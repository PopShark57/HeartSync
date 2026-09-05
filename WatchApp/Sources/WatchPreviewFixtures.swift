#if DEBUG
import Foundation

enum WatchPreviewFixtures {
    static func snapshot(now: Date = .now) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, metrics: [
            WatchMetric(
                kind: .heartRate,
                readings: [
                    WatchSourceReading(id: "demo.strap", sourceName: "Chest strap", value: 72, timestamp: now.addingTimeInterval(-20), provenance: .measured, isCompacted: false),
                    WatchSourceReading(id: "demo.watch", sourceName: "Apple Watch via Health", value: 74, timestamp: now.addingTimeInterval(-70), provenance: .measured, isCompacted: false),
                ],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
            ),
            WatchMetric(
                kind: .hrvRMSSD,
                readings: [WatchSourceReading(id: "demo.oura", sourceName: "Oura", value: 48, timestamp: now.addingTimeInterval(-7_200), provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
            ),
        ])
    }
}
#endif
