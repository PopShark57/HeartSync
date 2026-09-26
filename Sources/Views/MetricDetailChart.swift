import Charts
import SwiftUI

/// The metric-detail chart: device lines, the disagreement band, a scrubbable selection
/// with an inline callout (improvement 32), and period dragging (improvement 33).
///
/// A view of its own so a touch-move, which re-evaluates the chart on every frame, does not
/// re-evaluate the list around it. Everything drawn or looked up during a scrub comes from
/// the `MetricChartProjection` it is handed: nothing here reads the store.
struct MetricDetailChart: View {
    let kind: MetricKind
    let chart: MetricChartProjection
    /// The legend's series, so every scale on the chart shares one source-ID domain.
    let series: [SourceSeries]
    /// A legend entry the user emphasised. The other devices dim; nothing is removed.
    let emphasisedSourceID: String?
    /// A chosen period, drawn as a neutral band so the chart shows what it covers.
    let selectedPeriod: DateInterval?
    /// While true, a drag chooses a period instead of scrubbing.
    let isSelectingPeriod: Bool
    /// The window the callout describes. It stays after the finger lifts, so it can be
    /// read; a touch in empty plot area clears it.
    @Binding var selectedWindowStart: Date?
    /// Receives a dragged period, already snapped to the drawn buckets.
    var onSelectPeriod: (DateInterval) -> Void

    /// Raw value from `chartXSelection`: set while a finger is down, nil once it lifts.
    @State private var rawSelection: Date?
    /// Measured width, which turns the on-screen selection radius into seconds.
    @State private var chartWidth: CGFloat = 0
    /// The period being dragged out, before it is snapped.
    @State private var draggedPeriod: ClosedRange<Date>?

