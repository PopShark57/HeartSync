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
    /// A row sparkline: no axes, no legend, a fixed small height.
    var compact = false

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
        .frame(height: compact ? 30 : 110)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchChartProjection.spokenSummary(kind: kind, chart: chart, lookback: lookback))
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

    var body: some View {
        let points = WatchChartProjection.differencePoints(for: pair, in: chart, window: kind.comparisonWindow)
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
        }
        .chartXScale(domain: chart.start...chart.end)
        .chartYScale(domain: WatchChartProjection.differenceDomain(pair: pair))
        .chartXAxis(.hidden)
        .frame(height: 80)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchChartProjection.pairSummary(kind: kind, pair: pair))
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

/// Chooses the comparison period, like iPhone's 1H/24H/7D/30D control. Periods the iPhone
/// did not send for this metric (a daily metric has no 1H) are shown but disabled.
struct WatchRangePicker: View {
    @Binding var selection: WatchChartRange
    let available: [WatchChartRange]

    var body: some View {
        HStack(spacing: 4) {
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
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            Capsule().fill(isSelected ? Color.pink.opacity(0.45) : Color.gray.opacity(0.22))
                        )
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
