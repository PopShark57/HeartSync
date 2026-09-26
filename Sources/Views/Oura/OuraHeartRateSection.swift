import Charts
import SwiftUI

/// The last 24 hours of heart-rate samples present in the Oura cache.
///
/// This is Oura's processed cloud series, not a live sensor stream: the window is measured
/// back from the newest cached sample, so the footer says "Last 24 hours in cache" rather
/// than implying the chart is current.
///
/// Every projection the card draws comes from one `OuraHeartRateSeries`, resolved once per
/// update. Deriving points inside computed properties instead put a full parse-and-sort of
/// the whole cached collection inside the `Chart` content closure, which Swift Charts runs
/// once per plotted sample — that is what froze the Oura tab, and why the derivation now
/// lives in a value the closure only reads stored properties from.
struct OuraHeartRateSection: View {
    var heartRates: [OuraClient.HeartRatePoint]

    var body: some View {
        let series = OuraHeartRateSeries(heartRates: heartRates)

        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Heart rate",
                subtitle: "Recent Oura cloud samples",
                systemImage: "chart.xyaxis.line"
            )

            VStack(alignment: .leading, spacing: 12) {
                if series.points.isEmpty {
                    OuraInlineEmptyState(icon: "heart.slash", text: "No heart-rate samples in the current Oura cache.")
                } else {
                    // Its own view: a scrub re-evaluates only the chart, never this body,
                    // so the cached samples are not re-parsed on every touch-move.
                    OuraHeartRateChart(series: series)
                        .accessibilityIdentifier("oura.heartRate")
                    footer(series)
                }
            }
            .ouraCard()
        }
    }

    /// The range comes from every sample in the window, not only the drawn ones, and the
    /// note says outright when the line is a subset. Drawing part of the window silently
    /// would misstate how much data is behind it.
    @ViewBuilder
    private func footer(_ series: OuraHeartRateSeries) -> some View {
        HStack {
            if let low = series.lowest, let high = series.highest {
                Label("\(low)–\(high) bpm", systemImage: "arrow.up.arrow.down")
            }
            Spacer()
            Text("Last 24 hours in cache")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if series.isThinned {
            Text("Showing \(series.points.count) of \(series.sampleCount) cached samples for legibility, including the lowest and the highest.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Text("Drag across the chart to read a sample's time and heart rate.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The Oura heart-rate line with a selectable sample (improvement 35).
///
/// A drag snaps to the nearest drawn sample and shows its time and bpm; the selection stays
/// after the finger lifts, and a touch in a gap the ring did not upload clears it. Every
/// value shown is one of Oura's own samples — nothing is interpolated for the callout.
struct OuraHeartRateChart: View {
    let series: OuraHeartRateSeries

    /// Raw value from `chartXSelection`: set while a finger is down, nil once it lifts.
    @State private var rawSelection: Date?
    @State private var selectedID: String?
    /// Measured width, which turns the on-screen selection radius into seconds.
    @State private var chartWidth: CGFloat = 0

    var body: some View {
        let selected = series.point(id: selectedID)

        Chart {
            ForEach(series.points) { point in
                // Monotone, not Catmull-Rom: Catmull-Rom curves overshoot and drew peaks and
                // dips no sample had, contradicting the series' own "invents no value"
                // contract. Keyed per segment so the line and its fill stop at a hole in the
                // series.
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Baseline", series.floor),
                    yEnd: .value("Heart rate", point.bpm),
                    series: .value("Segment", point.segment)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            HeartSyncTheme.Chart.heartRateInk.opacity(0.24),
                            HeartSyncTheme.Chart.heartRateInk.opacity(0.02),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
                // The fill repeats the line; VoiceOver reads each sample once, below.
                .accessibilityHidden(true)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Heart rate", point.bpm),
                    series: .value("Segment", point.segment)
                )
                .foregroundStyle(HeartSyncTheme.Chart.heartRateInk)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
                .accessibilityLabel(point.date.formatted(date: .omitted, time: .shortened))
                .accessibilityValue("\(Int(point.bpm.rounded())) bpm")

                // A sample alone between two holes has no line; the dot keeps it visible.
                if point.isIsolated {
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Heart rate", point.bpm)
                    )
                    .foregroundStyle(HeartSyncTheme.Chart.heartRateInk)
                    .symbolSize(24)
                    .accessibilityHidden(true)
                }
            }

            if let selected {
                RuleMark(x: .value("Selected sample", selected.date))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
                    .lineStyle(HeartSyncTheme.Chart.selection)
                    .accessibilityHidden(true)

                PointMark(
                    x: .value("Time", selected.date),
                    y: .value("Heart rate", selected.bpm)
                )
                .foregroundStyle(HeartSyncTheme.Chart.heartRateInk)
                .symbolSize(70)
                .accessibilityHidden(true)
                .annotation(
                    position: .top,
                    spacing: 6,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    Text("\(selected.date.formatted(date: .omitted, time: .shortened)) · \(Int(selected.bpm)) bpm")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
        }
        // Pinned to the stated "last 24 hours in cache", so an upload gap stays visible.
        .chartXScale(domain: series.domain ?? Date.now...Date.now)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartYAxisLabel("bpm")
        .accessibilityChartDescriptor(OuraHeartRateAudioGraph(points: series.points.map { ($0.date, $0.bpm) }))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartXSelection(value: $rawSelection)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            chartWidth = width
        }
        .onChange(of: rawSelection) { _, raw in
            // The finger lifting keeps the sample; a touch in a gap clears it.
            guard let raw, let domain = series.domain else { return }
            let tolerance = ChartLookup.timeTolerance(
                points: ChartLookup.selectionRadius,
                plotWidth: Double(chartWidth),
                domain: domain
            )
            selectedID = series.point(nearest: raw, within: tolerance)?.id
        }
        .sensoryFeedback(.selection, trigger: selectedID) { _, new in new != nil }
        .heartSyncChartHeight(HeartSyncTheme.Chart.ouraHeartRateHeight)
    }
}
