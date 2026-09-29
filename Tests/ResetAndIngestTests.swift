import Foundation
import Testing
@testable import HeartSyncChecker

/// Resets that are exclusive with imports (47), batched Bluetooth ingest (52), and the
/// launch-time transport setup (53), through `AppModel`'s transport seam.

@MainActor
private func makeModel(_ transports: AppModel.TransportActions) -> AppModel {
    AppModel(
        store: HealthStore(persistenceEnabled: false),
        settings: AppSettings(persistenceEnabled: false),
        sessions: ComparisonSessionStore(persistenceEnabled: false),
        transports: transports
    )
}

/// Captures the callbacks `AppModel` hands to the Bluetooth transport.
@MainActor
private final class BluetoothCallbacks {
    var configureCount = 0
    var onReading: ((Reading) -> Void)?
    var onReadings: (([Reading]) -> Void)?
    var onLinkEnded: (() -> Void)?

    func install(into transports: inout AppModel.TransportActions) {
        transports.configureBluetooth = { [unowned self] _, reading, readings, ended in
            configureCount += 1
            onReading = reading
            onReadings = readings
            onLinkEnded = ended
        }
    }
}

private func strapReading(_ offset: TimeInterval, value: Double = 60) -> Reading {
    Reading(sourceID: "strap", kind: .heartRate, value: value, start: Date.now.addingTimeInterval(-offset))
}

// MARK: - 47

@Suite("Resets are exclusive with imports")
@MainActor
struct ResetExclusivityTests {

    @Test("A reset stops HealthKit and clears Oura before deleting, then resumes HealthKit", arguments: [
        AppModel.DataResetMode.clearForResync, .forgetImportedHistory,
    ])
    func resetOrder(mode: AppModel.DataResetMode) async {
        var events: [String] = []
        var readingsAtOuraClear = -1
        var model: AppModel?
        var transports = AppModel.TransportActions.inert
        transports.beginHealthKitReset = { events.append("begin") }
        transports.clearOura = { keeping in
            events.append("oura(\(keeping))")
            readingsAtOuraClear = model?.store.readings.count ?? -1
            return true
        }
        transports.finishHealthKitReset = { reread in
            events.append("finish(\(reread))")
            // HealthKit resumes only after the delete.
            #expect(model?.store.readings.isEmpty == true)
        }
        model = makeModel(transports)
        guard let model else { return }
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        model.store.append(strapReading(60))

        // A store without persistence reports "not saved"; only the order matters here.
        _ = await model.resetLocalData(mode)

        let resync = mode == .clearForResync
        #expect(events == ["begin", "oura(\(resync))", "finish(\(resync))"])
        // Oura was cleared before the store, and nothing was deleted until HealthKit stopped.
        #expect(readingsAtOuraClear == 1)
        #expect(model.store.readings.isEmpty)
    }

    @Test("A second reset while one is running is refused")
    func concurrentResetIsRefused() async {
        var second: Bool?
        var model: AppModel?
        var transports = AppModel.TransportActions.inert
        transports.beginHealthKitReset = {
            second = await model?.resetLocalData(.clearForResync)
        }
        model = makeModel(transports)
        _ = await model?.resetLocalData(.forgetImportedHistory)
        #expect(second == false)
        #expect(model?.isResettingData == false)
    }

    @Test("Live Bluetooth values waiting in the buffer are removed by the reset, not committed after it")
    func bufferedValuesGoWithTheReset() async {
        let callbacks = BluetoothCallbacks()
        var transports = AppModel.TransportActions.inert
        callbacks.install(into: &transports)
        let model = makeModel(transports)
        model.launch()
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        callbacks.onReading?(strapReading(5))

        _ = await model.resetLocalData(.clearForResync)
        model.flushBluetoothBuffer()

        #expect(model.store.readings.isEmpty)
    }
}

// MARK: - 52

@Suite("Batched Bluetooth ingest")
struct BluetoothIngestBufferTests {

    @Test("A batch is due after the flush interval or when full, and drains in order")
    func dueness() {
        var buffer = BluetoothIngestBuffer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!buffer.isDue(at: start))
        let first = buffer.append(strapReading(0, value: 60), at: start)
        let second = buffer.append(strapReading(0, value: 61), at: start.addingTimeInterval(1))
        #expect(!first && !second)
        #expect(buffer.isDue(at: start.addingTimeInterval(BluetoothIngestBuffer.flushInterval)))
        let drained = buffer.drain()
        #expect(drained.map(\.value) == [60, 61])
        #expect(buffer.isEmpty)
        #expect(!buffer.isDue(at: start.addingTimeInterval(100)))

