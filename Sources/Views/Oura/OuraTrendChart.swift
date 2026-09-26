import Charts
import SwiftUI

/// A fourteen-day trend inside an Oura score or biomarker card (improvement 35).
///
/// Days are categories keyed by Oura's own calendar day, never binned by the phone's
/// calendar, so a day cannot slide to its neighbour west of Greenwich. A missing day is an
/// empty slot: no bar, and a line that breaks rather than bridging it. The latest reported
/// day is drawn strongest; a tap on another day reveals its value in the card.
///
/// Hidden from VoiceOver: the card's own label carries the trend as one sentence.
struct OuraTrendChart: View {
    enum Style: Sendable {
        /// Scores from 0 to 100, as bars from zero.
        case bars
        /// A physiological value with no meaningful zero, as a line with points.
        case line
        /// A signed deviation from the user's own baseline, as bars above and below zero.
        case deviation
    }

    let trend: OuraDailyTrend
    let style: Style
    let tint: Color
    /// The day a tap revealed. The card shows that day's value instead of the latest.
    @Binding var selectedKey: String?

    /// Raw value from `chartXSelection`: set while a finger is down, nil once it lifts.
    @State private var rawSelection: String?

    var body: some View {
        let highlighted = selectedKey ?? trend.latest?.key

        Chart {
            if style == .deviation {
                // Neutral ink: the baseline is a reference, not a device or a verdict.
                RuleMark(y: .value("Baseline", 0))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
                    .lineStyle(HeartSyncTheme.Chart.zeroDifference)
            }

            if style == .line {
                ForEach(trend.segments) { entry in
                    let day = trend.days[entry.index]
                    let value = day.value ?? 0
                    LineMark(
                        x: .value("Day", day.key),
                        y: .value("Value", value),
                        series: .value("Run", entry.segment)
                    )
                    .foregroundStyle(tint.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))

                    PointMark(
                        x: .value("Day", day.key),
                        y: .value("Value", value)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(day.key == highlighted ? 40 : 12)
                }
            } else {
                ForEach(trend.days) { day in
                    if let value = day.value {
                        BarMark(
                            x: .value("Day", day.key),
                            y: .value("Value", value)
                        )
                        .foregroundStyle(tint.opacity(day.key == highlighted ? 1 : 0.35))
                    }
                }
            }
        }
        // Every day of the fortnight holds a slot, so a missing day shows as a gap.
        .chartXScale(domain: trend.days.map(\.key))
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXSelection(value: $rawSelection)
        .onChange(of: rawSelection) { _, raw in
            if let raw { selectedKey = raw }
        }
        .accessibilityHidden(true)
    }

    private var yDomain: ClosedRange<Double> {
        switch style {
        case .bars:
            return 0...100
        case .deviation:
            let extent = max(abs(trend.lowest ?? 0), abs(trend.highest ?? 0), 0.3) * 1.15
            return -extent...extent
        case .line:
            guard let low = trend.lowest, let high = trend.highest else { return 0...1 }
            let padding = max((high - low) * 0.2, 1)
            return (low - padding)...(high + padding)
        }
    }
}
