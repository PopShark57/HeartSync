import Foundation

/// Builds the wrist projection using indexed latest/range queries and the real comparison
/// engine. A row limit bounds transport size, never the inputs to comparison statistics.
@MainActor
enum WatchSnapshotBuilder {
    /// About this many chart windows per source and period.
    static let targetChartPoints = 30

    /// The period of `WatchMetric.chart` and `WatchMetric.comparison`: 24 hours for fast
    /// metrics, seven days for daily ones.
    static func standardRange(for kind: MetricKind) -> WatchChartRange {
        WatchChartRange.resolved(.standard, among: WatchChartRange.available(for: kind)) ?? .month
    }

    /// The chart window: a whole multiple of the comparison window, so every paired window
    /// falls inside exactly one chart window and no difference plots before the chart starts.
    static func chartBucket(for kind: MetricKind, range: WatchChartRange) -> TimeInterval {
        let window = kind.comparisonWindow
        let multiple = (range.duration / Double(targetChartPoints) / window).rounded(.up)
        return window * max(1, multiple)
    }

    static func make(store: HealthStore, now: Date = .now, cache: WatchChartCache? = nil) -> WatchSnapshot {
        guard store.loadState == .loaded else {
            return WatchSnapshot(generatedAt: now, availability: .unavailable, metrics: [])
        }
        let sources = store.enabledSources
        let enabledIDs = sources.map(\.id).sorted().joined(separator: ",")
        let metrics = MetricKind.allCases.compactMap { kind -> WatchMetric? in
            let latest = sources.compactMap { source -> (source: DataSource, reading: WatchSourceReading)? in
                guard let reading = store.latest(kind: kind, sourceID: source.id),
                      reading.start <= now.addingTimeInterval(60)
                else { return nil }
                return (source, WatchSourceReading(
                    id: watchID(for: source),
                    sourceName: displayName(source),
                    value: reading.value,
                    timestamp: reading.start,
                    provenance: reading.provenance,
                    isCompacted: reading.metadata?.aggregation != nil
                ))
            }.sorted {
                if $0.reading.timestamp != $1.reading.timestamp { return $0.reading.timestamp > $1.reading.timestamp }
                return $0.reading.id < $1.reading.id
            }
            guard !latest.isEmpty else { return nil }
            let shown = Array(latest.prefix(WatchSnapshot.maximumSourcesPerMetric))
            let shownSources = shown.map(\.source)
            // Anything that changes what a cached period would draw or compare.
            let fingerprint = enabledIDs + "|" + shownSources
                .map { "\($0.id)\u{001F}\($0.displayName)\u{001F}\($0.colorIndex)" }
                .joined(separator: "\u{001E}")

            let ranges = WatchChartRange.available(for: kind)
            var results: [WatchChartRange: PeriodResult] = [:]
            for range in ranges {
                let key = WatchChartCache.Key(kind: kind, range: range)
                if let cached = cache?.result(for: key, now: now, fingerprint: fingerprint, removals: store.removalGeneration) {
                    results[range] = cached
                    continue
                }
                let result = period(kind: kind, range: range, now: now, shown: shownSources, store: store)
                cache?.store(result, for: key, at: now, fingerprint: fingerprint, removals: store.removalGeneration)
                results[range] = result
            }
            let standard = standardRange(for: kind)
            let primary = results[standard]
            return WatchMetric(
                kind: kind,
                readings: shown.map(\.reading),
                omittedSourceCount: max(0, latest.count - WatchSnapshot.maximumSourcesPerMetric),
                comparison: primary?.comparison ?? WatchComparison(
                    readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: standard.duration
                ),
                chart: primary?.chart,
                rangeCharts: ranges.filter { $0 != standard }.compactMap { results[$0]?.chart },
                availableRanges: ranges
            )
        }
        return fitted(WatchSnapshot(generatedAt: now, metrics: metrics))
    }

    // MARK: Periods

    /// One period's evidence and chart. The chart is nil only when neither a shown source
    /// nor any pair has data in the period.
    struct PeriodResult: Equatable, Sendable {
        var comparison: WatchComparison
        var chart: WatchChart?
    }

