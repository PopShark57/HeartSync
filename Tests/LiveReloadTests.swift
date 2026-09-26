import Foundation
import Testing
@testable import HeartSyncChecker

/// Bounded and coalesced reloads on the live screens (improvement 29).
///
/// The throttle changes how often a screen re-reads history, and the Now read is bounded
/// per metric; neither may change what a card displays or which verdict it shows.
@Suite("Live screen reloads")
@MainActor
struct LiveReloadTests {

    // MARK: - Coalescing rule

    @Test("A changed question always loads at once")
    func userChangesAreImmediate() {
        #expect(LiveReloadPolicy.delay(dataOnly: false, elapsed: 0.2, minimumInterval: 30) == LiveReloadPolicy.debounce)
        #expect(LiveReloadPolicy.delay(dataOnly: false, elapsed: nil, minimumInterval: 30) == LiveReloadPolicy.debounce)
    }

    @Test("The first load is never delayed, even when only data changed")
    func firstLoadIsImmediate() {
        #expect(LiveReloadPolicy.delay(dataOnly: true, elapsed: nil, minimumInterval: 30) == LiveReloadPolicy.debounce)
    }

    @Test("New data alone waits out the rest of the interval, then loads")
    func dataOnlyIsCoalesced() {
        #expect(abs(LiveReloadPolicy.delay(dataOnly: true, elapsed: 12, minimumInterval: 30) - 18) < 0.000_1)
        #expect(LiveReloadPolicy.delay(dataOnly: true, elapsed: 30, minimumInterval: 30) == LiveReloadPolicy.debounce)
        #expect(LiveReloadPolicy.delay(dataOnly: true, elapsed: 400, minimumInterval: 30) == LiveReloadPolicy.debounce)
        // A clock that stepped backwards cannot produce a wait longer than the interval.
        #expect(LiveReloadPolicy.delay(dataOnly: true, elapsed: -5, minimumInterval: 30) == 30)
    }

