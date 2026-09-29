import Foundation

/// Builds the wrist projection using indexed latest/range queries and the real comparison
/// engine. A row limit bounds transport size, never the inputs to comparison statistics.
@MainActor
enum WatchSnapshotBuilder {
    /// The period the wrist compares and charts: the past six hours for fast metrics, and at
    /// least seven windows for daily ones. Six hours keeps a 1 Hz source's read bounded on
    /// the 30-second publication cadence while still showing a morning's spot readings.
    static func lookback(for kind: MetricKind) -> TimeInterval {
        kind.comparisonWindow >= 86_400 ? 7 * 86_400 : 6 * 3_600
    }

    /// About this many chart windows per source.
    static let targetChartPoints = 48

    /// The chart window: a whole multiple of the comparison window, so every paired window
    /// falls inside exactly one chart window and no difference plots before the chart starts.
    static func chartBucket(for kind: MetricKind) -> TimeInterval {
        let window = kind.comparisonWindow
        let multiple = (lookback(for: kind) / Double(targetChartPoints) / window).rounded(.up)
        return window * max(1, multiple)
    }

    static func make(store: HealthStore, now: Date = .now) -> WatchSnapshot {
        guard store.loadState == .loaded else {
            return WatchSnapshot(generatedAt: now, availability: .unavailable, metrics: [])
        }
        let sources = store.enabledSources
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
            let period = Self.lookback(for: kind)
            let range = DateInterval(start: now.addingTimeInterval(-period), end: now)
            let readings = store.readings(kind: kind, in: range)
            let analyses = ComparisonEngine.allPairwiseAnalyses(from: readings, kind: kind, range: range)
            let overview = PairwiseEvidenceOverview(analyses: analyses)
            let shown = Array(latest.prefix(WatchSnapshot.maximumSourcesPerMetric))
            return WatchMetric(
                kind: kind,
                readings: shown.map(\.reading),
                omittedSourceCount: max(0, latest.count - WatchSnapshot.maximumSourcesPerMetric),
                comparison: WatchComparison(
                    readyPairs: overview.readyCount,
                    incompletePairs: overview.incompleteCount,
                    outsideTolerancePairs: overview.outsideToleranceCount,
                    lookback: period
                ),
                chart: chart(
                    kind: kind,
                    readings: readings,
                    range: range,
                    analyses: analyses,
                    shown: shown.map(\.source),
                    store: store
                )
            )
        }
        return fitted(WatchSnapshot(generatedAt: now, metrics: metrics))
    }

    // MARK: Charts

    /// Window medians for each displayed source, estimates included and marked, plus the
    /// agreement of the most informative ready pair.
    static func chart(
        kind: MetricKind,
        readings: [Reading],
        range: DateInterval,
        analyses: [PairwiseAnalysis],
        shown: [DataSource],
        store: HealthStore
    ) -> WatchChart? {
        let bucket = chartBucket(for: kind)
        let start = Date(timeIntervalSince1970: (range.start.timeIntervalSince1970 / bucket).rounded(.down) * bucket)
        guard start < range.end else { return nil }
        let windows = ComparisonEngine.windows(
            from: readings,
            kind: kind,
            windowSize: bucket,
            range: range,
            includeEstimated: true
        )
        let series = shown.compactMap { source -> WatchChartSeries? in
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
            let slot = DataSource.paletteSlots[
                ((source.colorIndex % DataSource.paletteSlots.count) + DataSource.paletteSlots.count)
                    % DataSource.paletteSlots.count
            ]
            return WatchChartSeries(
                id: watchID(for: source),
                sourceName: displayName(source),
                color: WatchColor(red: slot.dark.red, green: slot.dark.green, blue: slot.dark.blue),
                symbol: SourceSymbol.forColorIndex(source.colorIndex).rawValue,
                isEstimated: estimated,
                offsets: offsets,
                values: values
            )
        }
        guard !series.isEmpty else { return nil }
        return WatchChart(
            start: start,
            end: range.end,
            bucket: bucket,
            series: series,
            pair: pairAgreement(analyses: analyses, chartStart: start, store: store)
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
        let plotted = analysis.plotSample(limit: 36, extremes: 4)
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

    /// Keeps the payload under its cap. Charts are the only optional part, so they are
    /// dropped from the last metrics first; readings and verdicts always travel.
    static func fitted(_ snapshot: WatchSnapshot) -> WatchSnapshot {
        var snapshot = snapshot
        while (try? snapshot.encoded()) == nil,
              let index = snapshot.metrics.lastIndex(where: { $0.chart != nil }) {
            snapshot.metrics[index].chart = nil
        }
        return snapshot
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