    static func period(
        kind: MetricKind,
        range: WatchChartRange,
        now: Date,
        shown: [DataSource],
        store: HealthStore
    ) -> PeriodResult {
        let interval = DateInterval(start: now.addingTimeInterval(-range.duration), end: now)
        let readings = store.readings(kind: kind, in: interval)
        let analyses = ComparisonEngine.allPairwiseAnalyses(from: readings, kind: kind, range: interval)
        let overview = PairwiseEvidenceOverview(analyses: analyses)
        let comparison = WatchComparison(
            readyPairs: overview.readyCount,
            incompletePairs: overview.incompleteCount,
            outsideTolerancePairs: overview.outsideToleranceCount,
            lookback: range.duration
        )
        var chart = self.chart(
            kind: kind,
            range: range,
            readings: readings,
            interval: interval,
            analyses: analyses,
            shown: shown,
            store: store
        )
        chart?.comparison = comparison
        return PeriodResult(comparison: comparison, chart: chart)
    }

    // MARK: Charts

    /// Window medians for each displayed source, estimates included and marked, plus the
    /// agreement of the most informative ready pair.
    static func chart(
        kind: MetricKind,
        range: WatchChartRange,
        readings: [Reading],
        interval: DateInterval,
        analyses: [PairwiseAnalysis],
        shown: [DataSource],
        store: HealthStore
    ) -> WatchChart? {
        let bucket = chartBucket(for: kind, range: range)
        let start = Date(timeIntervalSince1970: (interval.start.timeIntervalSince1970 / bucket).rounded(.down) * bucket)
        guard start < interval.end else { return nil }
        let windows = ComparisonEngine.windows(
            from: readings,
            kind: kind,
            windowSize: bucket,
            range: interval,
            includeEstimated: true
        )
        // The iPhone's rule: past six devices two sources can share a colour, and then the
        // later one takes a free shape, so they never look identical.
        let symbols = MetricDetailSnapshot.symbols(for: shown)
        let series = zip(shown, symbols).compactMap { source, symbol -> WatchChartSeries? in
            var offsets: [Int] = []
            var values: [Double] = []
            var estimated = false
            for window in windows {
                guard let value = window.value(for: source.id) else { continue }
                let rounded = roundedTenth(value.value)
                guard kind.plausibleRange.contains(rounded) else { continue }
                offsets.append(offset(window.start, from: start))
                values.append(rounded)
                estimated = estimated || value.provenance == .estimated
            }
            guard !values.isEmpty else { return nil }
            let count = DataSource.paletteSlots.count
            let slot = DataSource.paletteSlots[((source.colorIndex % count) + count) % count]
            return WatchChartSeries(
                id: watchID(for: source),
                sourceName: displayName(source),
                color: WatchColor(red: slot.dark.red, green: slot.dark.green, blue: slot.dark.blue),
                symbol: symbol.rawValue,
                isEstimated: estimated,
                offsets: offsets,
                values: values
            )
        }
        guard !series.isEmpty || !analyses.isEmpty else { return nil }
        return WatchChart(
            start: start,
            end: interval.end,
            bucket: bucket,
            series: series,
            pair: pairAgreement(analyses: analyses, chartStart: start, store: store),
            range: range
        )
    }

    /// A pair outside tolerance comes first, the widest gap leading, because that is what
    /// the wrist most needs to show. Otherwise the pair with the most paired windows.
    static func pairAgreement(
        analyses: [PairwiseAnalysis],
        chartStart: Date,
        store: HealthStore
    ) -> WatchPairAgreement? {
        let ready = analyses.compactMap { analysis -> (PairwiseAnalysis, PairwiseSummaryStatistics)? in
            analysis.statistics.map { (analysis, $0) }
        }
        let chosen = ready.max { lhs, rhs in
            let lhsOutside = lhs.1.severity != .agreeing
            let rhsOutside = rhs.1.severity != .agreeing
            if lhsOutside != rhsOutside { return rhsOutside }
            if lhsOutside { return lhs.1.meanAbsoluteDifference < rhs.1.meanAbsoluteDifference }
            if lhs.0.pairedWindowCount != rhs.0.pairedWindowCount {
                return lhs.0.pairedWindowCount < rhs.0.pairedWindowCount
            }
            // Deterministic between equals: the canonical pair order.
            return (lhs.0.sourceA, lhs.0.sourceB) > (rhs.0.sourceA, rhs.0.sourceB)
        }
        guard let chosen, chosen.0.pairedWindowCount >= WatchPairAgreement.minimumPairedWindows else { return nil }
        let (analysis, statistics) = chosen
        let plotted = analysis.plotSample(limit: 32, extremes: 4)
            .suffix(WatchChart.maximumDifferencePoints)
        return WatchPairAgreement(
            sourceA: String(store.displayName(forSource: analysis.sourceA).prefix(100)),
            sourceB: String(store.displayName(forSource: analysis.sourceB).prefix(100)),
            pairedWindows: analysis.pairedWindowCount,
            meanBias: statistics.meanBias,
            lowerLimit: statistics.limitsOfAgreement.lowerBound,
            upperLimit: statistics.limitsOfAgreement.upperBound,
            withinTolerance: statistics.severity == .agreeing,
            differenceOffsets: plotted.map { max(0, offset($0.start, from: chartStart)) },
            differences: plotted.map { roundedTenth($0.signedDifference) }
        )
    }

