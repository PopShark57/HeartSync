import Charts
import SwiftUI

extension WatchColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension WatchSourceShape {
    var chartSymbol: BasicChartSymbolShape {
        switch self {
        case .circle:   .circle
        case .square:   .square
        case .triangle: .triangle
        case .diamond:  .diamond
        case .pentagon: .pentagon
        case .cross:    .cross
        case .asterisk: .asterisk
        }
    }

    /// The same shape as an SF Symbol, for legends.
    var systemImage: String {
        switch self {
        case .circle:   "circle.fill"
        case .square:   "square.fill"
        case .triangle: "triangle.fill"
        case .diamond:  "diamond.fill"
        case .pentagon: "pentagon.fill"
        case .cross:    "xmark"
        case .asterisk: "asterisk"
        }
    }
}

/// Every displayed source's window medians on one pinned time axis, as on iPhone's metric
/// detail: each source keeps its iPhone colour and shape, lines break at gaps, isolated
/// windows are points, and estimates are dashed.
struct WatchTrendChart: View {
    let kind: MetricKind
    let chart: WatchChart
    let lookback: TimeInterval
    /// A row sparkline: no axes, no legend, a fixed small height, and no selection.
    var compact = false
    /// The middle of the selected window. Kept when the finger lifts.
    @State private var selectedDate: Date?

    private struct Plotted: Identifiable {
        var series: WatchChartSeries
        var points: [WatchChartProjection.Point]
        var id: String { series.id }
    }

    private var plotted: [Plotted] {
        chart.series.map { Plotted(series: $0, points: WatchChartProjection.points(for: $0, in: chart)) }
    }

    /// The period the axis labels describe; an older iPhone sends none, so infer it.
    private var axisRange: WatchChartRange {
        chart.range ?? WatchChartRange.allCases.first { $0.duration >= chart.span - chart.bucket } ?? .month
    }

    var body: some View {
        let windows = compact ? [] : WatchChartProjection.windows(in: chart)
        let selected = selectedDate.flatMap { date in windows.first { $0.date == date } }
        Chart {
            ForEach(plotted) { entry in
                let item = entry.series
                let style = StrokeStyle(lineWidth: compact ? 1.5 : 2, dash: item.isEstimated ? [3, 2] : [])
                ForEach(entry.points) { point in
                    if !point.isIsolated {
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(kind.shortTitle, point.value),
                            series: .value("Series", point.segmentKey)
                        )
                        .interpolationMethod(.linear)
                        .lineStyle(style)
                        .foregroundStyle(item.color.color)
                    }
                    if !compact || point.isIsolated {
                        PointMark(
                            x: .value("Time", point.date),
                            y: .value(kind.shortTitle, point.value)
                        )
                        .symbol(item.shape.chartSymbol)
                        .symbolSize(compact ? 12 : 20)
                        .foregroundStyle(item.color.color)
                    }
                }
            }
            if let selected {
                // A neutral rule, never a device's hue, with the window's values above it.
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        spacing: 2,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        WatchWindowCallout(kind: kind, window: selected, range: chart.range)
                    }
                ForEach(selected.entries, id: \.seriesID) { entry in
                    PointMark(
                        x: .value("Time", selected.date),
                        y: .value(kind.shortTitle, entry.value)
                    )
                    .symbol(entry.shape.chartSymbol)
                    .symbolSize(70)
                    .foregroundStyle(entry.color.color)
                }
            }
        }
        .chartXScale(domain: chart.start...chart.end)
        .chartYScale(domain: WatchChartProjection.valueDomain(kind: kind, chart: chart))
        // Round local times, short labels, and none at the edges: a date and a time together
        // cannot fit under a watch plot.
        .chartXAxis {
            AxisMarks(values: WatchChartProjection.axisTicks(range: axisRange, start: chart.start, end: chart.end)) { _ in
                AxisGridLine()
                AxisValueLabel(format: WatchChartProjection.axisFormat(for: axisRange))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .chartXAxis(compact ? .hidden : .visible)
        .chartYAxis(compact ? .hidden : .visible)
        .chartLegend(.hidden)
        .modifier(WatchChartSelection(
            isEnabled: !compact,
            dates: windows.map(\.date),
            domain: chart.start...chart.end,
            selection: $selectedDate
        ))
        .frame(height: compact ? 30 : 110)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchChartProjection.spokenSummary(kind: kind, chart: chart, lookback: lookback))
        .accessibilityValue(selected.map { WatchChartProjection.selectionSummary(kind: kind, window: $0, range: chart.range) } ?? "")
        .modifier(WatchChartSelectionAccessibility(isEnabled: !compact, dates: windows.map(\.date), selection: $selectedDate))
        // A new period or snapshot draws different windows.
        .onChange(of: chart.start) { selectedDate = nil }
    }
}

