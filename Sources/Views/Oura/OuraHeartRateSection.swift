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
                    chart(series)
                    footer(series)
                }
            }
            .ouraCard()
        }
    }

    private func chart(_ series: OuraHeartRateSeries) -> some View {
        Chart(series.points) { point in
            AreaMark(
                x: .value("Time", point.date),
                yStart: .value("Baseline", series.floor),
                yEnd: .value("Heart rate", point.bpm)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [.pink.opacity(0.24), .pink.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Time", point.date),
                y: .value("Heart rate", point.bpm)
            )
            .foregroundStyle(.pink)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: 210)
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
    }
}