    /// Longest periods are dropped first, from the last metric backwards, so the payload
    /// stays under its cap. Readings, the default comparison, and the period list always
    /// travel; a dropped period shows "open HeartSync on iPhone" rather than a false empty.
    static let dropOrder: [WatchChartRange] = [.month, .week, .hour, .day]

    static func fitted(_ snapshot: WatchSnapshot) -> WatchSnapshot {
        var snapshot = snapshot
        guard (try? snapshot.encoded()) == nil else { return snapshot }
        for range in dropOrder {
            for index in snapshot.metrics.indices.reversed() {
                guard snapshot.metrics[index].periodChart(range) != nil
                        || (range == .day && snapshot.metrics[index].chart != nil)
                else { continue }
                remove(range, from: &snapshot.metrics[index])
                if (try? snapshot.encoded()) != nil { return snapshot }
            }
        }
        // Still invalid: drop every chart, including any the rules above did not reach.
        for index in snapshot.metrics.indices {
            snapshot.metrics[index].chart = nil
            snapshot.metrics[index].rangeCharts = nil
            snapshot.metrics[index].availableRanges = nil
        }
        return snapshot
    }

    private static func remove(_ range: WatchChartRange, from metric: inout WatchMetric) {
        if metric.chart?.range == range || (range == .day && metric.chart?.range == nil) {
            metric.chart = nil
        }
        metric.rangeCharts?.removeAll { $0.range == range }
        // The period is no longer described, so it must not read as "no readings".
        let stillDrawn = metric.periodChart(range) != nil
        if !stillDrawn {
            metric.availableRanges?.removeAll { $0 == range }
        }
    }

    // MARK: Helpers

    private static func watchID(for source: DataSource) -> String {
        UUID(stableFrom: source.id).uuidString
    }

    private static func displayName(_ source: DataSource) -> String {
        let name = String(source.displayName.prefix(100))
        return name.isEmpty ? "Unknown device" : name
    }

    private static func offset(_ date: Date, from start: Date) -> Int {
        Int(date.timeIntervalSince(start).rounded(.down))
    }

    private static func roundedTenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}

/// Keeps the slower periods between publications. The watch payload is rebuilt at most every
/// 30 seconds; re-reading 30 days of a 1 Hz sensor that often would stall the main actor.
///
/// A period is reused until its refresh interval passes, the shown or enabled sources change
/// (rename, hide, colour), or the store removes anything (`removalGeneration`: deletions,
/// source removal, retention, reset, reload). New readings alone wait for the interval; each
/// chart's `end` tells the wrist how current it is.
@MainActor
final class WatchChartCache {
    struct Key: Hashable, Sendable {
        var kind: MetricKind
        var range: WatchChartRange
    }

    private struct Entry {
        var result: WatchSnapshotBuilder.PeriodResult
        var builtAt: Date
        var fingerprint: String
        var removals: Int
    }

    private var entries: [Key: Entry] = [:]

    static func refreshInterval(for range: WatchChartRange) -> TimeInterval {
        switch range {
        case .hour:  0
        case .day:   2 * 60
        case .week:  15 * 60
        case .month: 60 * 60
        }
    }

    func result(for key: Key, now: Date, fingerprint: String, removals: Int) -> WatchSnapshotBuilder.PeriodResult? {
        guard let entry = entries[key],
              entry.fingerprint == fingerprint,
              entry.removals == removals,
              now >= entry.builtAt,
              now.timeIntervalSince(entry.builtAt) < Self.refreshInterval(for: key.range)
        else { return nil }
        return entry.result
    }

    func store(_ result: WatchSnapshotBuilder.PeriodResult, for key: Key, at now: Date, fingerprint: String, removals: Int) {
        entries[key] = Entry(result: result, builtAt: now, fingerprint: fingerprint, removals: removals)
    }

    func removeAll() {
        entries.removeAll()
    }
}
