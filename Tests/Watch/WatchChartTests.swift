import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Watch comparison charts")
@MainActor
struct WatchChartTests {
    /// 2026-09-29T12:00:00Z, a whole number of 480-second windows since the epoch.
    private let now = Date(timeIntervalSince1970: 1_790_683_200)

    private func populate(
        _ store: HealthStore,
        sourceID: String,
        kind: MetricKind = .heartRate,
        value: Double,
        minutes: Int = 30,
        provenance: Provenance = .measured
    ) {
        if store.source(id: sourceID) == nil {
            store.upsert(DataSource(id: sourceID, displayName: "Source \(sourceID)", transport: .bluetooth))
        }
        for index in 1...minutes {
            store.append(Reading(
                sourceID: sourceID,
                kind: kind,
                value: value,
                start: now.addingTimeInterval(-Double(index) * 60),
                provenance: provenance
            ))
        }
    }

    private func chartFixture() -> WatchSnapshot {
        let start = now.addingTimeInterval(-6 * 3_600)
        let chart = WatchChart(
            start: start,
            end: now,
            bucket: 480,
            series: [WatchChartSeries(
                id: "strap", sourceName: "Chest strap",
                color: WatchColor(red: 0.42, green: 0.65, blue: 1), symbol: 0, isEstimated: false,
                offsets: [0, 480, 1_440], values: [70, 71.5, 72]
            )],
            pair: WatchPairAgreement(
                sourceA: "Chest strap", sourceB: "Ring", pairedWindows: 6,
                meanBias: 1.5, lowerLimit: -1, upperLimit: 4, withinTolerance: true,
                differenceOffsets: [60, 120], differences: [1, 2]
            )
        )
        return WatchSnapshot(generatedAt: now, metrics: [
            WatchMetric(
                kind: .heartRate,
                readings: [WatchSourceReading(id: "strap", sourceName: "Chest strap", value: 72, timestamp: now.addingTimeInterval(-5), provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 6 * 3_600),
                chart: chart
            ),
        ])
    }

    // MARK: Payload

    @Test("Charts round-trip, and payloads from either older app still decode")
    func compatibility() throws {
        let snapshot = chartFixture()
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)

        // An older iPhone sends no chart key.
        var withoutChart = snapshot
        withoutChart.metrics[0].chart = nil
        let old = try withoutChart.encoded()
        #expect(String(decoding: old, as: UTF8.self).contains("\"chart\"") == false)
        #expect(try WatchSnapshot.decode(old).metrics[0].chart == nil)

        // An older watch ignores keys it does not know; so does this one.
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object["futureField"] = ["anything": 1]
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(try WatchSnapshot.decode(future).metrics.count == 1)
    }

    @Test("Chart points outside the period, broken series, and thin pairs are rejected")
    func invalidCharts() {
        func rejected(_ change: (inout WatchChart) -> Void) -> Bool {
            var snapshot = chartFixture()
            var chart = snapshot.metrics[0].chart!
            change(&chart)
            snapshot.metrics[0].chart = chart
            return (try? snapshot.encoded()) == nil
        }
        #expect(rejected { $0.series[0].offsets[2] = 30_000 })
        #expect(rejected { $0.series[0].offsets.removeLast() })
        #expect(rejected { $0.series[0].values[0] = 900 })
        #expect(rejected { $0.series[0].symbol = 6 })
        #expect(rejected { $0.series[0].color.red = 2 })
        #expect(rejected { $0.series.append($0.series[0]) })
        #expect(rejected { $0.pair?.pairedWindows = 4 })
        #expect(rejected { $0.pair?.lowerLimit = 10 })
        #expect(rejected { $0.bucket = 0 })
        #expect(rejected { $0.end = $0.start })
    }

    @Test("The wire threshold for a pair equals the comparison engine's")
    func thresholdsMatch() {
        #expect(WatchPairAgreement.minimumPairedWindows == ComparisonEngine.minimumPairedWindows)
        #expect(WatchSourceShape.allCases.count == SourceSymbol.allCases.count)
    }

    // MARK: Builder

    @Test("Periods and chart windows: six hours for fast metrics, seven days for daily ones")
    func periods() {
        #expect(WatchSnapshotBuilder.lookback(for: .heartRate) == 6 * 3_600)
        #expect(WatchSnapshotBuilder.lookback(for: .restingHeartRate) == 7 * 86_400)
        #expect(WatchSnapshotBuilder.chartBucket(for: .heartRate) == 480)
        #expect(WatchSnapshotBuilder.chartBucket(for: .hrvRMSSD) == 600)
        #expect(WatchSnapshotBuilder.chartBucket(for: .bloodPressureSystolic) == 600)
        #expect(WatchSnapshotBuilder.chartBucket(for: .restingHeartRate) == 86_400)
        for kind in MetricKind.allCases {
            let bucket = WatchSnapshotBuilder.chartBucket(for: kind)
            #expect(bucket.truncatingRemainder(dividingBy: kind.comparisonWindow) == 0)
            #expect(WatchSnapshotBuilder.lookback(for: kind) / bucket <= Double(WatchChart.maximumPoints - 1))
        }
    }

