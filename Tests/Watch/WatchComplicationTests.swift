import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Watch complications")
struct WatchComplicationTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func fixture() -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, metrics: [WatchMetric(
            kind: .heartRate,
            readings: [WatchSourceReading(id: "strap", sourceName: "Chest strap", value: 72,
                                         timestamp: now.addingTimeInterval(-5),
                                         provenance: .measured, isCompacted: false)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 1,
                                        outsideTolerancePairs: 0, lookback: 3_600)
        )])
    }

    @Test("Select the newest non-estimated source, independent of payload ordering")
    func sourceSelection() {
        var snapshot = fixture()
        var newer = snapshot.metrics[0].readings[0]
        newer.id = "newer"
        newer.timestamp = now
        newer.provenance = .derived
        var estimate = newer
        estimate.id = "estimate"
        estimate.timestamp = now.addingTimeInterval(1)
        estimate.provenance = .estimated
        snapshot.metrics[0].readings += [estimate, newer]
        let value = WatchComplicationValue(kind: .heartRate, snapshot: snapshot)
        #expect(value.reading?.id == "newer")
        #expect(value.reading?.provenance == .derived)
        snapshot.metrics[0].readings.reverse()
        #expect(WatchComplicationValue(kind: .heartRate, snapshot: snapshot).reading == value.reading)
    }

    @Test("Equal timestamps use stable source identity and preserve aggregation metadata")
    func stableTie() {
        var snapshot = fixture()
        var other = snapshot.metrics[0].readings[0]
        other.id = "a"
        other.isCompacted = true
        snapshot.metrics[0].readings.append(other)
        let value = WatchComplicationValue(kind: .heartRate, snapshot: snapshot)
        #expect(value.reading?.id == "a")
        #expect(value.reading?.isCompacted == true)
    }

    @Test("Missing metrics, estimates, reset and unavailable states never invent a reading")
    func emptyStates() {
        #expect(WatchComplicationValue(kind: .spo2, snapshot: fixture()).reading == nil)
        #expect(WatchComplicationValue(kind: .heartRate, snapshot: nil).availability == nil)
        var snapshot = fixture()
        snapshot.metrics[0].readings[0].provenance = .estimated
        #expect(WatchComplicationValue(kind: .heartRate, snapshot: snapshot).reading == nil)
        snapshot.metrics = []
        #expect(WatchComplicationValue(kind: .heartRate, snapshot: snapshot).reading == nil)
        snapshot.availability = .unavailable
        let value = WatchComplicationValue(kind: .heartRate, snapshot: snapshot)
        #expect(value.reading == nil)
        #expect(value.availability == .unavailable)
    }

    @Test("A future timeline entry ages a reading without receiving another snapshot")
    func timelineAging() throws {
        let value = WatchComplicationValue(kind: .heartRate, snapshot: fixture())
        let transition = try #require(value.staleTransition(after: now))
        #expect(transition == now.addingTimeInterval(896))
        #expect(!value.isStale(at: transition.addingTimeInterval(-1)))
        #expect(value.isStale(at: transition))
        #expect(value.staleTransition(after: transition) == nil)
        var refreshed = fixture()
        refreshed.generatedAt = now.addingTimeInterval(3_600)
        #expect(WatchComplicationValue(kind: .heartRate, snapshot: refreshed).isStale(at: refreshed.generatedAt))
    }

    @Test("Daily metrics retain the dashboard's longer freshness window")
    func dailyAging() throws {
        var snapshot = fixture()
        snapshot.metrics[0].kind = .restingHeartRate
        let value = WatchComplicationValue(kind: .restingHeartRate, snapshot: snapshot)
        #expect(!value.isStale(at: now.addingTimeInterval(3_600)))
        let transition = try #require(value.staleTransition(after: now))
        #expect(value.isStale(at: transition))
        #expect(transition == snapshot.metrics[0].readings[0].freshnessDeadline(kind: .restingHeartRate).addingTimeInterval(1))
    }

    @Test("Cache round-trips and ignores duplicate snapshots")
    func cacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchComplicationStore(directory: directory)
        #expect(try store.load() == nil)
        #expect(try store.save(fixture()))
        #expect(try store.load() == fixture())
        #expect(try !store.save(fixture()))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("A reset survives process recreation and rejects late data")
    func durableReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchComplicationStore(directory: directory)
        try store.save(fixture())
        let reset = WatchSnapshot(generatedAt: now.addingTimeInterval(10), metrics: [])
        #expect(try store.save(reset))
        let relaunched = WatchComplicationStore(directory: directory)
        #expect(try !relaunched.save(fixture()))
        #expect(try relaunched.load() == reset)
        let unavailable = WatchSnapshot(generatedAt: now.addingTimeInterval(20), availability: .unavailable, metrics: [])
        #expect(try relaunched.save(unavailable))
        #expect(try relaunched.load() == unavailable)
    }

    @Test("Invalid incoming data leaves the previous cache intact")
    func invalidWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchComplicationStore(directory: directory)
        try store.save(fixture())
        var invalid = fixture()
        invalid.metrics[0].readings[0].value = 1_000
        #expect(throws: WatchSnapshot.PayloadError.self) { try store.save(invalid) }
        #expect(try store.load() == fixture())
    }

    @Test("A corrupt disposable cache recovers only when a valid context arrives")
    func corruptCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("complication-snapshot-v1.json")
        try Data("corrupt".utf8).write(to: file)
        let store = WatchComplicationStore(directory: directory)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try store.save(fixture()))
        #expect(try store.load() == fixture())
    }

    @Test("Missing entitlements and inaccessible cache paths fail without fabricated data")
    func unavailableStorage() throws {
        let store = WatchComplicationStore(directory: nil)
        #expect(throws: WatchComplicationStore.StoreError.self) { try store.load() }
        #expect(throws: WatchComplicationStore.StoreError.self) { try store.save(fixture()) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("do not overwrite".utf8)
        try original.write(to: file)
        let blocked = WatchComplicationStore(directory: file)
        #expect(throws: (any Error).self) { try blocked.save(fixture()) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Complication links round-trip and reject unrelated URLs")
    func links() throws {
        for kind in MetricKind.allCases {
            #expect(WatchComplicationLink(url: WatchComplicationLink.metric(kind).url) == .metric(kind))
        }
        #expect(WatchComplicationLink(url: WatchComplicationLink.workout.url) == .workout)
        for string in ["https://workout", "heartsync-watch://metric/unknown", "heartsync-watch://workout?start=true",
                       "heartsync-watch://metric/heartRate/extra", "heartsync-watch://user@workout"] {
            #expect(WatchComplicationLink(url: try #require(URL(string: string))) == nil)
        }
    }
}
