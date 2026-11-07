import Foundation
import Observation

/// What a mirror session sends and receives frames over: a `MacMirrorChannel` on the
/// network, or an in-memory pipe in tests.
protocol MacMirrorFrameChannel: AnyObject, Sendable {
    func send(_ frame: MacMirrorFrame) async throws
    func receive() async throws -> MacMirrorFrame
    /// Ends the connection; a receive in progress then throws.
    func cancel()
}

extension MacMirrorChannel: MacMirrorFrameChannel {}

extension MacMirrorFrameChannel {
    func receive(timeout: Duration) async throws -> MacMirrorFrame {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: MacMirrorFrame.self) { group in
                group.addTask { try await self.receive() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    self.cancel()
                    throw MacMirrorError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { self.cancel() }
    }
}

// MARK: - Inbox

/// Frames from the other device, read as they arrive rather than only when one is expected.
///
/// The phone used to read only while it waited for an acknowledgement. While it waited for
/// new history it read nothing, so it could not tell that the Mac had quit, slept, or closed
/// the connection: the session still looked up to date, and when the Mac came back the
/// phone did not reconnect until its own history next changed, which on a phone without a
/// streaming strap could be never. With a read always pending, a close, a goodbye, or a
/// keepalive failure is seen as soon as it happens (`wait(for:)`).
///
/// One pump task reads the channel until the connection ends; it is never cancelled, so
/// stopping a wait never closes the connection. Whoever owns the channel closes it, which
/// ends the pump.
@MainActor
final class MacMirrorInbox {
    private let channel: any MacMirrorFrameChannel
    private var frames: [MacMirrorFrame] = []
    /// Why the connection ended, once it has. Every later read throws it.
    private var ending: (any Error)?
    private var waiter: (id: UUID, continuation: CheckedContinuation<MacMirrorFrame, any Error>)?
    private var onArrival: (() -> Void)?

    init(channel: any MacMirrorFrameChannel) {
        self.channel = channel
        Task { [weak self] in
            while true {
                do {
                    let frame = try await channel.receive()
                    guard let self else { return }
                    self.deliver(frame)
                } catch {
                    self?.end(error)
                    return
                }
            }
        }
    }

    /// True when a frame, or the end of the connection, is waiting to be read.
    var hasPending: Bool { !frames.isEmpty || ending != nil }

    /// The next frame, waiting at most `timeout` (nil: as long as it takes).
    ///
    /// A timeout closes the channel, as `MacMirrorFrameChannel.receive(timeout:)` does: a
    /// peer that stopped answering mid-exchange is not waited for again. Cancellation only
    /// stops this wait; a frame that arrives later is kept for the next call.
    func next(timeout: Duration?) async throws -> MacMirrorFrame {
        if let result = take() { return try result.get() }
        let id = UUID()
        let deadline = timeout.map { timeout in
            Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.waiter?.id == id else { return }
                self.resume(id, with: .failure(MacMirrorError.timedOut))
                self.channel.cancel()
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let result = take() {
                    continuation.resume(with: result)
                } else {
                    waiter = (id, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id, with: .failure(CancellationError())) }
        }
    }

    /// Waits for `change`, unless something arrives from the peer first.
    ///
    /// - Returns: what `change` returned, or nil when a frame or the end of the connection
    ///   came first; `next(timeout:)` then returns it at once.
    func wait(for change: @escaping @MainActor @Sendable () async -> Bool) async -> Bool? {
        guard !hasPending else { return nil }
        let waiting = Task { @MainActor in await change() }
        onArrival = { waiting.cancel() }
        defer { onArrival = nil }
        let changed = await withTaskCancellationHandler {
            await waiting.value
        } onCancel: {
            waiting.cancel()
        }
        return hasPending ? nil : changed
    }

    private func take() -> Result<MacMirrorFrame, any Error>? {
        if !frames.isEmpty { return .success(frames.removeFirst()) }
        return ending.map { .failure($0) }
    }

    private func deliver(_ frame: MacMirrorFrame) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: frame)
        } else {
            frames.append(frame)
            onArrival?()
        }
    }

    private func end(_ error: any Error) {
        guard ending == nil else { return }
        ending = error
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(throwing: error)
        }
        onArrival?()
    }

    private func resume(_ id: UUID, with result: Result<MacMirrorFrame, any Error>) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(with: result)
    }
}

/// Where a session has got to, for the status line on each device.
enum MacMirrorProgress: Equatable, Sendable {
    case connecting
    /// Sending or receiving the whole history: rows so far of `total`.
    case snapshot(sent: Int, total: Int)
    /// Sending or receiving changes since the last session.
    case catchingUp
    /// Everything the phone had has been applied; waiting for the next change.
    case upToDate(Date)
}

// MARK: - iPhone

