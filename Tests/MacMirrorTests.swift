import CryptoKit
import Foundation
import Network
import Testing
#if canImport(HeartSyncMac)
@testable import HeartSyncMac
#else
@testable import HeartSyncChecker
#endif

/// Mac sync: the phone's change log, the batch format, pairing, and both session halves
/// against each other, in memory and over a real TLS connection on the loopback interface.

// MARK: - Fixtures

private func minute(_ now: Date) -> Date {
    Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
}

/// Two sources over the last hour, plus one row with metadata.
private func fixture(now: Date, minutes: Int = 60) -> [Reading] {
    var readings: [Reading] = []
    for offset in 0..<minutes {
        let at = now.addingTimeInterval(-Double(offset) * 60 - 30.25)
        readings.append(Reading(sourceID: "strap", kind: .heartRate, value: 60 + Double(offset % 7), start: at))
        readings.append(Reading(sourceID: "ring", kind: .heartRate, value: 62 + Double(offset % 5), start: at.addingTimeInterval(4.5)))
    }
    readings.append(Reading(
        sourceID: "strap", kind: .hrvRMSSD, value: 41, start: now.addingTimeInterval(-900), end: now.addingTimeInterval(-600),
        provenance: .derived, metadata: ReadingMetadata(quality: .accepted, observationDuration: 300, acceptedBeatCount: 280)
    ))
    return readings
}

@MainActor
private func phoneStore(now: Date, logging: Bool = true) -> HealthStore {
    let store = HealthStore(persistenceEnabled: false)
    store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
    store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
    if logging { #expect(store.setMirrorChangeLogging(true)) }
    store.append(contentsOf: fixture(now: now))
    return store
}

@MainActor
private func position(_ store: HealthStore) throws -> HealthDatabase.ChangeLogPosition? {
    try store.history.query { try $0.changeLogPosition() }.get()
}

@MainActor
private func expectMirrors(_ mac: HealthStore, _ phone: HealthStore, sourceLocation: SourceLocation = #_sourceLocation) {
    let phoneRows = phone.readings.sorted { $0.id.uuidString < $1.id.uuidString }
    let macRows = mac.readings.sorted { $0.id.uuidString < $1.id.uuidString }
    #expect(macRows.count == phoneRows.count, sourceLocation: sourceLocation)
    #expect(macRows == phoneRows, sourceLocation: sourceLocation)
    // As the phone stores them: dates are kept to the millisecond, as in every payload.
    let stored = (try? phone.history.query { try $0.allSources() }.get()) ?? []
    #expect(mac.sources == stored, sourceLocation: sourceLocation)
}

private func pairing(identity: String = "hsm-test", key: SymmetricKey = SymmetricKey(size: .bits256)) -> MacMirrorPairingRecord {
    MacMirrorPairingRecord(
        identity: identity,
        key: key.withUnsafeBytes { Data($0) },
        peer: MacMirrorPairing.Identity(id: UUID(), name: "Test device"),
        pairedAt: .now
    )
}

/// Two connected in-memory channels.
private final class PipeChannel: MacMirrorFrameChannel, @unchecked Sendable {
    private let inbox = Mailbox()
    private weak var peer: PipeChannel?

    static func pair() -> (PipeChannel, PipeChannel) {
        let a = PipeChannel()
        let b = PipeChannel()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ frame: MacMirrorFrame) async throws {
        guard let peer else { throw MacMirrorError.closed }
        try await peer.inbox.deliver(frame)
    }

    func receive() async throws -> MacMirrorFrame {
        try await inbox.next()
    }

    func cancel() {
        let peer = peer
        Task {
            await inbox.close()
            await peer?.inbox.close()
        }
    }

    private actor Mailbox {
        private var frames: [MacMirrorFrame] = []
        private var waiter: CheckedContinuation<MacMirrorFrame, any Error>?
        private var closed = false

        func deliver(_ frame: MacMirrorFrame) throws {
            guard !closed else { throw MacMirrorError.closed }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: frame)
            } else {
                frames.append(frame)
            }
        }

        func next() async throws -> MacMirrorFrame {
            if !frames.isEmpty { return frames.removeFirst() }
            guard !closed else { throw MacMirrorError.closed }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func close() {
            closed = true
            waiter?.resume(throwing: MacMirrorError.closed)
            waiter = nil
        }
    }
}

