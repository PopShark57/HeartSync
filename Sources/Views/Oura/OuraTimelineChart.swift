import Charts
import SwiftUI

/// Oura's five-minute classifications on a clock: one rectangle per run, one row per stage
/// or class (improvement 35). The hypnogram and the movement chart are both this chart.
///
/// Drag across it to read a run, such as "REM · 02:10–02:35 · 25m". The selection stays
/// after the finger lifts; touching an unclassified gap clears it. Each run is also its own
/// VoiceOver element that names the stage or class and its times, so the chart can be read
/// without seeing it. The row a run sits on says which stage it is, so no stage depends on
/// colour alone.
struct OuraTimelineChart<Category: Hashable & Sendable>: View {
    let timeline: OuraCategoryTimeline<Category>
    /// Rows from top to bottom.
    let rows: [Category]
    let title: (Category) -> String
    let color: (Category) -> Color
    /// Hours between axis labels.
    let hourStride: Int
    /// The chart as a whole, for VoiceOver.
    let summary: String

    /// Raw value from `chartXSelection`: set while a finger is down, nil once it lifts.
    @State private var rawSelection: Date?
    @State private var selectedRunID: Int?

    var body: some View {
        let selected = timeline.runs.first { $0.id == selectedRunID }

        Chart {
            ForEach(timeline.runs) { run in
                RectangleMark(
                    xStart: .value("Start", run.start),
                    xEnd: .value("End", run.end),
                    y: .value("Class", title(run.category))
                )
                .foregroundStyle(color(run.category))
                .opacity(selected == nil || selected?.id == run.id ? 1 : 0.5)
                .accessibilityLabel(title(run.category))
                .accessibilityValue(timeText(run))
            }

            if let selected {
                RuleMark(x: .value("Selected", selected.start.addingTimeInterval(selected.duration / 2)))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
                    .lineStyle(HeartSyncTheme.Chart.selection)
                    .accessibilityHidden(true)
                    .annotation(
                        position: .top,
                        spacing: 2,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(selected.category))
                                .font(.caption2.weight(.semibold))
                            Text(timeText(selected))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                        .padding(6)
                        .foregroundStyle(.primary)
                        .background(HeartSyncTheme.Chart.calloutBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    }
            }
        }
        .chartXScale(domain: timeline.start...timeline.end)
        .chartYScale(domain: rows.map(title))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $rawSelection)
        .onChange(of: rawSelection) { _, raw in
            // The finger lifting keeps the run; a touch in an unclassified gap clears it.
            guard let raw else { return }
            selectedRunID = timeline.run(at: raw)?.id
        }
        .onChange(of: timeline.start) {
            selectedRunID = nil
        }
        .sensoryFeedback(.selection, trigger: selectedRunID) { _, new in new != nil }
        .accessibilityLabel(summary)
    }

    /// "02:10–02:35 · 25m"
    private func timeText(_ run: OuraCategoryTimeline<Category>.Run) -> String {
        let start = run.start.formatted(date: .omitted, time: .shortened)
        let end = run.end.formatted(date: .omitted, time: .shortened)
        let length = OuraFormat.durationText(Int(run.duration)) ?? ""
        return "\(start)\u{2013}\(end) · \(length)"
    }
}