    @Test("Reload spacing grows with the range; the live screen keeps up at one a second")
    func intervalsFollowTheRange() {
        #expect(LiveReloadPolicy.minimumInterval(for: .rolling(.hour)) == 2)
        #expect(LiveReloadPolicy.minimumInterval(for: .rolling(.sixHours)) == 10)
        #expect(LiveReloadPolicy.minimumInterval(for: .rolling(.day)) == 30)
        #expect(LiveReloadPolicy.minimumInterval(for: .rolling(.week)) == 120)
        #expect(LiveReloadPolicy.minimumInterval(for: .rolling(.month)) == 720)
        // At most thirty reloads per chart bucket, whatever the zoom.
        for range in TimeRange.allCases {
            #expect(range.chartBucket / LiveReloadPolicy.minimumInterval(for: .rolling(range)) <= 30)
        }
        let walk = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 40 * 60)
        #expect(LiveReloadPolicy.minimumInterval(for: .fixed(walk)) == LiveReloadPolicy.minimumInterval(for: .rolling(.hour)))
        #expect(LiveReloadPolicy.liveScreenInterval == 1)
    }

    // MARK: - Bounded Now read

    private let strap = DataSource(id: "strap", displayName: "Strap", transport: .bluetooth)
    private let watch = DataSource(id: "hk.watch", displayName: "Watch", transport: .healthKit)
    private let ring = DataSource(id: DataSource.ouraSourceID, displayName: "Ring", transport: .oura)

    /// Three hours of 5-second heart rate from two devices, HRV windows, an old shared
    /// window two days back, and an overnight respiratory average that ended minutes ago.
    private func makeStore(now: Date) -> HealthStore {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(watch)
        store.upsert(ring)
        for step in stride(from: 3 * 3_600, to: 20, by: -5) {
            let stamp = now.addingTimeInterval(-Double(step))
            _ = store.append(Reading(sourceID: strap.id, kind: .heartRate, value: 60 + Double(step % 17), start: stamp))
            if step % 15 == 0 {
                _ = store.append(Reading(sourceID: watch.id, kind: .heartRate, value: 62 + Double(step % 11), start: stamp.addingTimeInterval(2)))
            }
        }
        for window in 1...6 {
            let end = now.addingTimeInterval(-Double(window) * 300 + 30)
            _ = store.append(Reading(sourceID: strap.id, kind: .hrvRMSSD, value: 40 + Double(window), start: end.addingTimeInterval(-300), end: end, provenance: .derived))
        }
        let twoDaysAgo = now.addingTimeInterval(-47 * 3_600)
        _ = store.append(Reading(sourceID: strap.id, kind: .spo2, value: 97, start: twoDaysAgo))
        _ = store.append(Reading(sourceID: watch.id, kind: .spo2, value: 96, start: twoDaysAgo.addingTimeInterval(3)))
        _ = store.append(Reading(sourceID: watch.id, kind: .spo2, value: 95, start: now.addingTimeInterval(-120)))
        // An overnight average: its midpoint is hours back, but it ended ten minutes ago,
        // so it is a current reading by the rule every row uses.
        _ = store.append(Reading(
            sourceID: ring.id,
            kind: .respiratoryRate,
            value: 14.5,
            start: now.addingTimeInterval(-8 * 3_600 - 600),
            end: now.addingTimeInterval(-600)
        ))
        _ = store.append(Reading(sourceID: strap.id, kind: .respiratoryRate, value: 15, start: now.addingTimeInterval(-90)))
        return store
    }

    /// The facts a card displays: rows, headline, and verdict.
    private struct Displayed: Equatable {
        var kind: MetricKind
        var rows: [String]
        var headline: Double?
        var severity: DiscrepancySeverity?
        var spread: Double?
        var comparedSources: Int?
    }

    private func displayed(_ snapshot: DashboardSnapshot) -> [Displayed] {
        snapshot.metrics.map { summary in
            Displayed(
                kind: summary.kind,
                rows: summary.rows.map {
                    "\($0.source.id)|\($0.value)|\($0.timestamp.timeIntervalSince1970)|\($0.deltaFromWindowConsensus.map { String($0) } ?? "-")"
                },
                headline: summary.headline,
                severity: summary.comparison?.severity,
                spread: summary.comparison?.spread,
                comparedSources: summary.comparison?.sourceCount
            )
        }
    }

    @Test("The bounded read shows the same values and verdicts as the two-day read")
    func boundedReadMatchesTwoDayRead() {
        let now = ComparisonEngine.floorToWindow(Date.now, size: 60).addingTimeInterval(37)
        let store = makeStore(now: now)

        let bounded = DashboardSnapshot(store: store, now: now)
        let twoDay = DashboardSnapshot(store: store, now: now) { _ in DashboardSnapshot.outerLookback }

        #expect(bounded.queryFailure == nil)
        #expect(displayed(bounded) == displayed(twoDay))
        #expect(bounded.metrics.map(\.kind).contains(.heartRate))
        #expect(bounded.metrics.first { $0.kind == .heartRate }?.comparison != nil)
    }

    @Test("A long reading that ended recently stays on screen although its midpoint is hours old")
    func longRecentReadingStaysLive() throws {
        let now = Date.now
        let store = makeStore(now: now)
        let snapshot = DashboardSnapshot(store: store, now: now)
        let respiration = try #require(snapshot.metrics.first { $0.kind == .respiratoryRate })
        #expect(respiration.rows.contains { $0.source.id == ring.id && $0.value == 14.5 })
    }

    @Test("Fast metrics read minutes, not days")
    func lookbackIsBoundedPerMetric() {
        #expect(DashboardSnapshot.lookback(for: .heartRate) == 17 * 60)
        #expect(DashboardSnapshot.lookback(for: .hrvRMSSD) == 25 * 60)
        // Daily metrics keep exactly the two-day read they always had.
        #expect(DashboardSnapshot.lookback(for: .restingHeartRate) == DashboardSnapshot.outerLookback)
        #expect(MetricKind.allCases.allSatisfy { DashboardSnapshot.lookback(for: $0) >= 2 * $0.comparisonWindow })
    }

    @Test("A failed read is reported, not shown as waiting for data")
    func failedReadIsReported() {
        let now = Date.now
        let store = makeStore(now: now)
        store.injectQueryFailureForTesting()
        let snapshot = DashboardSnapshot(store: store, now: now)
        #expect(snapshot.queryFailure != nil)
        #expect(snapshot.metrics.isEmpty)
    }
}