/// The phone's half: brings one paired Mac up to date and keeps it there while connected.
///
/// Reads run off the main actor on pooled connections (`HealthHistory`), as every history
/// read does. The session never writes to the phone's history; the only write it causes is
/// trimming the change log once a Mac has acknowledged entries, which the publisher does.
@MainActor
final class MacMirrorSender {
    private let store: HealthStore
    private let batchSize: Int

    init(store: HealthStore, batchSize: Int = MacMirrorProtocol.batchSize) {
        self.store = store
        self.batchSize = batchSize
    }

    /// How a session that did not fail ended.
    enum Ending: Equatable, Sendable {
        /// `waitForChange` returned false: the app went to the background, or the session
        /// was cancelled.
        case stopped
        /// The Mac closed the connection while it was up to date: it quit, slept, or asked
        /// to start again (Sync Now, Copy Everything Again). Reconnecting soon is right.
        case macClosed
    }

    /// Runs until the channel fails, the Mac closes it, or `waitForChange` returns false.
    ///
    /// - Parameters:
    ///   - onAcknowledged: each cursor the Mac confirms it has applied.
    ///   - waitForChange: called once the Mac is up to date; returns when there may be more
    ///     to send, or false to end the session. It is cancelled if the Mac closes the
    ///     connection meanwhile.
    @discardableResult
    func run(
        channel: any MacMirrorFrameChannel,
        pairing: MacMirrorPairingRecord,
        phoneName: String,
        onProgress: @escaping @MainActor (MacMirrorProgress) -> Void = { _ in },
        onAcknowledged: @escaping @MainActor (Int64) -> Void = { _ in },
        waitForChange: @escaping @MainActor @Sendable () async -> Bool
    ) async throws -> Ending {
        let inbox = MacMirrorInbox(channel: channel)
        onProgress(.connecting)
        try await channel.send(.json(.hello, MacMirrorHello(
            protocolVersion: MacMirrorProtocol.version,
            pairingIdentity: pairing.identity,
            phoneName: phoneName
        )))
        let state = try await inbox.next(timeout: .seconds(30)).decode(.state, as: MacMirrorState.self)
        guard state.protocolVersion == MacMirrorProtocol.version else {
            throw MacMirrorError.peerEnded(.versionMismatch)
        }
        var macEpoch = state.epoch
        var macCursor = state.cursor
        var sentSources: [DataSource]?

        while !Task.isCancelled {
            let position = try await read { try $0.changeLogPosition() }
            guard let position else {
                throw MacMirrorError.connectionFailed("the change log is off")
            }
            if macEpoch != position.epoch || (macCursor ?? -1) < position.floor || (macCursor ?? 0) > position.latest {
                try await sendSnapshot(from: position, channel: channel, inbox: inbox, onProgress: onProgress, onAcknowledged: onAcknowledged)
                macEpoch = position.epoch
                macCursor = position.latest
                sentSources = nil
                continue
            }
            let cursor = macCursor ?? position.latest
            let limit = batchSize
            let epoch = position.epoch
            let continuous = try await read { try $0.changesIfContinuous(after: cursor, epoch: epoch, limit: limit) }
            // The log moved on (trimmed past the cursor, or switched) since the position was
            // read; go round again, which sends a snapshot.
            guard let changes = continuous else { continue }
            let sources = store.sources
            let sourcesChanged = sources != sentSources
            guard !changes.ids.isEmpty || sourcesChanged else {
                onProgress(.upToDate(.now))
                // The Mac answers only what it is sent, so anything arriving now is it
                // closing the connection.
                guard let changed = await inbox.wait(for: waitForChange) else {
                    return try await closedWhileIdle(inbox)
                }
                guard changed else { return .stopped }
                continue
            }
            onProgress(.catchingUp)
            let ids = changes.ids
            let rows = try await read { try $0.readings(withIDs: ids) }
            let present = Set(rows.map(\.id))
            let batch = MacMirrorBatch(
                epoch: position.epoch,
                cursor: changes.through,
                snapshot: nil,
                sources: sourcesChanged ? sources : nil,
                readings: rows,
                removedIDs: ids.filter { !present.contains($0) }
            )
            try await send(batch, over: channel)
            macCursor = try await acknowledged(from: inbox, expecting: changes.through)
            sentSources = sources
            onAcknowledged(changes.through)
        }
        return .stopped
    }

    /// The Mac's goodbye, or the end of the connection, received while the phone had nothing
    /// to send. A clean close is the Mac stopping on purpose; anything else is a failure.
    private func closedWhileIdle(_ inbox: MacMirrorInbox) async throws -> Ending {
        let frame: MacMirrorFrame
        do { frame = try await inbox.next(timeout: .seconds(30)) }
        catch MacMirrorError.closed { return .macClosed }
        guard frame.type == .goodbye else {
            throw MacMirrorError.malformed("expected nothing while up to date, received \(frame.type)")
        }
        let goodbye = try frame.decode(.goodbye, as: MacMirrorGoodbye.self)
        guard goodbye.reason == .closing else { throw MacMirrorError.peerEnded(goodbye.reason) }
        return .macClosed
    }