/// Connections a test listener accepted, handed out in order. Nil once closed, so a test's
/// watchdog can release a waiter whose connection never arrives.
@MainActor
private final class AcceptedConnections {
    private var connections: [NWConnection] = []
    private var waiters: [CheckedContinuation<NWConnection?, Never>] = []
    private var isClosed = false

    func push(_ connection: NWConnection) {
        if waiters.isEmpty { connections.append(connection) } else { waiters.removeFirst().resume(returning: connection) }
    }

    func next() async -> NWConnection? {
        if !connections.isEmpty { return connections.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func close() {
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

/// Runs one sender against one receiver until the Mac is up to date, then ends both.
@MainActor
private func sync(phone: HealthStore, mac: HealthStore, record: MacMirrorPairingRecord, batchSize: Int = 25) async throws {
    let (phoneEnd, macEnd) = PipeChannel.pair()
    let receiver = Task { @MainActor in
        try await MacMirrorReceiver(store: mac).run(channel: macEnd, pairing: record)
    }
    try await MacMirrorSender(store: phone, batchSize: batchSize).run(
        channel: phoneEnd,
        pairing: record,
        phoneName: "Test iPhone",
        waitForChange: { false }
    )
    try await phoneEnd.send(.json(.goodbye, MacMirrorGoodbye(reason: .closing, detail: nil)))
    try await receiver.value
}

// MARK: - Change log

@Suite("Mac sync: the phone's change log")
@MainActor
struct MacMirrorChangeLogTests {
    @Test("Nothing is logged until a Mac is paired")
    func offByDefault() throws {
        let store = phoneStore(now: minute(.now), logging: false)
        #expect(try position(store) == nil)
        let count = try store.history.query { try $0.changes(after: 0, limit: 1_000).ids.count }.get()
        #expect(count == 0)
    }

    @Test("Switching on starts at the newest entry; later writes are named in order")
    func logsWrites() throws {
        let now = minute(.now)
        let store = phoneStore(now: now, logging: false)
        #expect(store.setMirrorChangeLogging(true))
        let start = try #require(try position(store))
        #expect(start.floor == start.latest)

        let added = Reading(sourceID: "strap", kind: .heartRate, value: 70, start: now.addingTimeInterval(-5))
        #expect(store.append(added))
        // A duplicate append is ignored by the database and so is not logged.
        #expect(!store.append(added))
        let doomed = try #require(store.readings.first { $0.sourceID == "ring" })
        #expect(store.remove(readingIDs: [doomed.id]) == 1)

        let changes = try store.history.query { try $0.changes(after: start.latest, limit: 100) }.get()
        #expect(changes.ids == [added.id, doomed.id])
        #expect(changes.through == (try #require(try position(store))).latest)
    }

    @Test("An upsert that changes a row is logged; the backfill of unchanged rows is not")
    func upsertLogged() throws {
        let now = minute(.now)
        let store = phoneStore(now: now)
        let before = try #require(try position(store)).latest
        var revised = try #require(store.readings.first)
        revised.value += 1
        #expect(store.upsert(contentsOf: [revised]).count == 1)
        let changes = try store.history.query { try $0.changes(after: before, limit: 100) }.get()
        #expect(changes.ids == [revised.id])
    }

    @Test("Deleting every reading clears the log and raises the floor past it")
    func resetRaisesFloor() throws {
        let store = phoneStore(now: minute(.now))
        let before = try #require(try position(store))
        #expect(store.deleteAllReadings())
        let after = try #require(try position(store))
        #expect(after.epoch == before.epoch)
        #expect(after.floor == after.latest)
        // Above the old newest entry, so even a Mac that was up to date starts again.
        #expect(after.floor > before.latest)
        let pending = try store.history.query { try $0.changes(after: 0, limit: 10).ids }.get()
        #expect(pending.isEmpty)
    }

    @Test("Trimming drops acknowledged entries, then caps the rest")
    func trimming() throws {
        let store = phoneStore(now: minute(.now))
        let start = try #require(try position(store))
        let acknowledged = start.floor + 10
        #expect(store.trimMirrorChangeLog(acknowledgedThrough: acknowledged))
        #expect(try #require(try position(store)).floor == acknowledged)
        let left = try store.history.query { try $0.changes(after: 0, limit: 10_000) }.get()
        #expect(left.ids.count == Int(start.latest - acknowledged))

        let database = try HealthDatabase(url: nil)
        try database.setChangeLogging(true)
        try database.commit(readings: fixture(now: minute(.now), minutes: 10), mode: .append, sources: [])
        let latest = try #require(try database.changeLogPosition()).latest
        #expect(try database.trimChangeLog(acknowledgedThrough: nil, maximumEntries: 5) == latest - 5)
        #expect(try database.changes(after: 0, limit: 100).ids.count == 5)
    }

    @Test("Switching off removes the log; switching on again is a new epoch")
    func newEpoch() throws {
        let store = phoneStore(now: minute(.now))
        let first = try #require(try position(store))
        #expect(store.setMirrorChangeLogging(false))
        #expect(try position(store) == nil)
        #expect(store.setMirrorChangeLogging(true))
        let second = try #require(try position(store))
        #expect(second.epoch != first.epoch)
        #expect(second.floor == second.latest)
    }
}

// MARK: - Batch format

@Suite("Mac sync: the batch format")
struct MacMirrorBatchTests {
    @Test("A batch round-trips exactly, metadata, removals, and fractional times included")
    func roundTrip() throws {
        let now = minute(.now)
        var source = DataSource(id: "strap", displayName: "Strap \u{2764}\u{FE0F}", transport: .bluetooth)
        // Source dates travel as payload dates do, to the millisecond.
        source.addedAt = now
        let batch = MacMirrorBatch(
            epoch: "epoch",
            cursor: 42,
            snapshot: .begin,
            snapshotTotal: 121,
            sources: [source],
            readings: fixture(now: now),
            removedIDs: [UUID(), UUID()]
        )
        let decoded = try MacMirrorBatchCodec.decode(try MacMirrorBatchCodec.encode(batch))
        #expect(decoded == batch)
        #expect(decoded.readings.first?.start == batch.readings.first?.start)
    }

    @Test("Corrupt, truncated, or unknown content is refused, not trapped on")
    func refusesBadInput() throws {
        #expect(throws: MacMirrorError.self) { try MacMirrorBatchCodec.decode(Data("not lzfse".utf8)) }
        let good = try MacMirrorBatchCodec.encode(MacMirrorBatch(
            epoch: "e", cursor: 1, snapshot: nil, sources: nil,
            readings: fixture(now: minute(.now), minutes: 2), removedIDs: []
        ))
        let plain = try (good as NSData).decompressed(using: .lzfse) as Data
        let truncated = try (plain.dropLast(9) as NSData).compressed(using: .lzfse) as Data
        #expect(throws: MacMirrorError.self) { try MacMirrorBatchCodec.decode(truncated) }

        let renamed = String(decoding: plain, as: UTF8.self).replacingOccurrences(of: "heartRate", with: "heartRatX")
        let unknown = try (Data(renamed.utf8) as NSData).compressed(using: .lzfse) as Data
        #expect(throws: MacMirrorError.self) { try MacMirrorBatchCodec.decode(unknown) }
    }

    @Test("Frame headers carry length and type; oversized and unknown frames are refused")
    func frames() throws {
        let frame = MacMirrorFrame(type: .ack, body: Data([1, 2, 3]))
        let encoded = frame.encoded
        let header = try MacMirrorFrame.parseHeader(encoded.prefix(MacMirrorFrame.headerLength))
        #expect(header.type == .ack)
        #expect(header.bodyLength == 3)
        #expect(throws: MacMirrorError.self) { try MacMirrorFrame.parseHeader(Data([0xff, 0xff, 0xff, 0xff, 4])) }
        #expect(throws: MacMirrorError.self) { try MacMirrorFrame.parseHeader(Data([0, 0, 0, 1, 99])) }
    }
}

// MARK: - Pairing

@Suite("Mac sync: pairing")
struct MacMirrorPairingTests {
    private let phone = MacMirrorPairing.Identity(id: UUID(), name: "iPhone")
    private let mac = MacMirrorPairing.Identity(id: UUID(), name: "Mac")

    @Test("Both sides derive the same code, key, and identity")
    func agreement() throws {
        let initiator = MacMirrorPairing.Initiator(identity: phone)
        var responder = MacMirrorPairing.Responder(identity: mac)
        let share = try responder.receive(initiator.commit)
        let (reveal, phoneSide) = try initiator.receive(share)
        let macSide = try responder.receive(reveal)
        #expect(phoneSide.code == macSide.code)
        #expect(phoneSide.code.count == 6)
        #expect(phoneSide.code.allSatisfy { $0.isNumber })
        #expect(phoneSide.identity == macSide.identity)
        #expect(phoneSide.key == macSide.key)
        #expect(phoneSide.mac == mac && macSide.phone == phone)
        #expect(macSide.verifies(phoneSide.confirmation(from: .phone), from: .phone))
        #expect(phoneSide.verifies(macSide.confirmation(from: .mac), from: .mac))
        // A confirmation cannot be reflected back to its sender as the other side's.
        #expect(!phoneSide.verifies(phoneSide.confirmation(from: .phone), from: .mac))
    }

    @Test("A key other than the committed one is refused")
    func commitmentEnforced() throws {
        let honest = MacMirrorPairing.Initiator(identity: phone)
        let attacker = MacMirrorPairing.Initiator(identity: phone)
        var responder = MacMirrorPairing.Responder(identity: mac)
        let share = try responder.receive(honest.commit)
        let (swapped, _) = try attacker.receive(share)
        #expect(throws: MacMirrorError.self) { try responder.receive(swapped) }
    }

    @Test("Another exchange gives another key")
    func freshKeys() throws {
        func run() throws -> MacMirrorPairing.Agreement {
            let initiator = MacMirrorPairing.Initiator(identity: phone)
            var responder = MacMirrorPairing.Responder(identity: mac)
            return try initiator.receive(try responder.receive(initiator.commit)).1
        }
        #expect(try run().key != run().key)
    }

    @Test("Confirming on both devices pairs them, in either order")
    @MainActor
    func exchange() async throws {
        let (phoneEnd, macEnd) = PipeChannel.pair()
        let phoneIdentity = phone, macIdentity = mac
        async let macRecord = MacMirrorPairingExchange.runMac(channel: macEnd, identity: macIdentity) { _, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        let phoneRecord = try await MacMirrorPairingExchange.runPhone(channel: phoneEnd, identity: phoneIdentity) { _, _ in true }
        let mac = try await macRecord
        #expect(phoneRecord.key == mac.key)
        #expect(phoneRecord.identity == mac.identity)
        #expect(phoneRecord.peer == macIdentity)
        #expect(mac.peer == phoneIdentity)
    }

    @Test("Declining on one device stops the other")
    @MainActor
    func decline() async throws {
        let (phoneEnd, macEnd) = PipeChannel.pair()
        let phoneIdentity = phone, macIdentity = mac
        let macTask = Task { @MainActor in
            try await MacMirrorPairingExchange.runMac(channel: macEnd, identity: macIdentity) { _, _ in
                // Waits for the person until the phone's refusal cancels the question.
                await withTaskCancellationHandler {
                    try? await Task.sleep(for: .seconds(30))
                    return true
                } onCancel: {}
            }
        }
        await #expect(throws: MacMirrorError.self) {
            _ = try await MacMirrorPairingExchange.runPhone(channel: phoneEnd, identity: phoneIdentity) { _, _ in false }
        }
        await #expect(throws: MacMirrorError.self) { _ = try await macTask.value }
    }
}

// MARK: - Sessions

@Suite("Mac sync: sessions")
@MainActor
struct MacMirrorSessionTests {
    @Test("A first session copies everything, then changes follow without another snapshot")
    func snapshotThenChanges() async throws {
        let now = minute(.now)
        let phone = phoneStore(now: now)
        let mac = HealthStore(persistenceEnabled: false)
        let record = pairing()

        try await sync(phone: phone, mac: mac, record: record)
        expectMirrors(mac, phone)
        let first = try #require(mac.mirrorPosition)
        #expect(first.epoch == (try #require(try position(phone))).epoch)

        // Add, revise, and delete on the phone, and rename a source.
        let added = Reading(sourceID: "ring", kind: .spo2, value: 97, start: now.addingTimeInterval(-20))
        #expect(phone.append(added))
        var revised = try #require(phone.readings.first { $0.sourceID == "strap" && $0.kind == .heartRate })
        revised.value = 99
        #expect(phone.upsert(contentsOf: [revised]).count == 1)
        let removed = try #require(phone.readings.first { $0.sourceID == "ring" && $0.kind == .heartRate })
        #expect(phone.remove(readingIDs: [removed.id]) == 1)
        #expect(phone.rename(sourceID: "ring", to: "Smart ring") == .applied)

        try await sync(phone: phone, mac: mac, record: record)
        expectMirrors(mac, phone)
        let second = try #require(mac.mirrorPosition)
        #expect(second.epoch == first.epoch)
        #expect(second.cursor > first.cursor)
    }

    @Test("A reset on the phone empties the mirror through a new snapshot")
    func resetPropagates() async throws {
        let phone = phoneStore(now: minute(.now))
        let mac = HealthStore(persistenceEnabled: false)
        let record = pairing()
        try await sync(phone: phone, mac: mac, record: record)
        #expect(!mac.readings.isEmpty)
        #expect(phone.deleteAllReadings())
        try await sync(phone: phone, mac: mac, record: record)
        #expect(mac.readings.isEmpty)
        expectMirrors(mac, phone)
    }

    @Test("A snapshot removes rows the phone no longer has, and a new epoch forces one")
    func snapshotSweeps() async throws {
        let now = minute(.now)
        let phone = phoneStore(now: now)
        let mac = HealthStore(persistenceEnabled: false)
        let record = pairing()
        try await sync(phone: phone, mac: mac, record: record)
        // Logging off and on again is a new log the Mac has no position in.
        #expect(phone.setMirrorChangeLogging(false))
        let gone = try #require(phone.readings.first)
        #expect(phone.remove(readingIDs: [gone.id]) == 1)
        #expect(phone.setMirrorChangeLogging(true))
        try await sync(phone: phone, mac: mac, record: record)
        expectMirrors(mac, phone)
        #expect(!mac.readings.contains { $0.id == gone.id })
    }

    @Test("A log trimmed past the Mac's position sends a snapshot instead of skipping entries")
    func trimmedPastCursor() async throws {
        let now = minute(.now)
        let phone = phoneStore(now: now)
        let mac = HealthStore(persistenceEnabled: false)
        let record = pairing()
        try await sync(phone: phone, mac: mac, record: record)
        let cursor = try #require(mac.mirrorPosition).cursor

        let doomed = try #require(phone.readings.first)
        #expect(phone.remove(readingIDs: [doomed.id]) == 1)
        #expect(phone.append(Reading(sourceID: "ring", kind: .spo2, value: 98, start: now.addingTimeInterval(-10))))
        // Every entry trimmed: the deletion above is no longer in the log.
        let database = try #require(try phone.history.query { try $0.changeLogPosition() }.get())
        #expect(phone.trimMirrorChangeLog(acknowledgedThrough: database.latest))
        #expect(try phone.history.query {
            try $0.changesIfContinuous(after: cursor, epoch: database.epoch, limit: 10)
        }.get() == nil)

        try await sync(phone: phone, mac: mac, record: record)
        expectMirrors(mac, phone)
        #expect(!mac.readings.contains { $0.id == doomed.id })
    }

    @Test("A Mac paired with another phone refuses the session")
    func wrongPairing() async throws {
        let phone = phoneStore(now: minute(.now))
        let mac = HealthStore(persistenceEnabled: false)
        let (phoneEnd, macEnd) = PipeChannel.pair()
        let receiver = Task { @MainActor in
            try await MacMirrorReceiver(store: mac).run(channel: macEnd, pairing: pairing(identity: "hsm-other"))
        }
        await #expect(throws: MacMirrorError.peerEnded(.notPaired)) {
            try await MacMirrorSender(store: phone).run(
                channel: phoneEnd, pairing: pairing(identity: "hsm-mine"), phoneName: "iPhone", waitForChange: { false }
            )
        }
        await #expect(throws: MacMirrorError.peerEnded(.notPaired)) { try await receiver.value }
        #expect(mac.readings.isEmpty)
    }

    @Test("Over TLS on the loopback interface with the pairing's key; a wrong key cannot connect")
    func overTLS() async throws {
        let phone = phoneStore(now: minute(.now))
        let mac = HealthStore(persistenceEnabled: false)
        let record = pairing()
        let listener = try NWListener(using: MacMirrorTransport.syncParameters(key: record.symmetricKey, identity: record.identity))
        let accepted = AcceptedConnections()
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { accepted.push(connection) }
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        var ports = ready.stream.makeAsyncIterator()
        let port = try #require(await ports.next())
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        let receiver = Task { @MainActor in
            guard let connection = await accepted.next() else { throw MacMirrorError.closed }
            let channel = MacMirrorChannel(connection: connection)
            try await channel.accept()
            try await MacMirrorReceiver(store: mac).run(channel: channel, pairing: record)
        }
        let channel = MacMirrorChannel(connection: NWConnection(
            to: endpoint,
            using: MacMirrorTransport.syncParameters(key: record.symmetricKey, identity: record.identity)
        ))
        try await channel.open()
        try await MacMirrorSender(store: phone, batchSize: 40).run(
            channel: channel, pairing: record, phoneName: "iPhone", waitForChange: { false }
        )
        await channel.close(.closing)
        try await receiver.value
        expectMirrors(mac, phone)

        // The listener side of the impostor's attempt must run for its handshake to fail.
        // Both halves are bounded: a connection that wrongly becomes ready (as a resumed TLS
        // session appeared to on macOS) leaves each side waiting for a frame that never comes,
        // which must fail the test rather than hang the run. A side the watchdog cancels
        // reports failure, never refusal.
        let refusal = Task { @MainActor in
            guard let connection = await accepted.next() else { return false }
            let channel = MacMirrorChannel(connection: connection)
            defer { channel.cancel() }
            do { try await channel.accept() } catch { return !Task.isCancelled }
            let frame = try? await channel.receive()
            return frame == nil && !Task.isCancelled
        }
        let impostor = MacMirrorChannel(connection: NWConnection(
            to: endpoint,
            using: MacMirrorTransport.syncParameters(key: SymmetricKey(size: .bits256), identity: record.identity)
        ))
        let attempt = Task {
            try await impostor.open()
            // Some stacks report the failed handshake only at the first read.
            _ = try await impostor.receive()
        }
        let watchdog = Task { @MainActor in
            try await Task.sleep(for: .seconds(20))
            attempt.cancel()
            refusal.cancel()
            accepted.close()
        }
        defer { watchdog.cancel() }
        // A watchdog cancellation ends the attempt with `CancellationError`, which fails this.
        await #expect(throws: MacMirrorError.self) { try await attempt.value }
        impostor.cancel()
        #expect(await refusal.value)
    }
}

/// Deliberately ignores cancellation while receipt is held: a late framework callback
/// must be harmless even when it wins a race with cancel().
private final class HeldBatchChannel: MacMirrorFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var hello: MacMirrorFrame?
    private var waiter: CheckedContinuation<MacMirrorFrame, any Error>?
    var isWaiting: Bool { lock.withLock { waiter != nil } }
    init(hello: MacMirrorFrame) { self.hello = hello }
    func send(_ frame: MacMirrorFrame) async throws {}
    func cancel() {}
    func receive() async throws -> MacMirrorFrame {
        if let first = lock.withLock({ let value = hello; hello = nil; return value }) { return first }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiter = continuation }
        }
    }
    func release(_ frame: MacMirrorFrame) {
        let continuation = lock.withLock { let value = waiter; waiter = nil; return value }
        continuation?.resume(returning: frame)
    }
}

