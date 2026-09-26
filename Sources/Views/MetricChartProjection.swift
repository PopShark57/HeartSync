import Foundation

/// One comparison window as the metric-detail selection callout describes it.
///
/// Every value here is a **window median** — the chart draws one median per device per
/// bucket, and the callout must describe what is drawn, not claim a raw sample.
struct ChartWindowSummary: Identifiable, Equatable, Sendable {

    /// One device's median in this window.
    struct Value: Identifiable, Equatable, Sendable {
        var sourceID: String
        /// The same disambiguated label the legend uses.
        var label: String
        var value: Double
        /// A modelled value. Labelled wherever it is shown and never part of `spread`.
        var isEstimate: Bool
        /// A fixed compacted median whose raw samples no longer exist.
        var isCompacted: Bool

        var id: String { sourceID }
    }

    /// Highest minus lowest measured or derived value in the window: the disagreement band's
    /// height at this moment, with the band's own severity.
    struct Spread: Equatable, Sendable {
        var low: Double
        var high: Double
        var severity: DiscrepancySeverity

        var width: Double { high - low }
    }

    var start: Date
    var duration: TimeInterval
    /// In legend order.
    var values: [Value]
    /// Nil unless at least two devices reported a measured or derived value. An estimate
    /// is not a device, so it can never create or widen a spread.
    var spread: Spread?

    var id: Date { start }
    var end: Date { start.addingTimeInterval(duration) }
    var hasEstimate: Bool { values.contains(where: \.isEstimate) }
    var hasCompacted: Bool { values.contains(where: \.isCompacted) }
}

extension ChartWindowSummary.Spread {
    /// The spread in words, measured against the metric's fixed tolerances.
    ///
    /// Deliberately silent about agreement. One window is not evidence that two devices
    /// agree — no conclusion is drawn from fewer than five paired windows — so the callout
    /// describes the gap at this moment and nothing more.
    func summary(for kind: MetricKind) -> String {
        let spread = kind.formatWithUnit(width)
        switch severity {
        case .agreeing:
            return "Spread \(spread), under the \(kind.formatWithUnit(kind.agreement.warn)) tolerance"
        case .notable:
            return "Spread \(spread), at or over the \(kind.formatWithUnit(kind.agreement.warn)) warning tolerance"
        case .major:
            return "Spread \(spread), at or over the \(kind.formatWithUnit(kind.agreement.alert)) major tolerance"
        }
    }
}

/// The drawing half of metric detail: one span of one metric at one bucket size.
///
/// The screen draws either the whole analysed period, from its snapshot's own windowing
/// pass, or a zoomed-in part of it re-read at a finer bucket. Both go through this one
/// projection, so the line segmentation, the band, the domains, and the selection lookups
/// cannot differ between the two.
@MainActor
struct MetricChartProjection {
    /// The span this projection was read for.
    let interval: DateInterval
    let bucketSize: TimeInterval
    let points: [ChartPoint]
    let bandPoints: [BandPoint]
    let yDomain: ClosedRange<Double>
    /// The pinned x-axis domain: the span, widened back to its first bucket boundary so
    /// the first window is drawn inside the plot. Pinning it keeps empty stretches visibly
    /// empty — a 7-day chart with one day of data must not look like a one-day chart.
    let xDomain: ClosedRange<Date>
    /// Every drawn window, in time order, as the selection callout describes it.
    let windows: [ChartWindowSummary]
    /// `windows[i].start` as reference-date seconds, ascending.
    private let windowStarts: [Double]