/// The small popup for a selected window: when it was, and each source's median there.
private struct WatchWindowCallout: View {
    let kind: MetricKind
    let window: WatchChartProjection.Window
    let range: WatchChartRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(WatchChartProjection.windowText(start: window.start, end: window.end, range: range))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(window.entries, id: \.seriesID) { entry in
                HStack(spacing: 3) {
                    Image(systemName: entry.shape.systemImage)
                        .font(.system(size: 7))
                        .foregroundStyle(entry.color.color)
                    Text(kind.formatWithUnit(entry.value))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    if entry.isEstimated {
                        Text("est.").foregroundStyle(.orange)
                    }
                    Text(entry.sourceName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// Tap a chart, or touch and hold and then slide, to pick the nearest plotted window. The
/// selection stays when the finger lifts; a touch farther than the selection radius from
/// every window clears it. Holding first lets a plain swipe still scroll the list.
private struct WatchChartSelection: ViewModifier {
    let isEnabled: Bool
    /// Ascending.
    let dates: [Date]
    let domain: ClosedRange<Date>
    @Binding var selection: Date?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                LongPressGesture(minimumDuration: 0.25)
                                    .sequenced(before: DragGesture(minimumDistance: 0))
                                    .onChanged { value in
                                        guard case .second(true, let drag?) = value else { return }
                                        select(at: drag.location, proxy: proxy, geometry: geometry)
                                    }
                            )
                            .simultaneousGesture(
                                SpatialTapGesture().onEnded { value in
                                    select(at: value.location, proxy: proxy, geometry: geometry)
                                }
                            )
                    }
                }
                .sensoryFeedback(.selection, trigger: selection)
        } else {
            content
        }
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let frame = geometry[anchor]
        guard let date: Date = proxy.value(atX: location.x - frame.minX) else { return }
        let tolerance = ChartLookup.timeTolerance(
            points: ChartLookup.selectionRadius,
            plotWidth: frame.width,
            domain: domain
        )
        selection = WatchChartProjection.nearestDate(to: date, in: dates, within: tolerance)
    }
}

