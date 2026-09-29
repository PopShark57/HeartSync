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
    ///   - includeIntervalAverages: whether averages over more than the metric's comparison
    ///     window (`Reading.isIntervalAverage`) participate. Off by default, for the same
    ///     reason: a night's mean heart rate placed in the minute around 03:00 and paired
    ///     with a strap's median for that minute measures the averaging, not the devices.
    ///     When included, the value is marked and its pairs never support a conclusion.
    static func windows(
        from readings: [Reading],
        kind: MetricKind,
        windowSize: TimeInterval? = nil,
        range: DateInterval? = nil,
        includeEstimated: Bool = false,
        includeIntervalAverages: Bool = false
    ) -> [ComparisonWindow] {
        let size = windowSize ?? kind.comparisonWindow
        guard size > 0 else { return [] }

        let relevant = readings.filter { reading in
            guard reading.kind == kind, reading.isPlausible else { return false }
            if !includeEstimated, reading.provenance == .estimated { return false }
            if !includeIntervalAverages, reading.isIntervalAverage { return false }
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

        let compacted = samples.filter {
            $0.metadata?.aggregation != nil || isLegacyCompactedMedian($0)
        }
        let sampleCount: Int?
        let standardDeviation: Double?
        if samples.count == 1, let aggregation = compacted.first?.metadata?.aggregation {
            sampleCount = aggregation.originalSampleCount
            standardDeviation = aggregation.originalStandardDeviation
        } else if compacted.isEmpty {
            sampleCount = samples.count
            standardDeviation = variance.squareRoot()
        } else {
            // A mixture of raw and already-compacted rows cannot be recombined honestly from
            // medians alone. This should only occur in legacy data and remains unknown.
            sampleCount = nil
            standardDeviation = nil
        }
        let qualityCaveatCount = samples.count { reading in
            guard let metadata = reading.metadata else { return false }
            return metadata.quality == .provisional
                || metadata.quality == .questionable
                || (metadata.artefactFraction ?? 0) > 0.10
        }

        // Timing facts describe when the device actually reported, which is not the same as
        // the bucket it landed in. A compacted median has no surviving contributing
        // timestamps, so its timing stays unknown rather than being backfilled from the
        // window bounds — that would manufacture a precision the archive discarded.
        let observedInterval: DateInterval?
        let representativeTime: Date?
        if compacted.isEmpty,
           let earliest = samples.map(\.start).min(),
           let latest = samples.map(\.end).max() {
            observedInterval = DateInterval(start: earliest, end: max(earliest, latest))
            representativeTime = Date(
                timeIntervalSince1970: median(samples.map(\.midpoint).map(\.timeIntervalSince1970))
            )
        } else {
            observedInterval = nil
            representativeTime = nil
        }

        return SourceValue(
            sourceID: sourceID,
            value: centre,
            sampleCount: sampleCount,
            standardDeviation: standardDeviation,
            provenance: provenance,
            isCompacted: !compacted.isEmpty,
            qualityCaveatCount: qualityCaveatCount,
            observedInterval: observedInterval,
            representativeTime: representativeTime,
            includesIntervalAverage: samples.contains(where: \.isIntervalAverage)
        )
    }

    /// Classifies how well one paired window supports "these describe the same moment".
    ///
    /// Deliberately does not move, adjust, or re-bucket any timestamp. The pairing rule is
    /// unchanged; this only makes the timing implied by that rule inspectable.
    static func timingQuality(
        sourceA: SourceValue,
        sourceB: SourceValue,
        kind: MetricKind
    ) -> PairTimingQuality {
        // Checked first: an interval average's midpoint can sit right next to the other
        // source's readings and look simultaneous while describing a whole night.
        if sourceA.includesIntervalAverage || sourceB.includesIntervalAverage { return .intervalAverage }
        guard let tolerance = kind.timingTolerance else { return .notApplicable }
        guard let a = sourceA.representativeTime, let b = sourceB.representativeTime else { return .unknown }
        return abs(a.timeIntervalSince(b)) <= tolerance ? .simultaneous : .separated
    }

    // MARK: - Pairwise analysis

    /// Builds a complete comparison for one metric and two selected sources.
    ///
    /// Source ordering is canonical regardless of argument order, so the sign of every
    /// difference is stable. Candidate windows are the union of windows reported by either
    /// selected source; paired observations are their intersection. Estimated values remain
    /// excluded because this API deliberately uses the default measurement-only windowing.
    /// Interval averages are excluded too unless `includeIntervalAverages` asks for them,
    /// and then their pairs are listed but never counted toward a conclusion.
    static func pairwiseAnalysis(
        from readings: [Reading],
        kind: MetricKind,
        sourceA: String,
        sourceB: String,
        range: DateInterval,
        windowSize: TimeInterval? = nil,
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows,
        includeIntervalAverages: Bool = false
    ) -> PairwiseAnalysis {
        let size = windowSize ?? kind.comparisonWindow
        let pair = canonicalPair(sourceA, sourceB)
        let comparisonWindows = windows(
            from: readings,
            kind: kind,
            windowSize: size,
            range: range,
            includeIntervalAverages: includeIntervalAverages
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
        minimumPairedWindows: Int = ComparisonEngine.minimumPairedWindows,
        includeIntervalAverages: Bool = false
    ) -> [PairwiseAnalysis] {
        let size = windowSize ?? kind.comparisonWindow
        let comparisonWindows = windows(
            from: readings,
            kind: kind,
            windowSize: size,
            range: range,
            includeIntervalAverages: includeIntervalAverages
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
                severity: kind.agreement.severity(forDelta: sourceA.value - sourceB.value),
                timing: timingQuality(sourceA: sourceA, sourceB: sourceB, kind: kind)
            )
        }

        let pairedWindowCount = observations.count
        // An interval-average pair is listed, and exported with its timing, but it is not
        // evidence about the devices: the threshold and the statistics use the rest only.
        let conclusive = observations.filter { $0.timing != .intervalAverage }
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
        let statistics = conclusive.count >= requiredWindowCount
            ? summaryStatistics(from: conclusive, kind: kind)
            : nil
        let state: PairwiseAnalysisState
        if pairedWindowCount == 0 {
            state = .noOverlap
        } else if let statistics {
            state = .ready(statistics)
        } else {
            state = .collecting(
                pairedWindowCount: conclusive.count,
                requiredWindowCount: requiredWindowCount
            )
        }

        let rawSampleCountA = knownSampleTotal(observations.map(\.sourceA))
        let rawSampleCountB = knownSampleTotal(observations.map(\.sourceB))
        let assessment = evidenceAssessment(
            observations: observations,
            pairedWindowCount: conclusive.count,
            overlapPercentage: overlapPercentage,
            analyzedSpan: analyzedSpan,
            windowSize: windowSize,
            minimumPairedWindows: requiredWindowCount
        )

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
            rawSampleCountA: rawSampleCountA,
            rawSampleCountB: rawSampleCountB,
            state: state,
            evidence: assessment
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

        let effectiveCount = effectiveSampleSize(of: observations)
        let confidence = confidenceIntervals(
            meanBias: meanBias,
            sd: differenceSD,
            count: differences.count,
            effectiveCount: effectiveCount
        )
        return PairwiseSummaryStatistics(
            meanBias: meanBias,
            meanAbsoluteDifference: meanAbsoluteDifference,
            differenceSD: differenceSD,
            limitsOfAgreement: limits,
            severity: kind.agreement.severity(forDelta: meanAbsoluteDifference),
            classification: classification,
            meanBiasConfidenceInterval: confidence?.mean,
            lowerLimitConfidenceInterval: confidence?.lowerLimit,
            upperLimitConfidenceInterval: confidence?.upperLimit,
            effectiveSampleSize: confidence == nil ? nil : effectiveCount
        )
    }

    /// How many independent differences `observations` are worth.
    ///
    /// Consecutive windows from one walk or one night are not independent: a device that
    /// reads 4 bpm high at 10:00 usually still does at 10:01. Treating thirty adjacent
    /// minutes as thirty independent draws makes the bias interval too narrow. This uses the
    /// usual AR(1) adjustment, `n (1 - r) / (1 + r)`, where `r` is the lag-one
    /// autocorrelation of the differences measured only across windows that touch. A
    /// negative `r` is treated as zero, so the adjustment never claims more than `n`, and
    /// the result is never below two.
    static func effectiveSampleSize(of observations: [PairwiseObservation]) -> Double {
        let n = Double(observations.count)
        guard observations.count >= 3 else { return n }
        let differences = observations.map(\.signedDifference)
        let mean = differences.reduce(0, +) / n
        let variance = differences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        guard variance > 0 else { return n }
        var lagProducts = 0.0
        var lagPairs = 0
        for index in 1..<observations.count
        where abs(observations[index].start.timeIntervalSince(observations[index - 1].end)) < 0.5 {
            lagProducts += (differences[index] - mean) * (differences[index - 1] - mean)
            lagPairs += 1
        }
        guard lagPairs > 0 else { return n }
        let r = min(0.99, max(0, lagProducts / Double(lagPairs) / variance))
        return max(2, min(n, n * (1 - r) / (1 + r)))
    }

    /// Two-sided 95% quantile of Student's t with `degreesOfFreedom` degrees of freedom.
    ///
    /// Tabulated to 30 and interpolated linearly in `1 / df` between entries (the usual
    /// rule for fractional degrees of freedom); beyond 30, the Cornish–Fisher expansion
    /// about the normal quantile (Abramowitz and Stegun 26.7.5), accurate to three decimals.
    static func tQuantile975(degreesOfFreedom df: Double) -> Double {
        guard df.isFinite, df > 0 else { return .infinity }
        if df <= 1 { return tTable975[0] }
        if df <= Double(tTable975.count) {
            let lower = Int(df.rounded(.down))
            let upper = min(lower + 1, tTable975.count)
            guard lower != upper else { return tTable975[lower - 1] }
            let fraction = (1 / Double(lower) - 1 / df) / (1 / Double(lower) - 1 / Double(upper))
            return tTable975[lower - 1] + fraction * (tTable975[upper - 1] - tTable975[lower - 1])
        }
        let z = 1.959963984540054
        let z3 = z * z * z, z5 = z3 * z * z, z7 = z5 * z * z, z9 = z7 * z * z
        return z
            + (z3 + z) / (4 * df)
            + (5 * z5 + 16 * z3 + 3 * z) / (96 * df * df)
            + (3 * z7 + 19 * z5 + 17 * z3 - 15 * z) / (384 * df * df * df)
            + (79 * z9 + 776 * z7 + 1482 * z5 - 1920 * z3 - 945 * z) / (92_160 * df * df * df * df)
    }

    /// t(0.975) for 1 through 30 degrees of freedom.
    private static let tTable975: [Double] = [
        12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
        2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
    ]

    private static func knownSampleTotal(_ values: [SourceValue]) -> Int? {
        var total = 0
        for value in values {
            guard let count = value.sampleCount else { return nil }
            total += count
        }
        return total
    }

    /// Whether `reading` is a window median written before rows carried aggregation metadata.
    ///
    /// Such a row was stored at the start of its window, so a row that does not start on a
    /// window boundary cannot be one. That cheap test comes first because this runs for every
    /// reading in every `windows()` call, and the identity check below formats a string and
    /// hashes it with SHA-256; almost every raw reading now stops at the boundary test.
    private static func isLegacyCompactedMedian(_ reading: Reading) -> Bool {
        let window = reading.kind.comparisonWindow
        let seconds = reading.start.timeIntervalSince1970
        guard seconds == (seconds / window).rounded(.down) * window else { return false }
        let start = floorToWindow(reading.midpoint, size: window)
        let expected = UUID(stableFrom: "compact.\(reading.sourceID).\(reading.kind.rawValue).\(Int(start.timeIntervalSince1970))")
        return reading.id == expected
    }

    private static func evidenceAssessment(
        observations: [PairwiseObservation],
        pairedWindowCount: Int,
        overlapPercentage: Double,
        analyzedSpan: DateInterval?,
        windowSize: TimeInterval,
        minimumPairedWindows: Int
    ) -> PairwiseEvidenceAssessment {
        let values = observations.flatMap { [$0.sourceA, $0.sourceB] }
        let unknownDepth = values.contains { $0.sampleCount == nil }
        let compacted = observations.count { $0.sourceA.isCompacted || $0.sourceB.isCompacted }
        let caveats = values.reduce(0) { $0 + $1.qualityCaveatCount }
        let span = analyzedSpan?.duration ?? 0
        let strongSpan = max(3_600, windowSize * 30)
        let moderateSpan = max(1_800, windowSize * 10)

        // Timing facts. Separated and unknown are counted apart because they mean different
        // things: one is a measured failure to coincide, the other is an absence of evidence.
        let separated = observations.count { $0.timing == .separated }
        let unknownTiming = observations.count { $0.timing == .unknown }
        let intervalAverages = observations.count { $0.timing == .intervalAverage }
        let separations = observations.compactMap(\.timingSeparation)
        let medianSeparation = separations.isEmpty ? nil : median(separations)
        // How much of the analyzed span the paired windows actually occupy. Below 1 the
        // pair's shared coverage is intermittent, whatever the window count says.
        let coverageFraction: Double? = span > 0
            ? min(1, Double(pairedWindowCount) * windowSize / span)
            : nil

        // A pair that never actually coincided is not strong evidence about the devices,
        // however many windows it accumulated, so timing gates the top grades. The paired
        // set itself is NOT filtered: statistics still use every paired window, as
        // documented, and this marks the evidence rather than quietly discarding data.
        let timingSupportsStrong = separated == 0 && unknownTiming == 0 && intervalAverages == 0
        let timingSupportsModerate = pairedWindowCount > 0 && intervalAverages == 0
            && Double(separated + unknownTiming) / Double(pairedWindowCount) <= 0.25

        let grade: PairwiseEvidenceGrade
        if pairedWindowCount < minimumPairedWindows {
            grade = .limited
        } else if pairedWindowCount >= 30, overlapPercentage >= 80,
                  span >= strongSpan, !unknownDepth, compacted == 0, caveats == 0,
                  timingSupportsStrong {
            grade = .strong
        } else if pairedWindowCount >= 10, overlapPercentage >= 60,
                  span >= moderateSpan, caveats == 0, timingSupportsModerate {
            grade = .moderate
        } else {
            grade = .weak
        }

        var reasons: [String] = []
        if pairedWindowCount < minimumPairedWindows {
            reasons.append(String(localized: "evidence.reason.tooFewWindows", defaultValue: "Too few paired windows", comment: "Why a device comparison has a low evidence grade"))
        }
        if overlapPercentage < 60 {
            reasons.append(String(localized: "evidence.reason.lowOverlap", defaultValue: "Low time overlap", comment: "Why a device comparison has a low evidence grade"))
        }
        if unknownDepth {
            reasons.append(String(localized: "evidence.reason.unknownDepth", defaultValue: "Some compacted sample counts are unknown", comment: "Why a device comparison has a low evidence grade"))
        }
        if compacted > 0 {
            reasons.append(String(localized: "evidence.reason.compacted", defaultValue: "Includes fixed compacted window medians", comment: "Why a device comparison has a low evidence grade"))
        }
        if caveats > 0 {
            reasons.append(String(localized: "evidence.reason.qualityCaveats", defaultValue: "Includes signal-quality caveats", comment: "Why a device comparison has a low evidence grade"))
        }
        if separated > 0 {
            reasons.append(String(
                localized: "evidence.reason.separated",
                defaultValue: "\(separated) paired windows pair readings taken too far apart in time",
                comment: "Why a device comparison has a low evidence grade. The argument is how many paired windows used readings taken too far apart."
            ))
        }
        if unknownTiming > 0 {
            reasons.append(String(
                localized: "evidence.reason.unknownTiming",
                defaultValue: "\(unknownTiming) paired windows have unknown measurement timing",
                comment: "Why a device comparison has a low evidence grade. The argument is how many paired windows have no timing information."
            ))
        }
        if intervalAverages > 0 {
            reasons.append(String(
                localized: "evidence.reason.intervalAverages",
                defaultValue: "\(intervalAverages) paired windows compare an average over a longer interval with one window",
                comment: "Why a device comparison has a low evidence grade. The argument is how many paired windows use a night or day average from one device."
            ))
        }
        if let coverageFraction, coverageFraction < 0.5 {
            reasons.append(String(localized: "evidence.reason.partialCoverage", defaultValue: "Paired windows cover only part of the analysed span", comment: "Why a device comparison has a low evidence grade"))
        }
        if reasons.isEmpty {
            reasons.append(String(localized: "evidence.reason.supported", defaultValue: "Window count, span, overlap, timing, and sample depth support this grade", comment: "Why a device comparison has a high evidence grade"))
        }

        return PairwiseEvidenceAssessment(
            grade: grade,
            hasUnknownSampleDepth: unknownDepth,
            compactedWindowCount: compacted,
            qualityCaveatCount: caveats,
            reasons: reasons,
            temporallySeparatedCount: separated,
            unknownTimingCount: unknownTiming,
            medianTimingSeparation: medianSeparation,
            coverageFraction: coverageFraction
        )
    }

    /// Approximate 95% confidence intervals are exposed only from ten pairs onward. The
    /// limits use Bland-Altman's standard error approximation; below ten, an interval would
    /// look more authoritative than the evidence warrants.
    ///
    /// Both use the effective sample size rather than the window count, and a t quantile
    /// on `effectiveCount - 1` degrees of freedom rather than 1.96. The limits themselves
    /// stay at 1.96 standard deviations: they describe the spread of the differences, not
    /// the uncertainty of an estimate.
    private static func confidenceIntervals(
        meanBias: Double,
        sd: Double,
        count: Int,
        effectiveCount: Double
    ) -> (mean: ClosedRange<Double>, lowerLimit: ClosedRange<Double>, upperLimit: ClosedRange<Double>)? {
        guard count >= 10, sd.isFinite else { return nil }
        let n = min(Double(count), max(2, effectiveCount))
        let spread = 1.96
        let critical = tQuantile975(degreesOfFreedom: n - 1)
        let meanMargin = critical * sd / n.squareRoot()
        let lower = meanBias - spread * sd
        let upper = meanBias + spread * sd
        let limitSE = sd * (1 / n + spread * spread / (2 * (n - 1))).squareRoot()
        let limitMargin = critical * limitSE
        return (
            (meanBias - meanMargin)...(meanBias + meanMargin),
            (lower - limitMargin)...(lower + limitMargin),
            (upper - limitMargin)...(upper + limitMargin)
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