    /// - Parameters:
    ///   - comparisonWindows: `ComparisonEngine.windows` over `interval` at `bucketSize`.
    ///   - series: the legend's series, which fix each device's label and order.
    ///   - labels: display names for devices without a series entry.
    init(
        windows comparisonWindows: [ComparisonWindow],
        kind: MetricKind,
        interval: DateInterval,
        bucketSize: TimeInterval,
        series: [SourceSeries],
        labels: [String: String] = [:]
    ) {
        self.interval = interval
        self.bucketSize = bucketSize

        var order: [String: Int] = [:]
        var names = labels
        for (index, entry) in series.enumerated() {
            order[entry.sourceID] = index
            names[entry.sourceID] = entry.label
        }

        var summaries: [ChartWindowSummary] = []
        summaries.reserveCapacity(comparisonWindows.count)
        var chartPoints: [ChartPoint] = []
        for window in comparisonWindows {
            let values = window.values
                .sorted { lhs, rhs in
                    let left = order[lhs.sourceID] ?? .max, right = order[rhs.sourceID] ?? .max
                    return left == right ? lhs.sourceID < rhs.sourceID : left < right
                }
                .map { value in
                    ChartWindowSummary.Value(
                        sourceID: value.sourceID,
                        label: names[value.sourceID] ?? value.sourceID,
                        value: value.value,
                        isEstimate: value.provenance == .estimated,
                        isCompacted: value.isCompacted
                    )
                }
            // The band is a disagreement verdict drawn on a chart, so it is built from
            // measured and derived values only. Showing estimates must never widen it or
            // change its colour: the estimate switch is presentation, and an estimate is
            // not a device.
            let comparable = values.filter { !$0.isEstimate }.map(\.value)
            var spread: ChartWindowSummary.Spread?
            if comparable.count >= 2, let low = comparable.min(), let high = comparable.max() {
                spread = ChartWindowSummary.Spread(
                    low: low,
                    high: high,
                    severity: kind.agreement.severity(forDelta: high - low)
                )
            }
            summaries.append(ChartWindowSummary(
                start: window.start,
                duration: window.duration,
                values: values,
                spread: spread
            ))
            for value in values {
                chartPoints.append(ChartPoint(
                    id: "\(value.sourceID)-\(window.start.timeIntervalSince1970)",
                    date: window.start,
                    value: value.value,
                    sourceID: value.sourceID,
                    sourceName: value.label,
                    isEstimate: value.isEstimate,
                    isCompacted: value.isCompacted
                ))
            }
        }
        summaries.sort { $0.start < $1.start }
        self.windows = summaries
        self.windowStarts = summaries.map { $0.start.timeIntervalSinceReferenceDate }
        self.points = Self.segmented(chartPoints, bucketSize: bucketSize)

        let compared = summaries.compactMap { summary -> BandPoint? in
            guard let spread = summary.spread else { return nil }
            return BandPoint(
                id: "\(kind.rawValue)-\(Int(summary.start.timeIntervalSince1970))",
                date: summary.start,
                low: spread.low,
                high: spread.high,
                severity: spread.severity
            )
        }
        self.bandPoints = Self.bandRuns(compared, bucketSize: bucketSize)

        // Pads the observed range slightly so lines are not flush against the plot edges,
        // and never collapses to zero height when every reading is identical.
        let plotted = self.points.map(\.value)
        if let low = plotted.min(), let high = plotted.max() {
            let padding = max((high - low) * 0.15, kind.agreement.warn)
            self.yDomain = (low - padding)...(high + padding)
        } else {
            self.yDomain = kind.displayRange
        }

        let firstBoundary = bucketSize > 0
            ? ComparisonEngine.floorToWindow(interval.start, size: bucketSize)
            : interval.start
        self.xDomain = min(firstBoundary, interval.end)...interval.end
    }

    // MARK: - Selection

    /// The drawn window whose start is nearest `date`, found by binary search. With a
    /// tolerance, a window farther away than that is not selected: the touch was in empty
    /// plot area, and the caller clears the selection instead.
    func window(nearest date: Date, within tolerance: TimeInterval? = nil) -> ChartWindowSummary? {
        ChartLookup.nearestIndex(
            in: windowStarts,
            to: date.timeIntervalSinceReferenceDate,
            within: tolerance
        ).map { windows[$0] }
    }

    /// The drawn window that starts exactly at `date`. Nil after a reload or a zoom that no
    /// longer draws it, so a stale selection disappears rather than pointing at nothing.
    func window(startingAt date: Date?) -> ChartWindowSummary? {
        guard let date,
              let index = ChartLookup.nearestIndex(in: windowStarts, to: date.timeIntervalSinceReferenceDate),
              windows[index].start == date
        else { return nil }
        return windows[index]
    }

    // MARK: - Projections

