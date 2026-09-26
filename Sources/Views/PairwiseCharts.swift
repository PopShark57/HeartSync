import Charts
import SwiftUI

/// How the pair's charts draw each device: its colour and its shape.
struct PairwiseChartStyle {
    var colorA: Color
    var colorB: Color
    var symbolA: SourceSymbol
    var symbolB: SourceSymbol
}

/// The paired-value timeline (improvement 34).
///
/// Selection comes from Swift Charts' own `chartXSelection` gesture, not from the
/// zero-distance drag overlay it replaces, which claimed every touch on the chart and could
/// turn a swipe over it into a selection instead of a scroll. How the built-in gesture
/// shares a swipe with the list is still a device check (`RELEASE_CHECKLIST.md`). A view
/// of its own so the raw selection, which changes on every touch-move, re-evaluates only
/// this chart.
struct PairwiseTimelineChart: View {
    let kind: MetricKind
    let snapshot: PairwiseSnapshot
    let style: PairwiseChartStyle
    let nameA: String
    let nameB: String
    /// Shared with the difference plot, so selecting on either chart highlights both.
    @Binding var selectedObservationStart: Date?
    /// Moves the selection by whole windows, for VoiceOver's actions.
    var step: (Int) -> Void

    /// Raw value from `chartXSelection`: set while a finger is down, nil once it lifts.
    @State private var rawSelection: Date?
    /// Measured width, which turns the on-screen selection radius into seconds.
    @State private var chartWidth: CGFloat = 0

    var body: some View {
        let points = snapshot.plotted
        let selected = snapshot.observation(startingAt: selectedObservationStart)

        Chart {
            ForEach(Array(points.enumerated()), id: \.element.start) { position, observation in
                // Keyed per segment, not per device: a stretch with no paired window is a
                // gap in the comparison, and the line must not run through it.
                let segment = snapshot.timelineSegments[position]
                let isSelected = selectedObservationStart == observation.start

                LineMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceA.value),
                    series: .value("Device", ChartSegmentation.key(series: "A", segment: segment))
                )
                .foregroundStyle(style.colorA)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
                .accessibilityHidden(true)

                // Every window keeps its point, so an isolated pairing stays visible after
                // the line breaks around it. Shape as well as colour separates A from B.
                // A's point carries the whole window for VoiceOver, so each paired window
                // is one stop rather than two.
                PointMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceA.value)
                )
                .foregroundStyle(style.colorA)
                .symbol(style.symbolA.chartSymbol)
                .symbolSize(isSelected ? 80 : 28)
                .accessibilityLabel(snapshot.spokenSummary(observation))

                LineMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceB.value),
                    series: .value("Device", ChartSegmentation.key(series: "B", segment: segment))
                )
                .foregroundStyle(style.colorB)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
                .accessibilityHidden(true)

                PointMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceB.value)
                )
                .foregroundStyle(style.colorB)
                .symbol(style.symbolB.chartSymbol)
                .symbolSize(isSelected ? 80 : 28)
                .accessibilityHidden(true)
            }

            // "A" and "B" at the line ends, the higher label above and the lower below, so
            // the two lines can be told apart without comparing colours at all.
            if let last = points.last {
                let aIsHigher = last.sourceA.value >= last.sourceB.value
                lineEndLabel("A", value: last.sourceA.value, at: last.start, above: aIsHigher, color: style.colorA)
                lineEndLabel("B", value: last.sourceB.value, at: last.start, above: !aIsHigher, color: style.colorB)
            }

            if let selected {
                RuleMark(x: .value("Selected window", selected.start))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk.opacity(0.7))
                    .lineStyle(HeartSyncTheme.Chart.selection)
                    .accessibilityHidden(true)
                    // Fitted inside the chart on both axes, so the callout never clips at
                    // the first or last window.
                    .annotation(
                        position: .top,
                        spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        PairwiseObservationCallout(
                            kind: kind,
                            observation: selected,
                            isOutsideLimits: snapshot.isOutsideLimits(selected)
                        )
                    }
            }
        }
        .chartLegend(.hidden)
        // Pinned to the analysed span, so a stretch with no paired window stays visible.
        .chartXScale(domain: snapshot.timelineXDomain)
        .chartYScale(domain: snapshot.timelineYDomain)
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine()
                AxisValueLabel(format: HeartSyncTheme.Chart.axisFormat(span: snapshot.interval.duration))
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXSelection(value: $rawSelection)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            chartWidth = width
        }
        .onChange(of: rawSelection) { _, raw in
            snapSelection(to: raw)
        }
        .accessibilityLabel("Paired value timeline for \(nameA) and \(nameB)")
        .accessibilityHint("Select a paired window to read both values, or use the Previous and Next window actions.")
        .accessibilityAction(named: Text("Next paired window")) { step(1) }
        .accessibilityAction(named: Text("Previous paired window")) { step(-1) }
    }

    /// Snaps to the nearest drawn window within the on-screen radius. A touch farther than
    /// that from every window is in empty plot area and clears the selection; the finger
    /// lifting (nil) keeps it, so the callout can be read.
    private func snapSelection(to raw: Date?) {
        guard let raw else { return }
        let tolerance = ChartLookup.timeTolerance(
            points: ChartLookup.selectionRadius,
            plotWidth: Double(chartWidth),
            domain: snapshot.timelineXDomain
        )
        selectedObservationStart = snapshot.observation(nearestStart: raw, within: tolerance)?.start
    }

    /// An invisible anchor at a line's last point that carries its "A" or "B" label.
    private func lineEndLabel(
        _ text: String,
        value: Double,
        at date: Date,
        above: Bool,
        color: Color
    ) -> some ChartContent {
        PointMark(
            x: .value("Window", date),
            y: .value(kind.title, value)
        )
        .symbolSize(0)
        .annotation(
            position: above ? .top : .bottom,
            spacing: 4,
            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
        ) {
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        }
        .accessibilityHidden(true)
    }
}

