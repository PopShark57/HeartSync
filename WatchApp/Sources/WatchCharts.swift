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
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
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
            Label("\(comparison.outsideTolerancePairs) pair\(comparison.outsideTolerancePairs == 1 ? "" : "s") outside tolerance", systemImage: "exclamationmark.triangle.fill")
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

/// The wrist counterpart of iPhone's Compare tab: every metric with two or more sources,
/// its verdict, and the leading pair's mean difference.
struct WatchCompareView: View {
    let connection: CompanionSession

    var body: some View {
        List {
            if let snapshot = connection.snapshot, snapshot.availability == .ready {
                let compared = snapshot.metrics.filter {
                    $0.readings.count + $0.omittedSourceCount >= 2
                        || $0.comparison.readyPairs + $0.comparison.incompletePairs > 0
                }
                if compared.isEmpty {
                    Section {
                        Label("Nothing to compare yet", systemImage: "square.split.2x1")
                        Text("A comparison needs two sources reporting the same metric, such as a ring and Apple Watch through Health.")
                            .font(.caption)
                    }
                } else {
                    Section {
                        ForEach(compared) { metric in
                            NavigationLink {
                                WatchMetricDetailView(metric: metric, generatedAt: snapshot.generatedAt)
                            } label: {
                                WatchCompareRow(metric: metric)
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
}

private struct WatchCompareRow: View {
    let metric: WatchMetric
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(metric.kind.title, systemImage: metric.kind.systemImage)
                .font(.caption)
                .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.secondary) : AnyShapeStyle(metric.kind.tint))
            WatchVerdictLabel(comparison: metric.comparison)
                .font(.caption2)
            if let pair = metric.chart?.pair {
                Text("\(pair.sourceA) \u{2212} \(pair.sourceB): \(WatchChartProjection.signed(pair.meanBias, kind: metric.kind))")
                    .font(.caption2).monospacedDigit()
                    .lineLimit(2)
                    .privacySensitive()
            }
            if !isLuminanceReduced, let chart = metric.chart {
                WatchTrendChart(kind: metric.kind, chart: chart, lookback: metric.comparison.lookback, compact: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
