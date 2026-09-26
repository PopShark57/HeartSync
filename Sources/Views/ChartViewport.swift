import Foundation

/// The visible stretch of a history chart, for zooming and panning inside the analysed
/// period, plus the snapping rule for a dragged period.
///
/// **Why not `chartScrollableAxes`.** With Swift Charts' own scrolling, a selection's
/// annotation stops displaying (Apple Feedback FB12584128, reported July 2023 and still
/// reproducing on iOS 18), and changing `chartXVisibleDomain` after a scroll makes the
/// chart jump (FB14091989). The selection callout is the point of improvement 32, so zoom
/// and pan here pin the chart's x domain to a viewport instead, moved by buttons that
/// VoiceOver and UI tests can reach as well as a finger.
///
/// **Semantic zoom.** A viewport names its own bucket: the metric's comparison window,
/// widened to the preset that fits the visible span, exactly as the whole-period chart
/// chooses its bucket. The screen re-reads just the visible span at that bucket, so a
/// one-hour view of a week is drawn from one-minute medians rather than from six-hour
/// medians magnified.
///
/// Nothing here draws, reads the store, or changes what an analysis computes: the period,
/// its statistics, and its pairs are untouched by zoom.
struct ChartViewport: Hashable, Sendable {
    /// The span the chart shows. Always inside the analysed period.
    let visible: DateInterval

    enum PanDirection: Sendable {
        case earlier
        case later
    }

    /// Narrowest span a history chart zooms to.
    static let minimumSpan: TimeInterval = 3_600

    /// Rounding allowance when comparing spans that were computed rather than typed.
    private static let slack: TimeInterval = 1

    // MARK: Buckets

    /// Spans a period of `duration` can zoom through, widest first. The whole period is
    /// the unzoomed state and is not listed.
    ///
    /// A span has to hold several of the metric's own comparison windows: zooming a daily
    /// resting heart rate into one hour would draw a single point, not more detail.
    static func zoomSpans(forPeriod duration: TimeInterval, kind: MetricKind) -> [TimeInterval] {
        let narrowest = max(minimumSpan, kind.comparisonWindow * 4)
        return TimeRange.allCases
            .map(\.duration)
            .filter { $0 < duration - slack && $0 >= narrowest }
            .sorted(by: >)
    }

    /// Bucket for a chart showing `span`: the metric's comparison window, widened to the
    /// preset that fits the span. The same rule the whole-period chart uses, so zooming all
    /// the way out and not zooming at all draw the same buckets.
    static func bucket(forSpan span: TimeInterval, kind: MetricKind) -> TimeInterval {
        max(kind.comparisonWindow, TimeRange.fitting(duration: span).chartBucket)
    }

    func bucket(for kind: MetricKind) -> TimeInterval {
        Self.bucket(forSpan: visible.duration, kind: kind)
    }

    // MARK: Zoom

    /// Whether the chart can zoom in from `current` (nil: the whole period).
    static func canZoomIn(from current: ChartViewport?, period: DateInterval, kind: MetricKind) -> Bool {
        narrowerSpan(than: current?.visible.duration ?? period.duration, period: period, kind: kind) != nil
    }

    /// The next narrower viewport, centred on `anchor` — the selected window, when there is
    /// one — or else on the middle of what is visible. Nil when no narrower span applies.
    static func zoomedIn(
        from current: ChartViewport?,
        period: DateInterval,
        kind: MetricKind,
        toward anchor: Date? = nil
    ) -> ChartViewport? {
        let visible = current?.visible ?? period
        guard let span = narrowerSpan(than: visible.duration, period: period, kind: kind) else { return nil }
        let centre = anchor ?? visible.start.addingTimeInterval(visible.duration / 2)
        return placed(centre: centre, span: span, period: period, kind: kind)
    }

    /// The next wider viewport around the middle of this one, or nil when the next step out
    /// is the whole period.
    func zoomedOut(period: DateInterval, kind: MetricKind) -> ChartViewport? {
        let wider = Self.zoomSpans(forPeriod: period.duration, kind: kind)
            .last { $0 > visible.duration + Self.slack }
        guard let wider else { return nil }
        return Self.placed(
            centre: visible.start.addingTimeInterval(visible.duration / 2),
            span: wider,
            period: period,
            kind: kind
        )
    }

