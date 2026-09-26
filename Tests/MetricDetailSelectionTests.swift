import Foundation
import Testing
@testable import HeartSyncChecker

/// The metric-detail chart's selection and callout (improvement 32).
///
/// The callout, the enlarged points, and the haptic tick all key on one looked-up window.
/// These pin that lookup and what it reports: every drawn window is reachable, a touch in
/// empty plot area selects nothing, and the callout's values are the chart's own window
/// medians, with estimates labelled and kept out of the spread.
@Suite("Metric-detail selection")
@MainActor
struct MetricDetailSelectionTests {

    /// On the one-minute grid, so window starts are exact minutes after it.
    private let origin = Date(timeIntervalSince1970: 1_699_999_980)
    private let strap = DataSource(id: "a-strap", displayName: "Strap", transport: .bluetooth, colorIndex: 0)
    private let ring = DataSource(id: "b-ring", displayName: "Ring", transport: .oura, colorIndex: 1)

    private var series: [SourceSeries] { MetricDetailSnapshot.makeSeries(for: [ring, strap]) }

    private func reading(
        _ sourceID: String,
        _ value: Double,
        minute: Double,
        provenance: Provenance = .measured,
        compacted: Bool = false
    ) -> Reading {
        Reading(
            sourceID: sourceID,
            kind: .heartRate,
            value: value,
            start: origin.addingTimeInterval(minute * 60 + 5),
            provenance: provenance,
            metadata: compacted
                ? ReadingMetadata(aggregation: AggregationMetadata(originalSampleCount: 60, originalStandardDeviation: 1.5))
                : nil
        )
    }

    private func projection(_ readings: [Reading], minutes: Double = 60) -> MetricChartProjection {
        let interval = DateInterval(start: origin, duration: minutes * 60)
        let windows = ComparisonEngine.windows(
            from: readings,
            kind: .heartRate,
            windowSize: 60,
            range: interval,
            includeEstimated: true
        )
        return MetricChartProjection(
            windows: windows,
            kind: .heartRate,
            interval: interval,
            bucketSize: 60,
            series: series
        )
    }

    @Test("Every drawn window can be selected, the first and the last included")
    func everyWindowIsReachable() throws {
        let readings = (0..<30).flatMap { minute in
            [reading(strap.id, 70, minute: Double(minute)), reading(ring.id, 72, minute: Double(minute))]
        }
        let chart = projection(readings)
        #expect(chart.windows.count == 30)
        for window in chart.windows {
            // A touch anywhere inside the window's half-bucket catchment snaps to it.
            let touch = window.start.addingTimeInterval(20)
            #expect(chart.window(nearest: touch, within: 60)?.start == window.start)
        }
        let first = try #require(chart.windows.first)
        let last = try #require(chart.windows.last)
        #expect(chart.window(nearest: origin.addingTimeInterval(-300))?.start == first.start)
        #expect(chart.window(nearest: origin.addingTimeInterval(86_400))?.start == last.start)
    }

