import Foundation
import Testing
@testable import HeartSyncChecker

/// Drill-down keeps the analysed period (improvement 27).
///
/// Back-navigation and the session banner are covered by UI tests; these pin the period
/// resolution the detail screens rely on, so a saved session's seconds reach the metric
/// detail, the pair analysis, and the export unchanged.
@Suite("Drill-down keeps the analysed period")
@MainActor
struct DrillDownPeriodTests {

    private let strap = DataSource(id: "a-strap", displayName: "Strap", transport: .bluetooth)
    private let ring = DataSource(id: "b-ring", displayName: "Ring", transport: .oura)

    /// Twenty paired heart-rate minutes ending ten minutes ago.
    private func makeStore() -> (HealthStore, Date) {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(ring)
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-30 * 60), size: 60)
        for minute in 0..<20 {
            let stamp = anchor.addingTimeInterval(Double(minute) * 60)
            _ = store.append(Reading(sourceID: strap.id, kind: .heartRate, value: 70 + Double(minute % 3), start: stamp))
            _ = store.append(Reading(sourceID: ring.id, kind: .heartRate, value: 72, start: stamp.addingTimeInterval(5)))
        }
        return (store, anchor)
    }

    @Test("A preset fits a fixed span: the shortest one that covers it, else the widest")
    func fittingPresetCoversTheSpan() {
        #expect(TimeRange.fitting(duration: 1) == .hour)
        #expect(TimeRange.fitting(duration: 3_600) == .hour)
        #expect(TimeRange.fitting(duration: 3_601) == .sixHours)
        #expect(TimeRange.fitting(duration: 2 * 86_400) == .week)
        #expect(TimeRange.fitting(duration: 90 * 86_400) == .month)
    }

    @Test("A fixed period draws at the zoom that fits it and has no rolling preset")
    func fixedPeriodZoom() {
        let walk = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 45 * 60)
        let fixed = ComparisonPeriod.fixed(walk)
        #expect(fixed.displayRange == .hour)
        #expect(fixed.chartBucket == TimeRange.hour.chartBucket)
        #expect(fixed.rollingRange == nil)

        let rolling = ComparisonPeriod.rolling(.week)
        #expect(rolling.displayRange == .week)
        #expect(rolling.rollingRange == .week)
    }

    @Test("Metric detail from a session analyses exactly the session's seconds")
    func metricDetailUsesTheSessionSpan() {
        let (store, anchor) = makeStore()
        // Five minutes inside the twenty that exist: the rolling 24-hour range holds all
        // twenty, so a detail screen that fell back to the picker would show four times more.
        let session = DateInterval(start: anchor.addingTimeInterval(5 * 60), end: anchor.addingTimeInterval(10 * 60 - 1))
        let snapshot = MetricDetailSnapshot(
            store: store,
            kind: .heartRate,
            period: .fixed(session),
            includeEstimates: false,
            hrvQuality: [:]
        )

        #expect(snapshot.interval == session)
        #expect(snapshot.points.allSatisfy { session.contains($0.date) })
        #expect(snapshot.points.count == 10)
        let pair = snapshot.pairwiseAnalyses.first
        #expect(pair?.range == session)
        #expect(pair?.pairedWindowCount == 5)

        let rolling = MetricDetailSnapshot(
            store: store,
            kind: .heartRate,
            range: .day,
            includeEstimates: false,
            hrvQuality: [:]
        )
        #expect(rolling.pairwiseAnalyses.first?.pairedWindowCount == 20)
    }

    @Test("A pair opened from a session analyses and exports the session's span")
    func pairAndExportCarryTheSessionSpan() throws {
        let (store, anchor) = makeStore()
        let session = DateInterval(start: anchor.addingTimeInterval(5 * 60), end: anchor.addingTimeInterval(10 * 60 - 1))
        let snapshot = PairwiseSnapshot(
            store: store,
            kind: .heartRate,
            sourceA: ring.id,
            sourceB: strap.id,
            period: .fixed(session)
        )

        #expect(snapshot.interval == session)
        #expect(snapshot.analysis.range == session)
        #expect(snapshot.analysis.pairedWindowCount == 5)
        // Canonical order is preserved whichever way round the pair was requested.
        #expect(snapshot.analysis.sourceA == strap.id)

        let export = PairwiseExporter.makeExport(
            analysis: snapshot.analysis,
            sources: [strap, ring],
            appVersion: "test",
            generatedAt: .now
        )
        let summary = try #require(String(data: export.summaryData, encoding: .utf8))
        // The exporter's own formatting: ISO 8601, fractional seconds, UTC.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        #expect(summary.contains(
            "Selected range (UTC): \(iso.string(from: session.start)) to \(iso.string(from: session.end))"
        ))
    }

    @Test("Re-resolving a fixed period later still yields the same analysis")
    func fixedPeriodIsStableAcrossLoads() async throws {
        let (store, anchor) = makeStore()
        let session = DateInterval(start: anchor, end: anchor.addingTimeInterval(20 * 60))
        let first = PairwiseSnapshot(store: store, kind: .heartRate, sourceA: strap.id, sourceB: ring.id, period: .fixed(session))
        try await Task.sleep(for: .milliseconds(20))
        let second = PairwiseSnapshot(store: store, kind: .heartRate, sourceA: strap.id, sourceB: ring.id, period: .fixed(session))
        #expect(first.analysis == second.analysis)
    }

    #if DEBUG
    @Test("The demo session covers five of the demo's eight paired minutes")
    func demoSessionIsNarrowerThanTheRollingRange() {
        // The saved-session UI test reads "5 paired of 5" on the pair screen; the rolling
        // range it must not fall back to reads eight.
        let store = HealthStore(persistenceEnabled: false)
        let now = Date.now
        DebugAnalysisFixtures.populate(store: store, now: now)
        let session = DebugAnalysisFixtures.demoSession(now: now)

        let fixed = PairwiseSnapshot(
            store: store,
            kind: .heartRate,
            sourceA: DebugAnalysisFixtures.sourceAID,
            sourceB: DebugAnalysisFixtures.sourceBID,
            period: .fixed(session.interval)
        )
        #expect(fixed.analysis.pairedWindowCount == 5)
        #expect(fixed.analysis.candidateWindowCount == 5)

        let rolling = PairwiseSnapshot(
            store: store,
            kind: .heartRate,
            sourceA: DebugAnalysisFixtures.sourceAID,
            sourceB: DebugAnalysisFixtures.sourceBID,
            period: .rolling(.day)
        )
        #expect(rolling.analysis.pairedWindowCount == 8)
    }
    #endif
}