    /// Sends every stored row, page by page, then an empty closing batch.
    ///
    /// The position is read before the first page and every batch carries it, so once the
    /// snapshot ends the log resumes from there: any row written while the pages were being
    /// read is in the log after it, whichever page it was or was not in.
    private func sendSnapshot(
        from position: HealthDatabase.ChangeLogPosition,
        channel: any MacMirrorFrameChannel,
        inbox: MacMirrorInbox,
        onProgress: @MainActor (MacMirrorProgress) -> Void,
        onAcknowledged: @MainActor (Int64) -> Void
    ) async throws {
        let total = try await read { try $0.readingCount() }
        var key: HealthDatabase.SnapshotKey?
        var sent = 0
        var first = true
        onProgress(.snapshot(sent: 0, total: total))
        while true {
            try Task.checkCancellation()
            let after = key
            let limit = batchSize
            let page = try await read { try $0.snapshotPage(after: after, limit: limit) }
            let batch = MacMirrorBatch(
                epoch: position.epoch,
                cursor: position.latest,
                snapshot: first ? .begin : .page,
                snapshotTotal: first ? total : nil,
                sources: first ? store.sources : nil,
                readings: page.rows,
                removedIDs: []
            )
            try await send(batch, over: channel)
            _ = try await acknowledged(from: inbox, expecting: position.latest)
            sent += page.rows.count
            onProgress(.snapshot(sent: sent, total: max(total, sent)))
            first = false
            guard let next = page.next else { break }
            key = next
        }
        let closing = MacMirrorBatch(
            epoch: position.epoch,
            cursor: position.latest,
            snapshot: .end,
            sources: store.sources,
            readings: [],
            removedIDs: []
        )
        try await send(closing, over: channel)
        _ = try await acknowledged(from: inbox, expecting: position.latest)
        onAcknowledged(position.latest)
    }

    private func send(_ batch: MacMirrorBatch, over channel: any MacMirrorFrameChannel) async throws {
        let encoded = await HealthHistory.offMain(priority: .utility) {
            Result { try MacMirrorBatchCodec.encode(batch) }
        }
        try await channel.send(MacMirrorFrame(type: .batch, body: try encoded.get()))
    }

    private func acknowledged(from inbox: MacMirrorInbox, expecting cursor: Int64) async throws -> Int64 {
        let ack = try await inbox.next(timeout: .seconds(30)).decode(.ack, as: MacMirrorAck.self)
        guard ack.cursor == cursor else { throw MacMirrorError.malformed("acknowledged \(ack.cursor), sent \(cursor)") }
        return ack.cursor
    }

    private func read<Value: Sendable>(
        _ body: @escaping @Sendable (HealthDatabase) throws -> Value
    ) async throws -> Value {
        let history = store.history
        return try await HealthHistory.offMain(priority: .utility) { history.query(body) }.get()
    }
}

// MARK: - Mac

/// Tells the Mac's screens about applied batches once per burst rather than once per batch.
///
/// Each batch is committed as it arrives; only the store's change token waits
/// (`HealthStore.applyMirrorBatch(publish:)`). A first copy is hundreds of batches and a
/// catch-up after a day away is dozens, landing within seconds. Advancing the token for
/// each one made every open screen cancel its load and start another, so a month-range
/// comparison could not finish until the sync did, and the reads it abandoned kept running.
/// A burst is now published when it pauses for `quiet`, and at least every `interval` while
/// it lasts, so a long first copy still fills the screens in as it goes.
@MainActor
final class MacMirrorPublicationGate {
    /// How long without a batch ends a burst.
    static let quiet: Duration = .milliseconds(400)
    /// While changes keep arriving, the screens still hear of them this often.
    static let changesInterval: TimeInterval = 2
    /// The same during a snapshot, which can last minutes and whose pages land back to back.
    static let snapshotInterval: TimeInterval = 5

    private let store: HealthStore
    private let quiet: Duration
    private var trailing: Task<Void, Never>?
    private var firstPending: Date?

    init(store: HealthStore, quiet: Duration = MacMirrorPublicationGate.quiet) {
        self.store = store
        self.quiet = quiet
    }

    /// Called after each batch is committed. Publishes now once `interval` has passed since
    /// the oldest unpublished batch; otherwise when no further batch follows within `quiet`.
    func applied(interval: TimeInterval, now: Date = .now) {
        let first = firstPending ?? now
        firstPending = first
        guard now.timeIntervalSince(first) < interval else {
            flush()
            return
        }
        trailing?.cancel()
        let quiet = quiet
        trailing = Task { [weak self] in
            do { try await Task.sleep(for: quiet) } catch { return }
            self?.flush()
        }
    }