    @Test("A touch in empty plot area selects nothing instead of jumping across the gap")
    func emptyAreaSelectsNothing() {
        let readings = [0.0, 1, 2, 40, 41].flatMap { minute in
            [reading(strap.id, 70, minute: minute), reading(ring.id, 71, minute: minute)]
        }
        let chart = projection(readings)
        let middleOfGap = origin.addingTimeInterval(20 * 60)
        // Twenty minutes from anything, with a two-minute catchment: nothing is selected.
        #expect(chart.window(nearest: middleOfGap, within: 120) == nil)
        // Without a tolerance (the chart not yet measured) it still snaps to the nearest.
        #expect(chart.window(nearest: middleOfGap) != nil)
        // Close to a window, the same catchment selects it.
        #expect(chart.window(nearest: origin.addingTimeInterval(40 * 60 + 20), within: 120)?.start
            == origin.addingTimeInterval(40 * 60))
    }

    @Test("The callout lists each device's window median in legend order, with its flags")
    func calloutValuesAreWindowMedians() throws {
        let readings = [
            reading(strap.id, 70, minute: 5),
            reading(strap.id, 80, minute: 5.2),
            reading(strap.id, 90, minute: 5.4),
            reading(ring.id, 75, minute: 5, compacted: true),
            reading("estimate", 99, minute: 5, provenance: .estimated),
        ]
        let chart = projection(readings)
        let window = try #require(chart.window(startingAt: origin.addingTimeInterval(300)))

        // Ring sorts before Strap in the legend, so it comes first here too.
        #expect(window.values.map(\.sourceID) == [ring.id, strap.id, "estimate"])
        // The strap's three samples are one median, as the chart draws it.
        #expect(window.values.first { $0.sourceID == strap.id }?.value == 80)
        #expect(window.values.first { $0.sourceID == ring.id }?.isCompacted == true)
        #expect(window.values.first { $0.sourceID == "estimate" }?.isEstimate == true)
        #expect(window.hasEstimate)
        #expect(window.hasCompacted)
        #expect(window.duration == 60)
        #expect(window.end == origin.addingTimeInterval(360))
    }

    @Test("An estimate never creates or widens the spread")
    func estimatesStayOutOfTheSpread() throws {
        let alone = projection([
            reading(strap.id, 70, minute: 0),
            reading("estimate", 140, minute: 0, provenance: .estimated),
        ])
        let lone = try #require(alone.windows.first)
        #expect(lone.spread == nil)
        #expect(alone.bandPoints.isEmpty)

        let compared = projection([
            reading(strap.id, 70, minute: 0),
            reading(ring.id, 76, minute: 0),
            reading("estimate", 140, minute: 0, provenance: .estimated),
        ])
        let spread = try #require(compared.windows.first?.spread)
        #expect(spread.low == 70)
        #expect(spread.high == 76)
        #expect(spread.width == 6)
        #expect(spread.severity == MetricKind.heartRate.agreement.severity(forDelta: 6))
    }

    @Test("The spread is described against the tolerances and never as agreement")
    func spreadWordingMakesNoAgreementClaim() {
        let kind = MetricKind.heartRate
        let within = ChartWindowSummary.Spread(low: 70, high: 72, severity: .agreeing).summary(for: kind)
        let notable = ChartWindowSummary.Spread(low: 70, high: 77, severity: .notable).summary(for: kind)
        let major = ChartWindowSummary.Spread(low: 70, high: 90, severity: .major).summary(for: kind)
        #expect(within == "Spread 2 bpm, under the 5 bpm tolerance")
        #expect(notable == "Spread 7 bpm, at or over the 5 bpm warning tolerance")
        #expect(major == "Spread 20 bpm, at or over the 12 bpm major tolerance")
        // A single window is not evidence of agreement, whatever its colour.
        for text in [within, notable, major] {
            #expect(!text.localizedCaseInsensitiveContains("agree"))
        }
        let compacted = projection([reading(strap.id, 70, minute: 0, compacted: true)])
        #expect(compacted.points.first?.isCompacted == true)
    }

    @Test("The callout's spread is the band drawn at that window")
    func spreadMatchesTheBand() {
        let readings = (0..<10).flatMap { minute in
            [reading(strap.id, 70, minute: Double(minute)), reading(ring.id, 70 + Double(minute), minute: Double(minute))]
        }
        let chart = projection(readings)
        for window in chart.windows {
            let band = chart.bandPoints.first { $0.date == window.start }
            #expect(band?.low == window.spread?.low)
            #expect(band?.high == window.spread?.high)
            #expect(band?.severity == window.spread?.severity)
        }
    }

    @Test("Exact-start lookup finds drawn windows and forgets a stale selection")
    func exactStartLookup() {
        let chart = projection([reading(strap.id, 70, minute: 0), reading(strap.id, 71, minute: 3)])
        for window in chart.windows {
            #expect(chart.window(startingAt: window.start) == window)
        }
        #expect(chart.window(startingAt: nil) == nil)
        #expect(chart.window(startingAt: origin.addingTimeInterval(61)) == nil)
    }

    @Test("The x domain is the whole span, so an empty stretch stays visibly empty")
    func xDomainIsPinnedToTheSpan() throws {
        // Data only in the last ten minutes of a six-hour span.
        let chart = projection(
            (350..<360).map { reading(strap.id, 70, minute: Double($0)) },
            minutes: 360
        )
        #expect(chart.xDomain.lowerBound == origin)
        #expect(chart.xDomain.upperBound == origin.addingTimeInterval(360 * 60))
        let first = try #require(chart.windows.first)
        #expect(first.start >= chart.xDomain.lowerBound)
        #expect(chart.windows.allSatisfy { chart.xDomain.contains($0.start) })
    }

    @Test("An unaligned span widens back to its first bucket, so its first window stays inside the plot")
    func xDomainStartsOnTheBucketGrid() {
        let interval = DateInterval(start: origin.addingTimeInterval(37), duration: 3_600)
        let windows = ComparisonEngine.windows(
            from: [reading(strap.id, 70, minute: 1)],
            kind: .heartRate,
            windowSize: 60,
            range: interval
        )
        let chart = MetricChartProjection(windows: windows, kind: .heartRate, interval: interval, bucketSize: 60, series: series)
        #expect(chart.xDomain.lowerBound == origin)
        #expect(chart.windows.allSatisfy { $0.start >= chart.xDomain.lowerBound })
    }

    @Test("The snapshot draws through the same projection its callout reads")
    func snapshotForwardsItsChart() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(ring)
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-40 * 60), size: 60)
        for minute in 0..<20 {
            let stamp = anchor.addingTimeInterval(Double(minute) * 60 + 3)
            _ = store.append(Reading(sourceID: strap.id, kind: .heartRate, value: 70, start: stamp))
            _ = store.append(Reading(sourceID: ring.id, kind: .heartRate, value: 73, start: stamp.addingTimeInterval(4)))
        }
        let snapshot = MetricDetailSnapshot(store: store, kind: .heartRate, range: .hour, includeEstimates: false, hrvQuality: [:])
        #expect(snapshot.points.map(\.id) == snapshot.chart.points.map(\.id))
        #expect(snapshot.bandPoints.map(\.id) == snapshot.chart.bandPoints.map(\.id))
        #expect(snapshot.bucketSize == 60)
        #expect(snapshot.chart.windows.count == 20)
        #expect(snapshot.chart.windows.allSatisfy { $0.spread?.width == 3 })
        // Labels in the callout are the legend's labels.
        let labels = Set(snapshot.series.map(\.label))
        #expect(snapshot.chart.windows.allSatisfy { window in window.values.allSatisfy { labels.contains($0.label) } })
    }

    // MARK: - Shared lookups

    @Test("Screen points convert to seconds on a date axis, and not before the chart is measured")
    func timeTolerance() {
        let domain = origin...origin.addingTimeInterval(3_600)
        #expect(ChartLookup.timeTolerance(points: 22, plotWidth: 330, domain: domain) == 240)
        #expect(ChartLookup.timeTolerance(points: 22, plotWidth: 0, domain: domain) == nil)
        #expect(ChartLookup.timeTolerance(points: 22, plotWidth: 330, domain: origin...origin) == nil)
    }

    @Test("Last-at-or-before finds the run a moment falls in")
    func lastIndexAtOrBefore() {
        let starts: [Double] = [0, 10, 20]
        #expect(ChartLookup.lastIndex(atOrBefore: -1, in: starts) == nil)
        #expect(ChartLookup.lastIndex(atOrBefore: 0, in: starts) == 0)
        #expect(ChartLookup.lastIndex(atOrBefore: 9.9, in: starts) == 0)
        #expect(ChartLookup.lastIndex(atOrBefore: 10, in: starts) == 1)
        #expect(ChartLookup.lastIndex(atOrBefore: 99, in: starts) == 2)
        #expect(ChartLookup.lastIndex(atOrBefore: 5, in: []) == nil)
    }
}