/// The legend: shape, colour, and name, so a colour is never the only cue.
struct WatchChartLegend: View {
    let chart: WatchChart

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(chart.series) { series in
                HStack(spacing: 4) {
                    Image(systemName: series.shape.systemImage)
                        .font(.system(size: 8))
                        .foregroundStyle(series.color.color)
                    Text(series.sourceName).lineLimit(1)
                    if series.isEstimated {
                        Text("estimate").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One pair's per-window differences around its bias and 95% limits, like iPhone's pair
/// difference chart. Reference lines use neutral inks, never a device's colour.
struct WatchDifferenceChart: View {
    let kind: MetricKind
    let chart: WatchChart
    let pair: WatchPairAgreement
    @State private var selectedDate: Date?

    var body: some View {
        let points = WatchChartProjection.differencePoints(for: pair, in: chart, window: kind.comparisonWindow)
        let selected = selectedDate.flatMap { date in points.first { $0.date == date } }
        Chart {
            RuleMark(y: .value("Zero", 0.0))
                .foregroundStyle(.gray.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(y: .value("Mean difference", pair.meanBias))
                .foregroundStyle(.white.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
            RuleMark(y: .value("Lower limit", pair.lowerLimit))
                .foregroundStyle(.gray)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 2]))
            RuleMark(y: .value("Upper limit", pair.upperLimit))
                .foregroundStyle(.gray)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 2]))
            ForEach(points) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Difference", point.difference)
                )
                .symbolSize(14)
                .foregroundStyle(.white)
            }
            if let selected {
                PointMark(
                    x: .value("Time", selected.date),
                    y: .value("Difference", selected.difference)
                )
                .symbolSize(60)
                .foregroundStyle(.white)
                .annotation(
                    position: .top,
                    spacing: 2,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(windowText(selected))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(WatchChartProjection.signed(selected.difference, kind: kind))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                }
            }
        }
        .chartXScale(domain: chart.start...chart.end)
        .chartYScale(domain: WatchChartProjection.differenceDomain(pair: pair))
        .chartXAxis(.hidden)
        .modifier(WatchChartSelection(
            isEnabled: true,
            dates: points.map(\.date),
            domain: chart.start...chart.end,
            selection: $selectedDate
        ))
        .frame(height: 80)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchChartProjection.pairSummary(kind: kind, pair: pair))
        .accessibilityValue(selected.map {
            WatchChartProjection.differenceSummary(kind: kind, pair: pair, point: $0, window: kind.comparisonWindow, range: chart.range)
        } ?? "")
        .modifier(WatchChartSelectionAccessibility(isEnabled: true, dates: points.map(\.date), selection: $selectedDate))
        .onChange(of: chart.start) { selectedDate = nil }
    }

    private func windowText(_ point: WatchChartProjection.DifferencePoint) -> String {
        let start = point.date.addingTimeInterval(-kind.comparisonWindow / 2)
        return WatchChartProjection.windowText(start: start, end: start.addingTimeInterval(kind.comparisonWindow), range: chart.range)
    }
}

/// The comparison verdict with the iPhone's rules: a gap outside tolerance always shows,
/// green needs every pair ready and inside tolerance, and anything else is insufficient.
struct WatchVerdictLabel: View {
    let comparison: WatchComparison

