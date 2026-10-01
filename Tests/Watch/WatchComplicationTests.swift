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

    @Test("The stress complication shows HeartSync's estimate; other metrics still drop estimates")
    func stressEstimate() throws {
        var snapshot = fixture()
        var heartEstimate = snapshot.metrics[0].readings[0]
        heartEstimate.id = "heartsync.estimate"
        heartEstimate.timestamp = now
        heartEstimate.provenance = .estimated
        snapshot.metrics[0].readings.append(heartEstimate)
        snapshot.metrics.append(WatchMetric(
            kind: .stress,
            readings: [WatchSourceReading(id: "heartsync.estimate", sourceName: "HeartSync estimates", value: 42,
                                         timestamp: now.addingTimeInterval(-60),
                                         provenance: .estimated, isCompacted: false)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400)
        ))
        #expect(WatchComplicationValue.estimatedKinds == [.stress])
        #expect(WatchComplicationValue(kind: .heartRate, snapshot: snapshot).reading?.id == "strap")

        let stress = WatchComplicationValue(kind: .stress, snapshot: snapshot)
        let reading = try #require(stress.reading)
        #expect(reading.value == 42)
        #expect(reading.provenance == .estimated)

        // The cache keeps it, so the extension draws the same thing the app would.
        let projection = snapshot.complicationProjection
        #expect(projection.metrics.map(\.kind) == [.heartRate, .stress])
        #expect(WatchComplicationValue(kind: .stress, snapshot: projection).reading == reading)

        // Ages like any five-minute metric, and a reset or unavailable phone clears it.
        #expect(!stress.isStale(at: now.addingTimeInterval(14 * 60)))
        #expect(stress.isStale(at: now.addingTimeInterval(15 * 60)))
        snapshot.availability = .unavailable
        snapshot.metrics = []
        #expect(WatchComplicationValue(kind: .stress, snapshot: snapshot).reading == nil)
    }

    @Test("A new stress score reloads the complications; an unchanged one does not")
    func stressReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchComplicationStore(directory: directory)
        var snapshot = fixture()
        snapshot.metrics.append(WatchMetric(
            kind: .stress,
            readings: [WatchSourceReading(id: "heartsync.estimate", sourceName: "HeartSync estimates", value: 42,
                                         timestamp: now.addingTimeInterval(-60),
                                         provenance: .estimated, isCompacted: false)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400)
        ))
        #expect(try store.save(snapshot))
        let cached = try store.load()
        #expect(WatchComplicationValue(kind: .stress, snapshot: cached).reading?.value == 42)
        #expect(WatchComplicationStore.widgetKinds.contains(WatchComplicationStore.stressWidgetKind))
        #expect(Set(WatchComplicationStore.widgetKinds).count == WatchComplicationStore.widgetKinds.count)

        var redelivered = snapshot
        redelivered.generatedAt = now.addingTimeInterval(30)
        #expect(try !store.save(redelivered))

        var rescored = redelivered
        rescored.generatedAt = now.addingTimeInterval(300)
        rescored.metrics[1].readings[0].value = 55
        rescored.metrics[1].readings[0].timestamp = now.addingTimeInterval(240)
        #expect(try store.save(rescored))
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
        #expect(try store.load() == fixture().complicationProjection)
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
        #expect(try relaunched.load() == reset.complicationProjection)
        let unavailable = WatchSnapshot(generatedAt: now.addingTimeInterval(20), availability: .unavailable, metrics: [])
        #expect(try relaunched.save(unavailable))
        #expect(try relaunched.load() == unavailable.complicationProjection)
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
        #expect(try store.load() == fixture().complicationProjection)
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
        #expect(try store.load() == fixture().complicationProjection)
    }

    @Test("Only a change a complication can show reloads its timelines")
    func reloadsOnlyOnDisplayedChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchComplicationStore(directory: directory)
        #expect(try store.save(fixture()))

        // A later delivery, a different comparison count, and a chart change nothing drawn.
        var redelivered = fixture()
        redelivered.generatedAt = now.addingTimeInterval(30)
        redelivered.metrics[0].comparison = WatchComparison(
            readyPairs: 3, incompletePairs: 0, outsideTolerancePairs: 1, lookback: 86_400
        )
        #expect(try !store.save(redelivered))

        // A new measurement, a different source, or a changed provenance is drawn.
        var measured = redelivered
        measured.generatedAt = now.addingTimeInterval(60)
        measured.metrics[0].readings[0].value = 74
        #expect(try store.save(measured))

        var otherSource = measured
        otherSource.generatedAt = now.addingTimeInterval(90)
        otherSource.metrics[0].readings[0].id = "ring"
        otherSource.metrics[0].readings[0].sourceName = "Ring"
        #expect(try store.save(otherSource))

        var derived = otherSource
        derived.generatedAt = now.addingTimeInterval(120)
        derived.metrics[0].readings[0].provenance = .derived
        #expect(try store.save(derived))

        // An older delivery never overwrites, even when it differs.
        var late = fixture()
        late.generatedAt = now.addingTimeInterval(-60)
        late.metrics[0].readings[0].value = 60
        #expect(try !store.save(late))
    }

    @Test("The cache holds the displayed reading, not the whole payload")
    func projectionIsSmall() throws {
        var snapshot = fixture()
        var estimate = snapshot.metrics[0].readings[0]
        estimate.id = "estimate"
        estimate.timestamp = now.addingTimeInterval(1)
        estimate.provenance = .estimated
        var older = snapshot.metrics[0].readings[0]
        older.id = "older"
        older.timestamp = now.addingTimeInterval(-500)
        snapshot.metrics[0].readings += [estimate, older]
        let projection = snapshot.complicationProjection
        #expect(projection.metrics.count == 1)
        #expect(projection.metrics[0].readings.map(\.id) == ["strap"])
        #expect(projection.metrics[0].chart == nil)
        #expect(
            WatchComplicationValue(kind: .heartRate, snapshot: projection).reading
                == WatchComplicationValue(kind: .heartRate, snapshot: snapshot).reading
        )
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
        for string in ["https://metric/heartRate", "heartsync-watch://workout", "heartsync-watch://metric/unknown", "heartsync-watch://workout?start=true",
                       "heartsync-watch://metric/heartRate/extra", "heartsync-watch://user@workout"] {
            #expect(WatchComplicationLink(url: try #require(URL(string: string))) == nil)
        }
    }
}
