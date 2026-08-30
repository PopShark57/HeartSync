import Foundation

/// Aligns readings from different devices onto a shared time grid and quantifies how much
/// they disagree.
///
/// The problem this solves: devices sample on their own schedules. A chest strap emits
/// once a second, a ring emits every few minutes, Oura returns five-minute averages, and
/// HealthKit hands over irregular batches. Comparing raw samples pairwise would mostly
/// measure the timing offset, not the devices. So everything is bucketed into windows
/// sized for the metric, aggregated per source, and only then compared.
///
/// All functions are pure so they can be tested without a device.
enum ComparisonEngine {

    /// A pair needs at least this many overlapping windows before the app will claim the
    /// two devices systematically disagree. Below this it is coincidence, not a pattern.
    static let minimumPairedWindows = 5

    // MARK: - Windowing

    /// Groups readings into aligned time buckets, one aggregate per source per bucket.
    ///
    /// Buckets are anchored to the Unix epoch rather than to the first reading, so the
    /// grid is stable across refreshes and two runs of this function over overlapping data
    /// produce the same window boundaries.
    ///
    /// - Parameters:
    ///   - readings: raw samples, any order, any source.
    ///   - kind: only readings of this metric are considered.
    ///   - windowSize: bucket length; defaults to the metric's own comparison window.
    ///   - range: optional clamp on the time span to consider.
    ///   - includeEstimated: whether modelled values participate. Off by default, because
    ///     comparing an estimate against a measurement tells you about the model, not the
    ///     devices.
    static func windows(
        from readings: [Reading],
        kind: MetricKind,
        windowSize: TimeInterval? = nil,
        range: DateInterval? = nil,
        includeEstimated: Bool = false
    ) -> [ComparisonWindow] {
        let size = windowSize ?? kind.comparisonWindow
        guard size > 0 else { return [] }

        let relevant = readings.filter { reading in
            guard reading.kind == kind, reading.isPlausible else { return false }
            if !includeEstimated, reading.provenance == .estimated { return false }
            if let range, !range.contains(reading.midpoint) { return false }
            return true
        }
        guard !relevant.isEmpty else { return [] }

        // bucketStart -> sourceID -> samples
        var buckets: [Date: [String: [Reading]]] = [:]
        for reading in relevant {
            let bucketStart = floorToWindow(reading.midpoint, size: size)
            buckets[bucketStart, default: [:]][reading.sourceID, default: []].append(reading)
        }

        return buckets
            .map { start, bySource in
                let values = bySource
                    .map { sourceID, samples in aggregate(samples, sourceID: sourceID) }
                    .sorted { $0.sourceID < $1.sourceID }
                return ComparisonWindow(kind: kind, start: start, duration: size, values: values)
            }
            .sorted { $0.start < $1.start }
    }