    var body: some View {
        if comparison.outsideTolerancePairs > 0 {
            Label(String(
                localized: "watch.comparison.outside",
                defaultValue: "\(comparison.outsideTolerancePairs) pairs outside tolerance",
                comment: "Wrist comparison summary. The argument is how many device pairs disagree beyond tolerance."
            ), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if comparison.allPairsAgree {
            Label("Within tolerance", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Insufficient evidence", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }
}

/// Chooses the comparison period: 1H, 3H, 24H, 7D, or 30D. Periods the iPhone did not send
/// for this metric (a daily metric has no 1H or 3H) are shown but disabled.
struct WatchRangePicker: View {
    @Binding var selection: WatchChartRange
    let available: [WatchChartRange]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WatchChartRange.allCases) { range in
                let isSelected = range == selection
                let isAvailable = available.contains(range)
                Button {
                    selection = range
                } label: {
                    Text(range.rawValue)
                        .font(.caption2.weight(isSelected ? .bold : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Capsule())
                        .watchGlassCapsule(selected: isSelected)
                }
                .buttonStyle(.borderless)
                .disabled(!isAvailable)
                .opacity(isAvailable ? 1 : 0.35)
                .accessibilityLabel(range.spokenTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// The period the watch shows everywhere, remembered between launches.
enum WatchRangeSelection {
    static let storageKey = "watch.chart.range"
}

/// The wrist counterpart of iPhone's Compare tab: every metric with two or more sources,
/// its verdict for the chosen period, and the leading pair's mean difference.
struct WatchCompareView: View {
    let connection: CompanionSession
    @AppStorage(WatchRangeSelection.storageKey) private var selectedRange: WatchChartRange = .standard

    var body: some View {
        List {
            if let snapshot = connection.snapshot, snapshot.availability == .ready {
                let compared = snapshot.metrics.filter(Self.isCompared)
                if compared.isEmpty {
                    Section {
                        Label("Nothing to compare yet", systemImage: "square.split.2x1")
                        Text("A comparison needs two sources reporting the same metric, such as a ring and Apple Watch through Health.")
                            .font(.caption)
                    }
                } else {
                    Section {
                        WatchRangePicker(selection: $selectedRange, available: WatchChartRange.allCases)
                            .listRowBackground(Color.clear)
                        ForEach(compared) { metric in
                            NavigationLink {
                                WatchMetricDetailView(metric: metric, generatedAt: snapshot.generatedAt)
                            } label: {
                                WatchCompareRow(metric: metric, selection: selectedRange)
                            }
                            .listRowBackground(WatchCardBackground(tint: metric.kind.tint))
                        }
                    } footer: {
                        Text("At least five paired windows are needed for a verdict. Estimates are excluded. A comparison does not show which device is right.")
                    }
                }
            } else {
                Section {
                    Label("No comparison yet", systemImage: "iphone")
                    Text("Open HeartSync on iPhone to send the latest readings.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Compare")
        .containerBackground(WatchTheme.backdrop, for: .navigation)
    }

    /// Two or more sources now, or pairs in any period.
    private static func isCompared(_ metric: WatchMetric) -> Bool {
        if metric.readings.count + metric.omittedSourceCount >= 2 { return true }
        let comparisons = [metric.comparison] + metric.allCharts.compactMap(\.comparison)
        return comparisons.contains { $0.readyPairs + $0.incompletePairs > 0 }
    }
}

private struct WatchCompareRow: View {
    let metric: WatchMetric
    let selection: WatchChartRange
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// The chosen period, or the nearest one this metric has (a daily metric has no 1H).
    private var range: WatchChartRange? {
        WatchChartRange.resolved(selection, among: metric.availableRanges ?? [])
    }

    private var chart: WatchChart? {
        range.flatMap(metric.periodChart) ?? (metric.availableRanges == nil ? metric.chart : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(metric.kind.title, systemImage: metric.kind.systemImage)
                    .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.secondary) : AnyShapeStyle(metric.kind.tint))
                if let range, range != selection {
                    Spacer(minLength: 2)
                    Text(range.rawValue).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            WatchVerdictLabel(comparison: range.map(metric.periodComparison) ?? metric.comparison)
                .font(.caption2)
            if let pair = chart?.pair {
                Text("\(pair.sourceA) \u{2212} \(pair.sourceB): \(WatchChartProjection.signed(pair.meanBias, kind: metric.kind))")
                    .font(.caption2).monospacedDigit()
                    .lineLimit(2)
                    .privacySensitive()
            }
            if !isLuminanceReduced, let chart, !chart.series.isEmpty {
                WatchTrendChart(kind: metric.kind, chart: chart, lookback: chart.comparison?.lookback ?? metric.comparison.lookback, compact: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The selection without a gesture: VoiceOver's adjustable action steps through the
/// windows, and a named action clears it. Applied to the chart's combined element.
private struct WatchChartSelectionAccessibility: ViewModifier {
    let isEnabled: Bool
    /// Ascending.
    let dates: [Date]
    @Binding var selection: Date?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        selection = WatchChartProjection.steppedDate(from: selection, in: dates, forward: true)
                    case .decrement:
                        selection = WatchChartProjection.steppedDate(from: selection, in: dates, forward: false)
                    @unknown default:
                        break
                    }
                }
                .accessibilityAction(named: Text("Clear selection")) { selection = nil }
        } else {
            content
        }
    }
}