@Suite("Mac receiver invalidation and network lifetime")
@MainActor
struct MirrorInvalidationTests {
    @Test("An in-flight batch cannot restore data after cancellation or session replacement")
    func obsoleteBatch() async throws {
        for cancelled in [true, false] {
            let store = HealthStore(persistenceEnabled: false)
            let record = pairing()
            let channel = HeldBatchChannel(hello: try .json(.hello, MacMirrorHello(protocolVersion: MacMirrorProtocol.version, pairingIdentity: record.identity, phoneName: "Old phone")))
            var current = true
            var updates = 0
            let task = Task {
                try await MacMirrorReceiver(store: store).run(channel: channel, pairing: record, onProgress: { _ in updates += 1 }, isCurrent: { current })
            }
            for _ in 0..<1_000 where !channel.isWaiting { await Task.yield() }
            #expect(channel.isWaiting)
            let before = updates
            if cancelled { task.cancel() } else { current = false }
            #expect(store.clearMirror())
            let frame = MacMirrorFrame(type: .batch, body: try MacMirrorBatchCodec.encode(MacMirrorBatch(epoch: "old", cursor: 10, snapshot: .begin, sources: [.init(id: "old", displayName: "Old", transport: .bluetooth)], readings: [.init(sourceID: "old", kind: .heartRate, value: 72, start: .now.addingTimeInterval(-30))], removedIDs: [])))
            channel.release(frame)
            do { try await task.value; Issue.record("Obsolete receiver unexpectedly succeeded") }
            catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
            #expect(store.readings.isEmpty)
            #expect(store.sources.isEmpty)
            #expect(store.mirrorPosition == nil)
            #expect(updates == before)
        }
    }

