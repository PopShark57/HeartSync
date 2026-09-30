import Foundation
import Testing
@testable import HeartSyncChecker

/// Spot and nightly measurements on Now.
///
/// Now used to drop every reading older than its fifteen-minute live window, so blood
/// pressure, SpO₂, temperature, and respiratory rate appeared only in the quarter hour after a
/// measurement. A device's last reading now stays for `recentHorizon(for:)`, labelled as not
/// current, and never enters the agreement verdict.
@Suite("Now keeps recent spot readings")
@MainActor
struct NowRecentReadingsTests {
    private let strap = DataSource(id: "strap", displayName: "Strap", transport: .bluetooth)
    private let watch = DataSource(id: "hk.watch", displayName: "Watch", transport: .healthKit)
    private let ring = DataSource(id: "ring", displayName: "Ring", transport: .bluetooth)

    private func makeStore() -> HealthStore {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(watch)
        store.upsert(ring)
        return store
    }

    @Test("A blood-oxygen reading from hours ago is shown with its age, and is not compared")
    func spotReadingStaysWithItsAge() throws {
        let now = Date.now
        let store = makeStore()
        let measured = now.addingTimeInterval(-3 * 3_600)
        _ = store.append(Reading(sourceID: watch.id, kind: .spo2, value: 96, start: measured))

        let snapshot = DashboardSnapshot(store: store, now: now)
        let card = try #require(snapshot.metrics.first { $0.kind == .spo2 })
        #expect(card.rows.count == 1)
        #expect(card.rows[0].value == 96)
        #expect(card.rows[0].isCurrent == false)
        #expect(card.rows[0].deltaFromWindowConsensus == nil)
        #expect(card.isCurrent == false)
        #expect(card.headline == 96)
        #expect(card.comparison == nil)
        #expect(card.notComparedDetail == nil)
        let newest = try #require(card.newestTimestamp)
        #expect(abs(newest.timeIntervalSince(measured)) < 0.01)
    }

    @Test("Blood pressure measured yesterday shows both halves")
    func bloodPressureFromYesterday() {
        let now = Date.now
        let store = makeStore()
        let measured = now.addingTimeInterval(-26 * 3_600)
        _ = store.append(Reading(sourceID: ring.id, kind: .bloodPressureSystolic, value: 118, start: measured, provenance: .estimated))
        _ = store.append(Reading(sourceID: ring.id, kind: .bloodPressureDiastolic, value: 76, start: measured, provenance: .estimated))

        let kinds = Set(DashboardSnapshot(store: store, now: now).metrics.map(\.kind))
        #expect(kinds.isSuperset(of: [.bloodPressureSystolic, .bloodPressureDiastolic]))
    }

    @Test("A reading older than the horizon is not shown")
    func olderThanTheHorizonIsDropped() {
        let now = Date.now
        let store = makeStore()
        let old = now.addingTimeInterval(-DashboardSnapshot.recentHorizon(for: .bodyTemperature) - 3_600)
        _ = store.append(Reading(sourceID: watch.id, kind: .bodyTemperature, value: 36.6, start: old))

        #expect(!DashboardSnapshot(store: store, now: now).metrics.contains { $0.kind == .bodyTemperature })
    }

    @Test("The newest of a device's readings is the one shown")
    func newestEarlierReadingWins() throws {
        let now = Date.now
        let store = makeStore()
        _ = store.append(Reading(sourceID: watch.id, kind: .respiratoryRate, value: 13, start: now.addingTimeInterval(-10 * 3_600)))
        _ = store.append(Reading(sourceID: watch.id, kind: .respiratoryRate, value: 15, start: now.addingTimeInterval(-5 * 3_600)))

        let card = try #require(DashboardSnapshot(store: store, now: now).metrics.first { $0.kind == .respiratoryRate })
        #expect(card.rows.map(\.value) == [15])
    }

    @Test("A live device keeps its verdict; an old one is listed after it and never compared")
    func oldRowStaysOutOfTheVerdict() throws {
        let now = ComparisonEngine.floorToWindow(Date.now, size: 60).addingTimeInterval(30)
        let store = makeStore()
        // Two live devices sharing the current minute.
        _ = store.append(Reading(sourceID: strap.id, kind: .heartRate, value: 70, start: now.addingTimeInterval(-10)))
        _ = store.append(Reading(sourceID: watch.id, kind: .heartRate, value: 72, start: now.addingTimeInterval(-5)))
        // A third that last reported two hours ago, far from both.
        _ = store.append(Reading(sourceID: ring.id, kind: .heartRate, value: 110, start: now.addingTimeInterval(-7_200)))

        let card = try #require(DashboardSnapshot(store: store, now: now).metrics.first { $0.kind == .heartRate })
        #expect(card.isCurrent)
        #expect(card.comparison?.sourceCount == 2)
        #expect(card.headline != 110)
        let old = try #require(card.rows.last)
        #expect(old.source.id == ring.id)
        #expect(old.isCurrent == false)
        #expect(old.deltaFromWindowConsensus == nil)
        #expect(card.rows.dropLast().allSatisfy { $0.isCurrent })
    }

    @Test("A paused device's old reading is not shown")
    func pausedDeviceIsHidden() {
        let now = Date.now
        let store = makeStore()
        _ = store.append(Reading(sourceID: watch.id, kind: .spo2, value: 97, start: now.addingTimeInterval(-3_600)))
        _ = store.setEnabled(false, forSource: watch.id)

        #expect(!DashboardSnapshot(store: store, now: now).metrics.contains { $0.kind == .spo2 })
    }

    @Test("The latest-reading query finds a device's newest row inside the range only")
    func latestQueryIsBounded() throws {
        let now = Date.now
        let store = makeStore()
        _ = store.append(Reading(sourceID: watch.id, kind: .spo2, value: 95, start: now.addingTimeInterval(-7_200)))
        _ = store.append(Reading(sourceID: watch.id, kind: .spo2, value: 97, start: now.addingTimeInterval(-600)))
        _ = store.append(Reading(sourceID: strap.id, kind: .spo2, value: 99, start: now.addingTimeInterval(-60)))
        let history = store.history

        let all = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        #expect(try history.latestOutcome(kind: .spo2, sourceID: watch.id, midpointIn: all).get()?.value == 97)
        let early = DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-3_600))
        #expect(try history.latestOutcome(kind: .spo2, sourceID: watch.id, midpointIn: early).get()?.value == 95)
        let none = DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-10_000))
        #expect(try history.latestOutcome(kind: .spo2, sourceID: watch.id, midpointIn: none).get() == nil)
    }
}