        var dueEarly = false
        for index in 0..<(BluetoothIngestBuffer.maximumPending - 1) {
            dueEarly = buffer.append(strapReading(0, value: Double(60 + index % 40)), at: start) || dueEarly
        }
        #expect(!dueEarly)
        let full = buffer.append(strapReading(0), at: start)
        #expect(full)
    }

    @Test("An hour of 1 Hz heart rate with HRV is about 1,800 commits, not over 3,600")
    func hourOfStreamingCommits() {
        var buffer = BluetoothIngestBuffer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var commits = 0
        var values = 0
        for second in 0..<3_600 {
            let now = start.addingTimeInterval(Double(second))
            // The timer flush: what `AppModel` does when the interval passes.
            if buffer.isDue(at: now) { _ = buffer.drain(); commits += 1 }
            var due = buffer.append(strapReading(0), at: now)
            values += 1
            // An RMSSD emission once a minute, as the accumulator rate-limits it.
            if second % 60 == 59 { due = buffer.append(strapReading(0, value: 40), at: now) || due; values += 1 }
            if due { _ = buffer.drain(); commits += 1 }
        }
        if !buffer.isEmpty { commits += 1 }
        #expect(values == 3_660)
        #expect(commits <= 1_801)
        #expect(commits >= 1_700)
    }

    @MainActor
    @Test("Streaming values commit as one transaction when flushed, and a link ending flushes")
    func oneTransactionPerBatch() {
        let callbacks = BluetoothCallbacks()
        var transports = AppModel.TransportActions.inert
        callbacks.install(into: &transports)
        let model = makeModel(transports)
        model.launch()
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        let before = model.store.commitCount

        for offset in 0..<100 { callbacks.onReading?(strapReading(Double(offset))) }
        #expect(model.store.readings.isEmpty)
        model.flushBluetoothBuffer()
        #expect(model.store.readings.count == 100)
        #expect(model.store.commitCount == before + 1)

        callbacks.onReading?(strapReading(200))
        callbacks.onLinkEnded?()
        #expect(model.store.readings.count == 101)
    }

    @MainActor
    @Test("A ring import commits after anything live that was waiting")
    func importFlushesFirst() {
        let callbacks = BluetoothCallbacks()
        var transports = AppModel.TransportActions.inert
        callbacks.install(into: &transports)
        let model = makeModel(transports)
        model.launch()
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        let before = model.store.commitCount

        callbacks.onReading?(strapReading(1))
        callbacks.onReadings?([strapReading(3_600), strapReading(7_200)])

        #expect(model.store.readings.count == 3)
        #expect(model.store.commitCount == before + 2)
    }

    @MainActor
    @Test("Re-appending more readings than one lookup batch holds changes nothing")
    func batchedExistenceCheck() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        let readings = (0..<1_200).map { strapReading(Double($0)) }
        #expect(store.append(contentsOf: readings).count == 1_200)
        let commits = store.commitCount
        #expect(store.append(contentsOf: readings).isEmpty)
        #expect(store.upsert(contentsOf: readings).isEmpty)
        #expect(store.commitCount == commits)
    }

    @MainActor
    @Test("Only the source a batch changed is rewritten, and it is persisted")
    func changedSourcesPersist() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("health.sqlite3")
        do {
            let store = HealthStore(persistenceEnabled: true, databaseURL: url, archive: ReadingArchive(directory: folder))
            await store.loadIfNeeded()
            store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
            store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
            store.append(contentsOf: [strapReading(10)])
        }
        let reopened = HealthStore(persistenceEnabled: true, databaseURL: url, archive: ReadingArchive(directory: folder))
        await reopened.loadIfNeeded()
        #expect(reopened.source(id: "strap")?.observedMetrics == [.heartRate])
        #expect(reopened.source(id: "ring")?.observedMetrics == [])
    }
}

// MARK: - 53

@Suite("Transports start at launch")
@MainActor
struct LaunchTests {

    @Test("Launch configures Bluetooth and background delivery once, before history loads")
    func launchConfiguresOnce() async {
        let callbacks = BluetoothCallbacks()
        var registrations = 0
        var resumes = 0
        var transports = AppModel.TransportActions.inert
        callbacks.install(into: &transports)
        transports.registerHealthKitBackgroundDelivery = { registrations += 1 }
        transports.resumeBluetoothAfterLoad = { resumes += 1 }
        let model = makeModel(transports)

        model.launch()
        #expect(callbacks.configureCount == 1)
        #expect(registrations == 1)
        #expect(resumes == 0)

        model.launch()
        await model.start()
        #expect(callbacks.configureCount == 1)
        #expect(registrations == 1)
        // Known devices are reconnected once the source list has loaded.
        #expect(resumes == 1)
    }

    @Test("Starting without a launch still configures the transports")
    func startLaunchesIfNeeded() async {
        let callbacks = BluetoothCallbacks()
        var transports = AppModel.TransportActions.inert
        callbacks.install(into: &transports)
        let model = makeModel(transports)
        await model.start()
        #expect(callbacks.configureCount == 1)
    }
}
