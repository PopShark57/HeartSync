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

    /// Runs until the channel fails, the Mac says goodbye, or `waitForChange` returns false.
    ///
    /// - Parameters:
    ///   - onAcknowledged: each cursor the Mac confirms it has applied.
    ///   - waitForChange: called once the Mac is up to date; returns when there may be more
    ///     to send, or false to end the session.
    func run(
        channel: any MacMirrorFrameChannel,
        pairing: MacMirrorPairingRecord,
        phoneName: String,
        onProgress: @escaping @MainActor (MacMirrorProgress) -> Void = { _ in },
        onAcknowledged: @escaping @MainActor (Int64) -> Void = { _ in },
        waitForChange: @escaping @MainActor () async -> Bool
    ) async throws {
        onProgress(.connecting)
        try await channel.send(.json(.hello, MacMirrorHello(
            protocolVersion: MacMirrorProtocol.version,
            pairingIdentity: pairing.identity,
            phoneName: phoneName
        )))
        let state = try await channel.receive(timeout: .seconds(30)).decode(.state, as: MacMirrorState.self)
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
                try await sendSnapshot(from: position, channel: channel, onProgress: onProgress, onAcknowledged: onAcknowledged)
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
                guard await waitForChange() else { return }
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
            macCursor = try await acknowledged(over: channel, expecting: changes.through)
            sentSources = sources
            onAcknowledged(changes.through)
        }
    }

    /// Sends every stored row, page by page, then an empty closing batch.
    ///
    /// The position is read before the first page and every batch carries it, so once the
    /// snapshot ends the log resumes from there: any row written while the pages were being
    /// read is in the log after it, whichever page it was or was not in.
    private func sendSnapshot(
        from position: HealthDatabase.ChangeLogPosition,
        channel: any MacMirrorFrameChannel,
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
            _ = try await acknowledged(over: channel, expecting: position.latest)
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
        _ = try await acknowledged(over: channel, expecting: position.latest)
        onAcknowledged(position.latest)
    }

    private func send(_ batch: MacMirrorBatch, over channel: any MacMirrorFrameChannel) async throws {
        let encoded = await HealthHistory.offMain(priority: .utility) {
            Result { try MacMirrorBatchCodec.encode(batch) }
        }
        try await channel.send(MacMirrorFrame(type: .batch, body: try encoded.get()))
    }

    private func acknowledged(over channel: any MacMirrorFrameChannel, expecting cursor: Int64) async throws -> Int64 {
        let ack = try await channel.receive(timeout: .seconds(30)).decode(.ack, as: MacMirrorAck.self)
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

/// The Mac's half: applies what the paired phone sends, one transaction per batch.
///
/// Compiled into the iPhone app as well, so the hosted tests can run both halves against
/// each other; the phone never starts one.
@MainActor
final class MacMirrorReceiver {
    private let store: HealthStore

    init(store: HealthStore) {
        self.store = store
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
                    cursor: batch.cursor
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
                onProgress(.snapshot(sent: snapshotApplied, total: max(snapshotTotal, snapshotApplied)))
            case .end:
                inSnapshot = false
                epoch = batch.epoch
                onProgress(.upToDate(.now))
            case nil:
                onProgress(.upToDate(.now))
            }
        }
    }
}