    var body: some View {
        let selected = chart.window(startingAt: selectedWindowStart)
        let highlight = periodHighlight

        Chart {
            if let highlight {
                RectangleMark(
                    xStart: .value("Period start", highlight.lowerBound),
                    xEnd: .value("Period end", highlight.upperBound)
                )
                .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk.opacity(0.12))
                .accessibilityHidden(true)
            }

            ForEach(chart.bandPoints) { band in
                if band.isIsolated {
                    // One compared window between gaps: an area needs two points, so it is
                    // drawn as a short bar spanning that window's spread.
                    RuleMark(
                        x: .value("Time", band.date),
                        yStart: .value("Low", band.low),
                        yEnd: .value("High", band.high)
                    )
                    .foregroundStyle(band.severity.tint.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                    .accessibilityHidden(true)
                } else {
                    // Keyed per run: the band breaks where nothing was compared and where
                    // the severity changes, since an area series takes a single style.
                    AreaMark(
                        x: .value("Time", band.date),
                        yStart: .value("Low", band.low),
                        yEnd: .value("High", band.high),
                        series: .value("Band", band.seriesKey)
                    )
                    .foregroundStyle(band.severity.tint.opacity(0.16))
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                }
            }

            // Every mark keys on `sourceID`, never on the display name. Two devices called
            // "Polar H10" are two series; renaming one is a label change, not a data move.
            ForEach(chart.points) { point in
                let emphasis = emphasisedSourceID == nil || emphasisedSourceID == point.sourceID ? 1.0 : 0.2
                let isSelected = point.date == selected?.start

                LineMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value),
                    // Segment key, not source key: the line breaks across a gap in this
                    // source's data rather than implying continuous measurement.
                    series: .value("Source", point.seriesKey)
                )
                .foregroundStyle(by: .value("Source", point.sourceID))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: point.isEstimate ? [4, 3] : []))
                .interpolationMethod(.monotone)
                .opacity(emphasis)
                .accessibilityHidden(true)

                // Dots keep single-sample series visible; LineMark alone draws nothing for
                // one point. They are also what VoiceOver visits, once per device per window.
                PointMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value)
                )
                .foregroundStyle(by: .value("Source", point.sourceID))
                .symbol(by: .value("Source", point.sourceID))
                .symbolSize(isSelected ? 90 : 36)
                .opacity(emphasis)
                .accessibilityLabel(spokenLabel(point))
                .accessibilityValue(spokenValue(point))
            }

            if let selected {
                RuleMark(x: .value("Selected window", selected.start))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
                    .lineStyle(HeartSyncTheme.Chart.selection)
                    .accessibilityHidden(true)
                    // Fitted inside the chart on both axes, so the callout never clips at the
                    // first or last window and never spills over the rows around the chart.
                    .annotation(
                        position: .top,
                        spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        MetricWindowCallout(kind: kind, window: selected, series: series)
                    }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.sourceID), range: series.map(\.color))
        .chartSymbolScale(domain: series.map(\.sourceID), range: series.map(\.symbol.chartSymbol))
        .chartLegend(.hidden)
        // Pinned to the whole drawn span, so an empty stretch stays visibly empty.
        .chartXScale(domain: chart.xDomain)
        .chartYScale(domain: chart.yDomain)
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine()
                AxisValueLabel(format: HeartSyncTheme.Chart.axisFormat(span: chart.interval.duration))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartYAxisLabel(kind.unit)
        // Names each device in the Audio Graph; the automatic one would name source IDs.
        .accessibilityChartDescriptor(MetricAudioGraph(kind: kind, chart: chart, series: series))
        // Swift Charts recognises the gesture itself, rather than an overlay claiming every
        // touch; how it shares a vertical swipe with the list is a device check. In period
        // mode the binding ignores it and the overlay below takes the drag instead.
        .chartXSelection(value: selectionBinding)
        .chartOverlay { proxy in
            if isSelectingPeriod {
                periodDragLayer(proxy)
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            chartWidth = width
        }
        .onChange(of: rawSelection) { _, raw in
            snapSelection(to: raw)
        }
        // One tick per window, not per pixel: the trigger is the snapped window.
        .sensoryFeedback(.selection, trigger: selectedWindowStart) { _, new in new != nil }
    }

    /// Writes from `chartXSelection` are ignored while a period is being chosen.
    private var selectionBinding: Binding<Date?> {
        Binding(
            get: { rawSelection },
            set: { value in
                if !isSelectingPeriod { rawSelection = value }
            }
        )
    }

    /// Snaps a raw selection to the nearest drawn window within the on-screen radius. A
    /// touch farther than that from every window is in empty plot area and clears the
    /// selection; the finger lifting (nil) keeps it.
    private func snapSelection(to raw: Date?) {
        guard let raw, !isSelectingPeriod else { return }
        let tolerance = ChartLookup.timeTolerance(
            points: ChartLookup.selectionRadius,
            plotWidth: Double(chartWidth),
            domain: chart.xDomain
        )
        selectedWindowStart = chart.window(nearest: raw, within: tolerance)?.start
    }

    /// The chosen or in-progress period, clipped to what this chart draws.
    private var periodHighlight: ClosedRange<Date>? {
        let shown = draggedPeriod ?? selectedPeriod.map { $0.start...$0.end }
        guard let shown else { return nil }
        let lower = max(shown.lowerBound, chart.xDomain.lowerBound)
        let upper = min(shown.upperBound, chart.xDomain.upperBound)
        return lower < upper ? lower...upper : nil
    }

    /// A transparent layer that turns a drag into a period. Only present in period mode,
    /// so ordinary scrubbing and list scrolling are untouched the rest of the time.
    private func periodDragLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let originX = geometry[plotFrame].origin.x
                            guard let start = proxy.value(atX: value.startLocation.x - originX, as: Date.self),
                                  let current = proxy.value(atX: value.location.x - originX, as: Date.self)
                            else { return }
                            draggedPeriod = min(start, current)...max(start, current)
                        }
                        .onEnded { _ in
                            if let dragged = draggedPeriod,
                               let period = ChartViewport.snappedPeriod(
                                   from: dragged.lowerBound,
                                   to: dragged.upperBound,
                                   bucket: chart.bucketSize,
                                   within: chart.xDomain
                               ) {
                                onSelectPeriod(period)
                            }
                            draggedPeriod = nil
                        }
                )
        }
        .accessibilityHidden(true)
    }

    // MARK: - Accessibility

    private func spokenLabel(_ point: ChartPoint) -> String {
        "\(point.sourceName), \(point.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    /// The window median with its unit, and any reason it is not a plain measurement.
    private func spokenValue(_ point: ChartPoint) -> String {
        var parts = [kind.formatWithUnit(point.value), "window median"]
        if point.isEstimate { parts.append("estimate, not measured") }
        if point.isCompacted { parts.append("compacted") }
        return parts.joined(separator: ", ")
    }

}

/// The inline callout for one selected window: its span, each device's window median with
/// the device's colour and shape, the spread against the tolerances, and any estimate or
/// compacted caveat.
///
/// Hidden from VoiceOver, which reads the same values from the chart's points.
struct MetricWindowCallout: View {
    let kind: MetricKind
    let window: ChartWindowSummary
    let series: [SourceSeries]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(spanText)
                .font(.caption2.weight(.semibold))
            Text("\(WindowLabel.length(window.duration)) window medians")
                .foregroundStyle(.secondary)

            ForEach(window.values) { value in
                HStack(spacing: 4) {
                    if let entry = series.first(where: { $0.sourceID == value.sourceID }) {
                        SourceSymbolGlyph(symbol: entry.symbol, color: entry.color, size: 7)
                    }
                    Text(value.label)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(kind.formatWithUnit(value.value))
                        .monospacedDigit()
                }
                if value.isEstimate {
                    Text("Estimate: modelled, not measured")
                        .foregroundStyle(HeartSyncTheme.Chart.cautionInk)
                }
            }

            if let spread = window.spread {
                Text(spread.summary(for: kind))
                    .foregroundStyle(spread.severity.tint)
            } else {
                Text("Not compared: fewer than two measured devices")
                    .foregroundStyle(.secondary)
            }
            if window.hasCompacted {
                Text("Compacted median: raw samples no longer stored")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.secondary.opacity(0.25))
        }
        .accessibilityHidden(true)
    }

    private var spanText: String {
        let start = window.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let end = window.end.formatted(.dateTime.hour().minute())
        return "\(start)\u{2013}\(end)"
    }
}
