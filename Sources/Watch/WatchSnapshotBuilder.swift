import Foundation

/// Builds the wrist projection using indexed latest/range queries and the real comparison
/// engine. A row limit bounds transport size, never the inputs to comparison statistics.
@MainActor
enum WatchSnapshotBuilder {
    static func make(store: HealthStore, now: Date = .now) -> WatchSnapshot {
        guard store.loadState == .loaded else {
            return WatchSnapshot(generatedAt: now, availability: .unavailable, metrics: [])
        }
        let sources = store.enabledSources
        let metrics = MetricKind.allCases.compactMap { kind -> WatchMetric? in
            let latest = sources.compactMap { source -> WatchSourceReading? in
                guard let reading = store.latest(kind: kind, sourceID: source.id),
                      reading.start <= now.addingTimeInterval(60)
                else { return nil }
                return WatchSourceReading(
                    id: UUID(stableFrom: source.id).uuidString,
                    sourceName: String(source.displayName.prefix(100)).isEmpty ? "Unknown device" : String(source.displayName.prefix(100)),
                    value: reading.value,
                    timestamp: reading.start,
                    provenance: reading.provenance,
                    isCompacted: reading.metadata?.aggregation != nil
                )
            }.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
            guard !latest.isEmpty else { return nil }
            // At least seven windows for daily metrics, and one hour for faster metrics.
            let lookback: TimeInterval = kind.comparisonWindow >= 86_400 ? 7 * 86_400 : 3_600
            let range = DateInterval(start: now.addingTimeInterval(-lookback), end: now)
            let analyses = ComparisonEngine.allPairwiseAnalyses(
                from: store.readings(kind: kind, in: range), kind: kind, range: range
            )
            let overview = PairwiseEvidenceOverview(analyses: analyses)
            return WatchMetric(
                kind: kind,
                readings: Array(latest.prefix(WatchSnapshot.maximumSourcesPerMetric)),
                omittedSourceCount: max(0, latest.count - WatchSnapshot.maximumSourcesPerMetric),
                comparison: WatchComparison(
                    readyPairs: overview.readyCount,
                    incompletePairs: overview.incompleteCount,
                    outsideTolerancePairs: overview.outsideToleranceCount,
                    lookback: lookback
                )
            )
        }
        return WatchSnapshot(generatedAt: now, metrics: metrics)
    }
}