    private static func narrowerSpan(than span: TimeInterval, period: DateInterval, kind: MetricKind) -> TimeInterval? {
        zoomSpans(forPeriod: period.duration, kind: kind).first { $0 < span - slack }
    }

    // MARK: Pan

    /// Half a span toward `direction`, stopping at the edge of the period.
    func panned(_ direction: PanDirection, period: DateInterval, kind: MetricKind) -> ChartViewport {
        let step = visible.duration / 2
        let centre = visible.start.addingTimeInterval(
            visible.duration / 2 + (direction == .earlier ? -step : step)
        )
        return Self.placed(centre: centre, span: visible.duration, period: period, kind: kind)
    }

    /// Whether a pan toward `direction` would move the view at all.
    func canPan(_ direction: PanDirection, period: DateInterval, kind: MetricKind) -> Bool {
        let moved = panned(direction, period: period, kind: kind).visible.start
        switch direction {
        case .earlier: return moved < visible.start
        case .later:   return moved > visible.start
        }
    }

    // MARK: Placement

    /// A viewport of `span` centred on `centre`, with its start on the bucket grid.
    ///
    /// It never leaves the period: the earliest start is the period's first bucket
    /// boundary, and the latest ends exactly at the period's end, so the newest readings of
    /// a rolling range stay reachable even though "now" is not on the grid.
    static func placed(centre: Date, span: TimeInterval, period: DateInterval, kind: MetricKind) -> ChartViewport {
        let bucket = bucket(forSpan: span, kind: kind)
        let earliest = ComparisonEngine.floorToWindow(period.start, size: bucket)
        let latest = period.end.addingTimeInterval(-span)
        var start = ComparisonEngine.floorToWindow(centre.addingTimeInterval(-span / 2), size: bucket)
        if start > latest { start = latest }
        if start < earliest { start = earliest }
        return ChartViewport(visible: DateInterval(start: start, duration: span))
    }

    /// This viewport after the period re-resolved — a rolling range moves with the clock.
    ///
    /// Unchanged while it still fits, so a live reload never nudges the view the user chose;
    /// moved only as far as the new period requires otherwise. Nil when the span no longer
    /// fits at all, which returns the chart to the whole period.
    func clamped(to period: DateInterval, kind: MetricKind) -> ChartViewport? {
        guard visible.duration < period.duration - Self.slack else { return nil }
        let earliest = ComparisonEngine.floorToWindow(period.start, size: bucket(for: kind))
        if visible.start >= earliest, visible.end <= period.end { return self }
        var start = visible.start
        if visible.end > period.end { start = period.end.addingTimeInterval(-visible.duration) }
        if start < earliest { start = earliest }
        return ChartViewport(visible: DateInterval(start: start, duration: visible.duration))
    }

    // MARK: Period selection

    /// A dragged period, snapped outward to whole buckets and kept inside `bounds`.
    ///
    /// The drag is snapped to the grid the chart draws, so the saved period starts and
    /// ends where the user saw window boundaries. Both ends are whole seconds: a rolling
    /// range ends at a fractional "now", and the sessions archive stores ISO-8601 dates
    /// without fractions, so an unrounded end would reopen a fraction of a second shorter
    /// than it was saved. Nil for a drag with no width: a tap in period mode is not a
    /// chosen period.
    static func snappedPeriod(
        from first: Date,
        to second: Date,
        bucket: TimeInterval,
        within bounds: ClosedRange<Date>
    ) -> DateInterval? {
        guard bucket > 0, first != second else { return nil }
        let lower = min(first, second)
        let upper = max(first, second)
        var start = ComparisonEngine.floorToWindow(lower, size: bucket)
        let floored = ComparisonEngine.floorToWindow(upper, size: bucket)
        var end = floored == upper ? upper : floored.addingTimeInterval(bucket)
        start = max(start, bounds.lowerBound)
        end = min(end, bounds.upperBound)
        start = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.up))
        end = Date(timeIntervalSince1970: end.timeIntervalSince1970.rounded(.down))
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// "1-minute medians", naming the bucket a chart is drawn from.
    static func bucketDescription(_ bucket: TimeInterval) -> String {
        "\(WindowLabel.length(bucket)) medians"
    }
}
