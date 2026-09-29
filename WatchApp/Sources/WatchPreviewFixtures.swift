#if DEBUG
import Foundation

/// Synthetic display data for previews and `--watch-demo`. Never written to the complication
/// cache and never a measurement.
enum WatchPreviewFixtures {
    private static let blue = WatchColor(red: 0.42, green: 0.65, blue: 1.00)
    private static let amber = WatchColor(red: 0.75, green: 0.46, blue: 0.00)
    private static let green = WatchColor(red: 0.67, green: 1.00, blue: 0.31)

    /// A strap with a gap, and a watch reading a little high, over one period.
    private static func heartChart(_ range: WatchChartRange, now: Date) -> WatchChart {
        let bucket = (range.duration / 30 / 60).rounded(.up) * 60
        let start = Date(timeIntervalSince1970: (now.addingTimeInterval(-range.duration).timeIntervalSince1970 / bucket).rounded(.down) * bucket)
        let count = Int(now.timeIntervalSince(start) / bucket)
        let strapIndices = (0..<count).filter { !(12...15).contains($0) }
        let strap = strapIndices.map { 68 + 6 * sin(Double($0) / 4) }
        let watch = (0..<count).map { 70 + 6 * sin(Double($0) / 4) + (Double($0 % 3) - 1) }
        let differences = (0..<20).map { 2 * sin(Double($0)) - 2 }
        let comparison = WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: range.duration)
        return WatchChart(
            start: start,
            end: now,
            bucket: bucket,
            series: [
                WatchChartSeries(id: "demo.strap", sourceName: "Chest strap", color: blue, symbol: 0, isEstimated: false,
                                 offsets: strapIndices.map { $0 * Int(bucket) }, values: strap.map(rounded)),
                WatchChartSeries(id: "demo.watch", sourceName: "Apple Watch via Health", color: amber, symbol: 1, isEstimated: false,
                                 offsets: (0..<count).map { $0 * Int(bucket) }, values: watch.map(rounded)),
            ],
            pair: WatchPairAgreement(
                sourceA: "Apple Watch via Health", sourceB: "Chest strap", pairedWindows: 26,
                meanBias: 2.1, lowerLimit: -1.4, upperLimit: 5.6, withinTolerance: true,
                differenceOffsets: (0..<20).map { $0 * Int(bucket) }, differences: differences.map(rounded)
            ),
            range: range,
            comparison: comparison
        )
    }

    static func snapshot(now: Date = .now) -> WatchSnapshot {
        let pressureChart = WatchChart(
            start: now.addingTimeInterval(-86_400),
            end: now,
            bucket: 3_000,
            series: [
                WatchChartSeries(id: "demo.ring", sourceName: "R11M ring", color: green, symbol: 2, isEstimated: true,
                                 offsets: [9_000, 30_000, 54_000, 81_000], values: [116, 114, 119, 114]),
            ],
            pair: nil,
            range: .day,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400)
        )

        return WatchSnapshot(generatedAt: now, metrics: [
            WatchMetric(
                kind: .heartRate,
                readings: [
                    WatchSourceReading(id: "demo.strap", sourceName: "Chest strap", value: 72, timestamp: now.addingTimeInterval(-20), provenance: .measured, isCompacted: false),
                    WatchSourceReading(id: "demo.watch", sourceName: "Apple Watch via Health", value: 74, timestamp: now.addingTimeInterval(-70), provenance: .measured, isCompacted: false),
                ],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400),
                chart: heartChart(.day, now: now),
                rangeCharts: [heartChart(.hour, now: now), heartChart(.week, now: now), heartChart(.month, now: now)],
                availableRanges: WatchChartRange.allCases
            ),
            WatchMetric(
                kind: .bloodPressureSystolic,
                readings: [WatchSourceReading(id: "demo.ring", sourceName: "R11M ring", value: 114, timestamp: now.addingTimeInterval(-1_800), provenance: .estimated, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400),
                chart: pressureChart,
                rangeCharts: [],
                availableRanges: WatchChartRange.allCases
            ),
            WatchMetric(
                kind: .hrvRMSSD,
                readings: [WatchSourceReading(id: "demo.oura", sourceName: "Oura", value: 48, timestamp: now.addingTimeInterval(-7_200), provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400)
            ),
        ])
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
#endif