    /// Publishes whatever has been applied and not yet published.
    func flush() {
        trailing?.cancel()
        trailing = nil
        firstPending = nil
        store.publishMirrorChanges()
    }
}

/// The Mac's half: applies what the paired phone sends, one transaction per batch.
///
/// Compiled into the iPhone app as well, so the hosted tests can run both halves against
/// each other; the phone never starts one.
@MainActor
final class MacMirrorReceiver {
    private let store: HealthStore
    private let publication: MacMirrorPublicationGate

    init(store: HealthStore, publicationQuiet: Duration = MacMirrorPublicationGate.quiet) {
        self.store = store
        self.publication = MacMirrorPublicationGate(store: store, quiet: publicationQuiet)
    }

    /// Runs until the phone closes the connection or something fails.
    ///
    /// - Parameters:
    ///   - pairing: the one pairing this Mac accepts; a hello naming another is refused.
    ///   - onPhone: the phone's name, once it has said hello.
    func run(
        channel: any MacMirrorFrameChannel,
        pairing: MacMirrorPairingRecord,
        onPhone: @escaping @MainActor (String) -> Void = { _ in },
        onProgress: @escaping @MainActor (MacMirrorProgress) -> Void = { _ in },
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        // However the session ends, what it applied reaches the screens.
        defer { publication.flush() }
        onProgress(.connecting)
        let hello = try await channel.receive(timeout: .seconds(30)).decode(.hello, as: MacMirrorHello.self)
        guard hello.protocolVersion == MacMirrorProtocol.version else {
            try? await channel.send(.json(.goodbye, MacMirrorGoodbye(reason: .versionMismatch, detail: nil)))
            throw MacMirrorError.peerEnded(.versionMismatch)
        }
        guard hello.pairingIdentity == pairing.identity else {
            try? await channel.send(.json(.goodbye, MacMirrorGoodbye(reason: .notPaired, detail: nil)))
            throw MacMirrorError.peerEnded(.notPaired)
        }
        try checkCurrent()
        onPhone(hello.phoneName)
        let position = store.mirrorPosition
        try await channel.send(.json(.state, MacMirrorState(
            protocolVersion: MacMirrorProtocol.version,
            epoch: position?.epoch,
            cursor: position?.cursor
        )))

        var epoch = position?.epoch
        var inSnapshot = false
        var snapshotTotal = 0
        var snapshotApplied = 0
        var hasReceivedBatch = false
        while !Task.isCancelled {
            let frame: MacMirrorFrame
            do { frame = try await (inSnapshot || !hasReceivedBatch ? channel.receive(timeout: .seconds(30)) : channel.receive()) }
            catch MacMirrorError.closed { return }
            if frame.type == .goodbye { return }
            guard frame.type == .batch else { throw MacMirrorError.malformed("expected a batch, received \(frame.type)") }
            let body = frame.body
            let batch = try await HealthHistory.offMain {
                Result { try MacMirrorBatchCodec.decode(body) }
            }.get()

            try checkCurrent()
            hasReceivedBatch = true
            switch batch.snapshot {
            case .begin:
                inSnapshot = true
                snapshotTotal = batch.snapshotTotal ?? 0
                snapshotApplied = 0
            case .page, .end:
                guard inSnapshot else { throw MacMirrorError.malformed("snapshot page outside a snapshot") }
            case nil:
                guard !inSnapshot, batch.epoch == epoch else {
                    throw MacMirrorError.malformed("changes for another log")
                }
            }
            do {
                try store.applyMirrorBatch(
                    sources: batch.sources,
                    readings: batch.readings,
                    removingReadingIDs: batch.removedIDs,
                    snapshot: batch.snapshot,
                    epoch: batch.epoch,
                    cursor: batch.cursor,
                    publish: false
                )
            } catch {
                try? await channel.send(.json(.goodbye, MacMirrorGoodbye(
                    reason: .applyFailed,
                    detail: error.localizedDescription
                )))
                throw error
            }
            try checkCurrent()
            try await channel.send(.json(.ack, MacMirrorAck(cursor: batch.cursor)))
            try checkCurrent()

            switch batch.snapshot {
            case .begin, .page:
                snapshotApplied += batch.readings.count
                publication.applied(interval: MacMirrorPublicationGate.snapshotInterval)
                onProgress(.snapshot(sent: snapshotApplied, total: max(snapshotTotal, snapshotApplied)))
            case .end:
                inSnapshot = false
                epoch = batch.epoch
                publication.flush()
                onProgress(.upToDate(.now))
            case nil:
                publication.applied(interval: MacMirrorPublicationGate.changesInterval)
                onProgress(.upToDate(.now))
            }
        }
    }
}
