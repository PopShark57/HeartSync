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
            let variance = diffs.reduce(0) { $0 + ($1 - bias) * ($1 - bias) } / n
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

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