    /// Assigns each point a line-segment key, starting a new segment wherever a source
    /// skipped more than one bucket.
    ///
    /// A curve drawn across a gap asserts that the device was measuring throughout it. It
    /// was not, and the chart must not say so. An isolated observation gets its own
    /// segment and remains visible as a point, because `PointMark` is drawn regardless.
    ///
    /// The threshold is 1.5 buckets: one bucket of spacing is normal for a source
    /// reporting every window, so only a genuinely missed window breaks the line.
    static func segmented(_ points: [ChartPoint], bucketSize: TimeInterval) -> [ChartPoint] {
        guard bucketSize > 0 else { return points }
        let threshold = ChartSegmentation.windowThreshold(windowSize: bucketSize)
        var result: [ChartPoint] = []
        result.reserveCapacity(points.count)

        for (sourceID, group) in Dictionary(grouping: points, by: \.sourceID) {
            let ordered = group.sorted { $0.date < $1.date }
            let segments = ChartSegmentation.segments(for: ordered.map(\.date), threshold: threshold)
            for (point, segment) in zip(ordered, segments) {
                var keyed = point
                keyed.seriesKey = ChartSegmentation.key(series: sourceID, segment: segment)
                result.append(keyed)
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Splits the disagreement band into areas that are honest about two things.
    ///
    /// **Gaps.** A window where fewer than two devices reported has no band. One area drawn
    /// across it shaded "disagreement" over time when nothing was compared, so the band
    /// breaks at a missing window exactly as the lines do.
    ///
    /// **Severity.** Swift Charts draws a whole area series in the style of its first mark,
    /// so one area per stretch painted every window in the first window's colour: a major
    /// disagreement after an agreeing start was shaded as agreement. Each run of equal
    /// severity is its own series instead. Where the severity changes the two runs meet at
    /// the midpoint between the windows, so each window keeps its own colour for its half
    /// of the interval and the band stays continuous.
    ///
    /// A compared window with no compared neighbour is kept and flagged `isIsolated`.
    static func bandRuns(_ band: [BandPoint], bucketSize: TimeInterval) -> [BandPoint] {
        let ordered = band.sorted { $0.date < $1.date }
        let gaps = ChartSegmentation.segments(
            for: ordered.map(\.date),
            threshold: ChartSegmentation.windowThreshold(windowSize: bucketSize)
        )
        var result: [BandPoint] = []
        result.reserveCapacity(ordered.count)
        var run = -1

        func emit(_ point: BandPoint, id: String) {
            var keyed = point
            keyed.id = id
            keyed.seriesKey = ChartSegmentation.key(series: "band", segment: run)
            result.append(keyed)
        }

        for index in ordered.indices {
            let point = ordered[index]
            guard index > 0, gaps[index] == gaps[index - 1] else {
                run += 1
                emit(point, id: point.id)
                continue
            }
            let previous = ordered[index - 1]
            if point.severity != previous.severity {
                let middle = BandPoint(
                    id: "",
                    date: Date(timeIntervalSince1970: (previous.date.timeIntervalSince1970 + point.date.timeIntervalSince1970) / 2),
                    low: (previous.low + point.low) / 2,
                    high: (previous.high + point.high) / 2,
                    severity: previous.severity
                )
                emit(middle, id: "\(previous.id)\u{001F}end")
                run += 1
                var opening = middle
                opening.severity = point.severity
                emit(opening, id: "\(point.id)\u{001F}start")
            }
            emit(point, id: point.id)
        }

        var counts: [String: Int] = [:]
        for point in result { counts[point.seriesKey, default: 0] += 1 }
        for index in result.indices { result[index].isIsolated = counts[result[index].seriesKey] == 1 }
        return result
    }
}

/// A zoomed-in part of the metric-detail chart, re-read for just the visible span at the
/// bucket that span calls for (semantic zoom, improvement 33).
///
/// Only the chart zooms. The per-device table and the pair list keep describing the whole
/// analysed period, because they are labelled with that period.
@MainActor
struct MetricZoomSnapshot {
    let viewport: ChartViewport
    let chart: MetricChartProjection
    /// A failed read is not an empty span; the screen says so rather than drawing nothing.
    let queryFailure: HealthStoreQueryError?
    let generation: Int
    let resolvedAt: Date

    /// - Parameter series: the whole period's legend series, so a zoomed chart keeps every
    ///   device's label, colour, and shape. A device that first reported after the period
    ///   loaded is left out until the period reloads, rather than drawn without a legend entry.
    init(
        store: HealthStore,
        kind: MetricKind,
        viewport: ChartViewport,
        includeEstimates: Bool,
        series: [SourceSeries]
    ) {
        self.viewport = viewport
        self.generation = store.changeToken
        self.resolvedAt = .now
        let outcome = store.readingsOutcome(kind: kind, in: viewport.visible)
        self.queryFailure = outcome.error
        let known = Set(series.map(\.sourceID))
        let bucket = viewport.bucket(for: kind)
        let windows = ComparisonEngine.windows(
            from: outcome.valueOrEmpty.filter { known.contains($0.sourceID) },
            kind: kind,
            windowSize: bucket,
            range: viewport.visible,
            includeEstimated: includeEstimates
        )
        self.chart = MetricChartProjection(
            windows: windows,
            kind: kind,
            interval: viewport.visible,
            bucketSize: bucket,
            series: series
        )
    }
}

/// The pair evidence for a period dragged out on the metric-detail chart.
///
/// Computed exactly as metric detail computes it for a saved session over the same
/// seconds — the same read, the same engine call, the same range — so saving the period
/// and reopening it shows these statistics, not different ones.
@MainActor
struct MetricPeriodEvidence {
    let interval: DateInterval
    let analyses: [PairwiseAnalysis]
    let queryFailure: HealthStoreQueryError?

    init(store: HealthStore, kind: MetricKind, interval: DateInterval) {
        self.interval = interval
        let outcome = store.readingsOutcome(kind: kind, in: interval)
        self.queryFailure = outcome.error
        self.analyses = ComparisonEngine.allPairwiseAnalyses(
            from: outcome.valueOrEmpty,
            kind: kind,
            range: interval
        )
    }
}
