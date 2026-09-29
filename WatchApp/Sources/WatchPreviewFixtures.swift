#if DEBUG
import Foundation

/// Synthetic display data for previews and `--watch-demo`. Never written to the complication
/// cache and never a measurement.
enum WatchPreviewFixtures {
    private static let blue = WatchColor(red: 0.42, green: 0.65, blue: 1.00)
    private static let amber = WatchColor(red: 0.75, green: 0.46, blue: 0.00)
    private static let green = WatchColor(red: 0.67, green: 1.00, blue: 0.31)

    static func snapshot(now: Date = .now) -> WatchSnapshot {
        let lookback: TimeInterval = 6 * 3_600
        let bucket: TimeInterval = 480
        let start = Date(timeIntervalSince1970: (now.addingTimeInterval(-lookback).timeIntervalSince1970 / bucket).rounded(.down) * bucket)
        let count = Int(now.timeIntervalSince(start) / bucket)
        // A strap with a gap in the middle, and a watch reading a little high.
        let strapOffsets = (0..<count).filter { !(18...22).contains($0) }
        let strap = strapOffsets.map { 68 + 6 * sin(Double($0) / 5) }
        let watch = (0..<count).map { 70 + 6 * sin(Double($0) / 5) + (Double($0 % 3) - 1) }
        let differences = (0..<24).map { 2 * sin(Double($0)) - 2 }

        let heartChart = WatchChart(
            start: start,
            end: now,
            bucket: bucket,
            series: [
                WatchChartSeries(id: "demo.strap", sourceName: "Chest strap", color: blue, symbol: 0, isEstimated: false,
                                 offsets: strapOffsets.map { $0 * Int(bucket) }, values: strap.map(rounded)),
                WatchChartSeries(id: "demo.watch", sourceName: "Apple Watch via Health", color: amber, symbol: 1, isEstimated: false,
                                 offsets: (0..<count).map { $0 * Int(bucket) }, values: watch.map(rounded)),
            ],
            pair: WatchPairAgreement(
                sourceA: "Apple Watch via Health", sourceB: "Chest strap", pairedWindows: 31,
                meanBias: 2.1, lowerLimit: -1.4, upperLimit: 5.6, withinTolerance: true,
                differenceOffsets: (0..<24).map { $0 * 900 }, differences: differences.map(rounded)
            )
        )
        let ringOffsets = [3_600, 9_000, 14_400, 19_800]
        let pressureChart = WatchChart(
            start: start,
            end: now,
            bucket: 600,
            series: [
                WatchChartSeries(id: "demo.ring", sourceName: "R11M ring", color: green, symbol: 2, isEstimated: true,
                                 offsets: ringOffsets, values: [116, 114, 119, 114]),
            ],
            pair: nil
        )

        return WatchSnapshot(generatedAt: now, metrics: [
            WatchMetric(
                kind: .heartRate,
                readings: [
                    WatchSourceReading(id: "demo.strap", sourceName: "Chest strap", value: 72, timestamp: now.addingTimeInterval(-20), provenance: .measured, isCompacted: false),
                    WatchSourceReading(id: "demo.watch", sourceName: "Apple Watch via Health", value: 74, timestamp: now.addingTimeInterval(-70), provenance: .measured, isCompacted: false),
                ],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: lookback),
                chart: heartChart
            ),
            WatchMetric(
                kind: .bloodPressureSystolic,
                readings: [WatchSourceReading(id: "demo.ring", sourceName: "R11M ring", value: 114, timestamp: now.addingTimeInterval(-1_800), provenance: .estimated, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: lookback),
                chart: pressureChart
            ),
            WatchMetric(
                kind: .hrvRMSSD,
                readings: [WatchSourceReading(id: "demo.oura", sourceName: "Oura", value: 48, timestamp: now.addingTimeInterval(-7_200), provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: lookback)
            ),
        ])
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
#endif