    /// Snaps a date down to the start of its epoch-aligned bucket.
    static func floorToWindow(_ date: Date, size: TimeInterval) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / size).rounded(.down) * size)
    }

    /// Reduces one source's samples inside a window to a single value.
    ///
    /// Uses the median rather than the mean: a single motion-artefact spike from an
    /// optical sensor would drag a mean far enough to manufacture a discrepancy, and the
    /// whole point of this app is that a reported gap should mean something.
    static func aggregate(_ samples: [Reading], sourceID: String) -> SourceValue {
        let values = samples.map(\.value)
        let centre = median(values)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.count > 1
            ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            : 0
        // If any sample in the window was measured, call the aggregate measured; only
        // fall back to the weakest provenance present when nothing better exists.
        let provenance: Provenance = samples.contains { $0.provenance == .measured } ? .measured
            : samples.contains { $0.provenance == .derived } ? .derived
            : .estimated

        return SourceValue(
            sourceID: sourceID,
            value: centre,
            sampleCount: samples.count,
            standardDeviation: variance.squareRoot(),
            provenance: provenance
        )
    }

    // MARK: - Pairwise analysis

    /// Builds a complete comparison for one metric and two selected sources.
    ///
    /// Source ordering is canonical regardless of argument order, so the sign of every
    /// difference is stable. Candidate windows are the union of windows reported by either
    /// selected source; paired observations are their intersection. Estimated values remain
    /// excluded because this API deliberately uses the default measurement-only windowing.
    static func pairwiseAnalysis(
        from readings: [Reading],
        kind: MetricKind,
        sourceA: String,
        sourceB: String,
        range: DateInterval,
        windowSize: TimeInterval? = nil,
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows
    ) -> PairwiseAnalysis {
        let size = windowSize ?? kind.comparisonWindow
        let pair = canonicalPair(sourceA, sourceB)
        let comparisonWindows = windows(
            from: readings,
            kind: kind,
            windowSize: size,
            range: range
        )
        return pairwiseAnalysis(
            fromWindows: comparisonWindows,
            kind: kind,
            pair: pair,
            range: range,
            windowSize: size,
            minimumPairedWindows: minimumPairedWindows
        )
    }

    /// Builds every source pair for one metric, including pairs with no overlapping windows.
    ///
    /// A source only needs one eligible reading in the requested range to participate, so a
    /// pair whose timestamps never overlap remains discoverable as `.noOverlap`.
    static func allPairwiseAnalyses(
        from readings: [Reading],
        kind: MetricKind,
        range: DateInterval,
        windowSize: TimeInterval? = nil,
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows
    ) -> [PairwiseAnalysis] {
        let size = windowSize ?? kind.comparisonWindow
        let comparisonWindows = windows(
            from: readings,
            kind: kind,
            windowSize: size,
            range: range
        )
        let sourceIDs = Set(comparisonWindows.flatMap { $0.values.map(\.sourceID) }).sorted()
        guard sourceIDs.count >= 2 else { return [] }

        var analyses: [PairwiseAnalysis] = []
        for indexA in sourceIDs.indices {
            for indexB in sourceIDs.index(after: indexA)..<sourceIDs.endIndex {
                analyses.append(pairwiseAnalysis(
                    fromWindows: comparisonWindows,
                    kind: kind,
                    pair: PairKey(a: sourceIDs[indexA], b: sourceIDs[indexB]),
                    range: range,
                    windowSize: size,
                    minimumPairedWindows: minimumPairedWindows
                ))
            }
        }
        return analyses
    }

    /// Builds every eligible pair for every metric. Ordering follows `MetricKind.allCases`,
    /// then canonical source order, so exports and UI refreshes are deterministic.
    ///
    /// Readings are bucketed by metric once up front. Passing the whole array to each
    /// per-metric call instead would rescan every reading ten times, which is the
    /// difference between one and ten full passes over a month of 1 Hz strap data.
    static func allPairwiseAnalyses(
        from readings: [Reading],
        range: DateInterval,
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows
    ) -> [PairwiseAnalysis] {
        let byKind = Dictionary(grouping: readings, by: \.kind)
        return MetricKind.allCases.flatMap { kind -> [PairwiseAnalysis] in
            guard let forKind = byKind[kind] else { return [] }
            return allPairwiseAnalyses(
                from: forKind,
                kind: kind,
                range: range,
                minimumPairedWindows: minimumPairedWindows
            )
        }
    }

    // MARK: - Discrepancies

    /// Summarises how each pair of sources compares for one metric, using the
    /// Bland\u{2013}Altman approach: mean signed difference (bias) plus the standard deviation
    /// of the differences (which gives the limits of agreement).
    ///
    /// Bland\u{2013}Altman is the right tool here specifically because none of these devices is
    /// a reference standard. Correlation would be misleading \u{2014} two devices can correlate
    /// almost perfectly while one reads 10 bpm high all day.
    static func discrepancies(
        from readings: [Reading],
        kind: MetricKind,
        range: DateInterval? = nil,
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows
    ) -> [Discrepancy] {
        let windows = windows(from: readings, kind: kind, range: range)
        return discrepancies(fromWindows: windows, kind: kind, minimumPairedWindows: minimumPairedWindows)
    }

    static func discrepancies(
        fromWindows windows: [ComparisonWindow],
        kind: MetricKind,
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows
    ) -> [Discrepancy] {
        let multiSource = windows.filter { $0.values.count >= 2 }
        guard !multiSource.isEmpty else { return [] }

        // pairKey -> signed differences (A - B) plus the window times they came from
        var pairs: [PairKey: [Double]] = [:]
        var spans: [PairKey: (Date, Date)] = [:]

        for window in multiSource {
            let values = window.values
            for i in values.indices {
                for j in values.index(after: i)..<values.endIndex {
                    let a = values[i], b = values[j]
                    // Order the pair canonically so A\u{2013}B and B\u{2013}A do not become two entries.
                    let key = PairKey(a: min(a.sourceID, b.sourceID), b: max(a.sourceID, b.sourceID))
                    let signed = key.a == a.sourceID ? a.value - b.value : b.value - a.value
                    pairs[key, default: []].append(signed)
                    if let existing = spans[key] {
                        spans[key] = (min(existing.0, window.start), max(existing.1, window.end))
                    } else {
                        spans[key] = (window.start, window.end)
                    }
                }
            }
        }

        return pairs.compactMap { key, diffs -> Discrepancy? in
            guard diffs.count >= minimumPairedWindows, let span = spans[key] else { return nil }
            let n = Double(diffs.count)
            let bias = diffs.reduce(0, +) / n
            let meanAbs = diffs.reduce(0) { $0 + abs($1) } / n
            // The observed windows are a sample of the devices' possible differences, so
            // Bland–Altman uses sample variance rather than population variance here.
            let variance = diffs.count > 1
                ? diffs.reduce(0) { $0 + ($1 - bias) * ($1 - bias) } / Double(diffs.count - 1)
                : 0
            return Discrepancy(
                kind: kind,
                sourceA: key.a,
                sourceB: key.b,
                meanBias: bias,
                meanAbsoluteDifference: meanAbs,
                differenceSD: variance.squareRoot(),
                windowCount: diffs.count,
                span: DateInterval(start: span.0, end: max(span.1, span.0))
            )
        }
        .sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.meanAbsoluteDifference > rhs.meanAbsoluteDifference
        }
    }

    /// Every metric's discrepancies at once, ordered worst-first, for the summary screen.
    static func allDiscrepancies(
        from readings: [Reading],
        range: DateInterval? = nil
    ) -> [Discrepancy] {
        MetricKind.allCases
            .flatMap { discrepancies(from: readings, kind: $0, range: range) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.windowCount > rhs.windowCount
            }
    }

    // MARK: - Latest side-by-side

    /// The most recent value each source has for a metric, for the live dashboard.
    ///
    /// - Parameter staleAfter: readings older than this are dropped rather than shown as
    ///   current, so a disconnected device does not appear to still be reporting.
    static func latestBySource(
        from readings: [Reading],
        kind: MetricKind,
        now: Date = .now,
        staleAfter: TimeInterval = 15 * 60
    ) -> [String: Reading] {
        var latest: [String: Reading] = [:]
        for reading in readings where reading.kind == kind && reading.isPlausible {
            guard now.timeIntervalSince(reading.end) <= staleAfter else { continue }
            if let existing = latest[reading.sourceID], existing.end >= reading.end { continue }
            latest[reading.sourceID] = reading
        }
        return latest
    }

    // MARK: - Helpers

    private struct PairKey: Hashable {
        let a: String
        let b: String
    }

    private static func canonicalPair(_ first: String, _ second: String) -> PairKey {
        first <= second
            ? PairKey(a: first, b: second)
            : PairKey(a: second, b: first)
    }

    private static func pairwiseAnalysis(
        fromWindows windows: [ComparisonWindow],
        kind: MetricKind,
        pair: PairKey,
        range: DateInterval,
        windowSize: TimeInterval,
        minimumPairedWindows: Int
    ) -> PairwiseAnalysis {
        let candidates = windows.filter { window in
            window.value(for: pair.a) != nil || window.value(for: pair.b) != nil
        }

        // A self-pair is not a device comparison. Return an evidence-free result rather
        // than manufacturing perfect agreement or trapping a caller at runtime.
        let observations: [PairwiseObservation] = pair.a == pair.b ? [] : candidates.compactMap { window in
            guard let sourceA = window.value(for: pair.a),
                  let sourceB = window.value(for: pair.b)
            else { return nil }
            return PairwiseObservation(
                start: window.start,
                duration: window.duration,
                sourceA: sourceA,
                sourceB: sourceB,
                severity: kind.agreement.severity(forDelta: sourceA.value - sourceB.value)
            )
        }

        let pairedWindowCount = observations.count
        let candidateWindowCount = candidates.count
        let overlapPercentage = candidateWindowCount > 0
            ? min(100, max(0, Double(pairedWindowCount) / Double(candidateWindowCount) * 100))
            : 0
        let analyzedSpan: DateInterval? = if let first = observations.first,
                                             let last = observations.last {
            DateInterval(start: first.start, end: max(first.start, last.end))
        } else {
            nil
        }
        let requiredWindowCount = max(1, minimumPairedWindows)
        let statistics = pairedWindowCount >= requiredWindowCount
            ? summaryStatistics(from: observations, kind: kind)
            : nil
        let state: PairwiseAnalysisState
        if pairedWindowCount == 0 {
            state = .noOverlap
        } else if let statistics {
            state = .ready(statistics)
        } else {
            state = .collecting(
                pairedWindowCount: pairedWindowCount,
                requiredWindowCount: requiredWindowCount
            )
        }

        return PairwiseAnalysis(
            kind: kind,
            sourceA: pair.a,
            sourceB: pair.b,
            range: range,
            windowSize: windowSize,
            observations: observations,
            candidateWindowCount: candidateWindowCount,
            pairedWindowCount: pairedWindowCount,
            overlapPercentage: overlapPercentage,
            analyzedSpan: analyzedSpan,
            rawSampleCountA: observations.reduce(0) { $0 + $1.sourceA.sampleCount },
            rawSampleCountB: observations.reduce(0) { $0 + $1.sourceB.sampleCount },
            state: state
        )
    }

    private static func summaryStatistics(
        from observations: [PairwiseObservation],
        kind: MetricKind
    ) -> PairwiseSummaryStatistics? {
        guard !observations.isEmpty else { return nil }
        let differences = observations.map(\.signedDifference)
        let count = Double(differences.count)
        let meanBias = differences.reduce(0, +) / count
        let meanAbsoluteDifference = differences.reduce(0) { $0 + abs($1) } / count
        let variance = differences.count > 1
            ? differences.reduce(0) { $0 + ($1 - meanBias) * ($1 - meanBias) }
                / Double(differences.count - 1)
            : 0
        let differenceSD = variance.squareRoot()
        let limits = (meanBias - 1.96 * differenceSD)...(meanBias + 1.96 * differenceSD)
        let classification: PairwiseDifferenceClassification
        if meanAbsoluteDifference == 0 {
            classification = .noApparentDifference
        } else if differenceSD == 0 || abs(meanBias) > differenceSD {
            classification = .systematicBias
        } else {
            classification = .measurementNoise
        }

        return PairwiseSummaryStatistics(
            meanBias: meanBias,
            meanAbsoluteDifference: meanAbsoluteDifference,
            differenceSD: differenceSD,
            limitsOfAgreement: limits,
            severity: kind.agreement.severity(forDelta: meanAbsoluteDifference),
            classification: classification
        )
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