/// The Bland–Altman difference plot (improvement 34).
///
/// A tap selects the point drawn nearest the finger in both x and y, so an outlier stacked
/// above the dense cluster at the same paired mean can be picked on its own; a tap in empty
/// plot area clears the selection. A tap never competes with scrolling the list.
struct PairwiseDifferenceChart: View {
    let kind: MetricKind
    let snapshot: PairwiseSnapshot
    @Binding var selectedObservationStart: Date?
    /// Moves the selection by whole windows, for VoiceOver's actions.
    var step: (Int) -> Void

    var body: some View {
        let points = snapshot.plotted
        let selected = snapshot.observation(startingAt: selectedObservationStart)

        Chart {
            // Reference lines are neutral ink told apart by dash pattern and weight. Hue is
            // reserved for devices and for the agreement scale, so no statistic can be
            // mistaken for a device line on the timeline above.
            RuleMark(y: .value("Zero difference", 0))
                .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
                .lineStyle(HeartSyncTheme.Chart.zeroDifference)

            toleranceRules(kind.agreement.warn, label: "Warning", style: HeartSyncTheme.Chart.warningTolerance)
            toleranceRules(kind.agreement.alert, label: "Major", style: HeartSyncTheme.Chart.majorTolerance)

            if let stats = snapshot.analysis.statistics {
                RuleMark(y: .value("Mean bias", stats.meanBias))
                    .foregroundStyle(HeartSyncTheme.Chart.referenceInk)
                    .lineStyle(HeartSyncTheme.Chart.meanBias)

                RuleMark(y: .value("Lower 95% limit", stats.limitsOfAgreement.lowerBound))
                    .foregroundStyle(HeartSyncTheme.Chart.referenceInk)
                    .lineStyle(HeartSyncTheme.Chart.limitsOfAgreement)

                RuleMark(y: .value("Upper 95% limit", stats.limitsOfAgreement.upperBound))
                    .foregroundStyle(HeartSyncTheme.Chart.referenceInk)
                    .lineStyle(HeartSyncTheme.Chart.limitsOfAgreement)
            }

            ForEach(points, id: \.start) { observation in
                let outside = snapshot.isOutsideLimits(observation)
                PointMark(
                    x: .value("Paired mean", observation.pairedMean),
                    y: .value("A minus B", observation.signedDifference)
                )
                .foregroundStyle(observation.severity.tint)
                .symbolSize(symbolSize(observation, outside: outside))
                .accessibilityLabel(snapshot.spokenSummary(observation))

                // Outside the limits is a statistical fact, so it is marked in the limits'
                // own neutral ink: a ring, rather than a hue that a device also wears.
                if outside {
                    PointMark(
                        x: .value("Paired mean", observation.pairedMean),
                        y: .value("A minus B", observation.signedDifference)
                    )
                    .symbol {
                        Circle()
                            .strokeBorder(HeartSyncTheme.Chart.referenceInk, lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                    }
                    .accessibilityHidden(true)
                }
            }

            if let selected {
                RuleMark(x: .value("Selected paired mean", selected.pairedMean))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk.opacity(0.55))
                    .lineStyle(HeartSyncTheme.Chart.selection)
                    .accessibilityHidden(true)

                // An invisible anchor at the selected point that carries its callout, so the
                // values are readable here without scrolling back up to the timeline.
                PointMark(
                    x: .value("Paired mean", selected.pairedMean),
                    y: .value("A minus B", selected.signedDifference)
                )
                .symbolSize(0)
                .accessibilityHidden(true)
                .annotation(
                    position: .top,
                    spacing: 10,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    PairwiseObservationCallout(
                        kind: kind,
                        observation: selected,
                        isOutsideLimits: snapshot.isOutsideLimits(selected)
                    )
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: snapshot.differenceXDomain)
        .chartYScale(domain: snapshot.differenceYDomain)
        .chartXAxisLabel("Paired mean (\(kind.unit))")
        .chartYAxisLabel("A − B (\(kind.unit))")
        .chartXAxis { AxisMarks(preset: .aligned) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        select(at: location, proxy: proxy, geometry: geometry)
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Bland Altman plot of Device A minus Device B")
        .accessibilityHint("Select a point to read its paired window, or use the Previous and Next window actions.")
        .accessibilityAction(named: Text("Next paired window")) { step(1) }
        .accessibilityAction(named: Text("Previous paired window")) { step(-1) }
    }

    /// Selects the point nearest the tap on screen, or nothing when every point is farther
    /// than the selection radius.
    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        let plotLocation = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        selectedObservationStart = snapshot.observation(
            nearestTo: plotLocation,
            within: ChartLookup.selectionRadius
        ) { observation in
            guard let x = proxy.position(forX: observation.pairedMean),
                  let y = proxy.position(forY: observation.signedDifference)
            else { return nil }
            return CGPoint(x: x, y: y)
        }?.start
    }

    @ChartContentBuilder
    private func toleranceRules(
        _ tolerance: Double,
        label: String,
        style: StrokeStyle
    ) -> some ChartContent {
        RuleMark(y: .value("Positive \(label) tolerance", tolerance))
            .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
            .lineStyle(style)
        RuleMark(y: .value("Negative \(label) tolerance", -tolerance))
            .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
            .lineStyle(style)
    }

    private func symbolSize(_ observation: PairwiseObservation, outside: Bool) -> CGFloat {
        if selectedObservationStart == observation.start { return 115 }
        if outside || observation.severity != .agreeing { return 75 }
        return 42
    }
}

/// The compact on-chart callout for one paired window: A, B, A − B, and whether the two
/// readings were taken close enough together to describe the same moment. The full card
/// below the charts keeps every other detail.
///
/// Hidden from VoiceOver, which reads the same values from the selected point.
struct PairwiseObservationCallout: View {
    let kind: MetricKind
    let observation: PairwiseObservation
    let isOutsideLimits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(observation.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2.weight(.semibold))
            Text("A \(kind.formatWithUnit(observation.sourceA.value))")
            Text("B \(kind.formatWithUnit(observation.sourceB.value))")
            Text("A \u{2212} B \(PairwiseSnapshot.signed(observation.signedDifference, kind: kind)) \(kind.unit)")
                .foregroundStyle(observation.severity.tint)
            Text(observation.timing.title)
                .foregroundStyle(observation.timing.supportsConclusion ? Color.secondary : HeartSyncTheme.Chart.cautionInk)
            if isOutsideLimits {
                Text("Outside the observed 95% limits")
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .fixedSize()
        .padding(7)
        .foregroundStyle(.primary)
        .background(HeartSyncTheme.Chart.calloutBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.secondary.opacity(0.25))
        }
        .accessibilityHidden(true)
    }
}