    @Test("A stalled peer frame has a bounded deadline and closes its channel")
    func peerFrameDeadline() async throws {
        let (a, b) = PipeChannel.pair()
        do { _ = try await a.receive(timeout: .milliseconds(50)); Issue.record("Expected timeout") }
        catch {}
        do { _ = try await b.receive(); Issue.record("Peer was not closed") } catch {}
    }

    @Test("Cancelling an actual Network receive closes the connection promptly")
    func networkReceiveCancellation() async throws {
        let listener = try NWListener(using: MacMirrorTransport.pairingParameters(), on: .any)
        let accepted = AcceptedConnections()
        listener.newConnectionHandler = { connection in Task { @MainActor in accepted.push(connection) } }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        var ports = ready.stream.makeAsyncIterator()
        let rawPort = try #require(await ports.next())
        let port = try #require(NWEndpoint.Port(rawValue: rawPort))
        let client = MacMirrorChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: MacMirrorTransport.pairingParameters()))
        let clientOpen = Task { try await client.open() }
        let peerConnection = try #require(await accepted.next())
        let peer = MacMirrorChannel(connection: peerConnection)
        try await peer.accept()
        try await clientOpen.value
        defer { client.cancel(); peer.cancel() }
        let receive = Task { try await client.receive() }
        receive.cancel()
        do { _ = try await receive.value; Issue.record("Cancelled receive succeeded") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test("Key exchange and confirmation waits expire and release both ends")
    func pairingDeadlines() async throws {
        let (phone, mac) = PipeChannel.pair()
        do {
            _ = try await MacMirrorPairingExchange.runPhone(channel: phone, identity: .init(id: UUID(), name: "Phone"), handshakeTimeout: .milliseconds(50)) { _, _ in true }
            Issue.record("A silent peer should time out")
        } catch {}
        mac.cancel()
        let (a, b) = PipeChannel.pair()
        let phoneTask = Task {
            try await MacMirrorPairingExchange.runPhone(channel: a, identity: .init(id: UUID(), name: "Phone"), confirmationTimeout: .milliseconds(50)) { _, _ in
                do { try await Task.sleep(for: .seconds(10)) } catch { return false }
                return true
            }
        }
        let macTask = Task {
            try await MacMirrorPairingExchange.runMac(channel: b, identity: .init(id: UUID(), name: "Mac"), confirmationTimeout: .milliseconds(50)) { _, _ in true }
        }
        do { _ = try await phoneTask.value; Issue.record("Confirmation should time out") } catch {}
        do { _ = try await macTask.value; Issue.record("Peer should close") } catch {}
    }

}