    @Test("Each shown source gets its palette colour, shape, and window medians; the pair is A minus B")
    func builderSeries() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70)
        populate(store, sourceID: "b", value: 74)
        let snapshot = WatchSnapshotBuilder.make(store: store, now: now)
        let metric = try #require(snapshot.metrics.first { $0.kind == .heartRate })
        let chart = try #require(metric.chart)
        #expect(metric.comparison.lookback == 6 * 3_600)
        #expect(chart.end == now)
        #expect(chart.series.count == 2)
        #expect(Set(chart.series.map(\.id)) == Set(metric.readings.map(\.id)))

        let sourceA = try #require(store.source(id: "a"))
        let seriesA = try #require(chart.series.first { $0.sourceName == "Source a" })
        let slot = DataSource.paletteSlots[sourceA.colorIndex % DataSource.paletteSlots.count]
        #expect(seriesA.color == WatchColor(red: slot.dark.red, green: slot.dark.green, blue: slot.dark.blue))
        #expect(seriesA.symbol == SourceSymbol.forColorIndex(sourceA.colorIndex).rawValue)
        #expect(seriesA.values.allSatisfy { $0 == 70 })
        #expect(seriesA.offsets.allSatisfy { $0 >= 0 && $0 % 480 == 0 })
        #expect(!seriesA.isEstimated)

        let pair = try #require(chart.pair)
        #expect(pair.sourceA == "Source a")
        #expect(pair.meanBias == -4)
        #expect(pair.pairedWindows == 30)
        #expect(pair.withinTolerance)
        #expect(pair.differences.allSatisfy { $0 == -4 })
        #expect(pair.differenceOffsets.allSatisfy { $0 >= 0 })
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)
    }

    @Test("Estimates are charted and marked, but never form the pair")
    func estimatesMarked() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "ring", kind: .bloodPressureSystolic, value: 114, provenance: .estimated)
        populate(store, sourceID: "cuff", kind: .bloodPressureSystolic, value: 118)
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first { $0.kind == .bloodPressureSystolic })
        let chart = try #require(metric.chart)
        #expect(chart.series.first { $0.sourceName == "Source ring" }?.isEstimated == true)
        #expect(chart.series.first { $0.sourceName == "Source cuff" }?.isEstimated == false)
        #expect(chart.pair == nil)
        #expect(metric.comparison.readyPairs == 0)
    }

    @Test("Fewer than five paired windows send no pair figures")
    func thinPairOmitted() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, minutes: 4)
        populate(store, sourceID: "b", value: 72, minutes: 4)
        let chart = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first?.chart)
        #expect(chart.pair == nil)
    }

    @Test("A pair outside tolerance is chosen over a larger pair inside it")
    func outsideTolerancePreferred() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, minutes: 60)
        populate(store, sourceID: "b", value: 71, minutes: 60)
        populate(store, sourceID: "c", value: 90, minutes: 10)
        let pair = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first?.chart?.pair)
        #expect(!pair.withinTolerance)
        #expect(pair.sourceB == "Source c")
    }

    @Test("A chart that cannot be sent is dropped; the readings and verdict still travel")
    func fittedDropsCharts() throws {
        var snapshot = chartFixture()
        snapshot.metrics[0].chart?.series[0].offsets[0] = -1
        let fitted = WatchSnapshotBuilder.fitted(snapshot)
        #expect(fitted.metrics[0].chart == nil)
        #expect(fitted.metrics[0].readings == snapshot.metrics[0].readings)
        #expect((try? fitted.encoded()) != nil)
    }

    // MARK: Projection

    @Test("Lines break at missing windows and lone windows are points")
    func segmentation() throws {
        let chart = try #require(chartFixture().metrics[0].chart)
        let points = WatchChartProjection.points(for: chart.series[0], in: chart)
        #expect(points.map(\.segment) == [0, 0, 1])
        #expect(points.map(\.isIsolated) == [false, false, true])
        #expect(points[0].date == chart.start.addingTimeInterval(240))
        #expect(Set(points.map(\.segmentKey)).count == 2)
    }

    @Test("Axes include the usual range, every value, zero, and both limits")
    func domains() throws {
        let chart = try #require(chartFixture().metrics[0].chart)
        let values = WatchChartProjection.valueDomain(kind: .heartRate, chart: chart)
        #expect(values.lowerBound <= 40 && values.upperBound >= 160)
        let pair = try #require(chart.pair)
        let differences = WatchChartProjection.differenceDomain(pair: pair)
        #expect(differences.contains(0) && differences.contains(pair.lowerLimit) && differences.contains(pair.upperLimit))
    }

    @Test("Spoken summaries name each source and the pair without claiming agreement")
    func spoken() throws {
        let chart = try #require(chartFixture().metrics[0].chart)
        let summary = WatchChartProjection.spokenSummary(kind: .heartRate, chart: chart, lookback: 6 * 3_600)
        #expect(summary.contains("Chest strap"))
        #expect(summary.contains("3 windows"))
        let pair = WatchChartProjection.pairSummary(kind: .heartRate, pair: try #require(chart.pair))
        #expect(pair.contains("Chest strap minus Ring"))
        #expect(pair.contains("6 paired windows"))
        #expect(!pair.lowercased().contains("agree"))
        #expect(WatchChartProjection.periodText(6 * 3_600) == "Past 6 hours")
        #expect(WatchChartProjection.periodText(7 * 86_400) == "Past 7 days")
        #expect(WatchChartProjection.periodText(3_600) == "Past hour")
    }
}
