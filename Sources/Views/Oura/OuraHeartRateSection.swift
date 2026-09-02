import Charts
import SwiftUI

/// The last 24 hours of heart-rate samples present in the Oura cache.
///
/// This is Oura's processed cloud series, not a live sensor stream: the window is measured
/// back from the newest cached sample, so the footer says "Last 24 hours in cache" rather
/// than implying the chart is current.
struct OuraHeartRateSection: View {
    var heartRates: [OuraClient.HeartRatePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Heart rate",
                subtitle: "Recent Oura cloud samples",
                systemImage: "chart.xyaxis.line"
            )

            VStack(alignment: .leading, spacing: 12) {
                if heartChartPoints.isEmpty {
                    OuraInlineEmptyState(icon: "heart.slash", text: "No heart-rate samples in the current Oura cache.")
                } else {
                    Chart(heartChartPoints) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Baseline", heartChartFloor),
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

                    HStack {
                        if let low = heartChartPoints.map(\.bpm).min(),
                           let high = heartChartPoints.map(\.bpm).max() {
                            Label("\(Int(low))–\(Int(high)) bpm", systemImage: "arrow.up.arrow.down")
                        }
                        Spacer()
                        Text("Last 24 hours in cache")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .ouraCard()
        }
    }

    /// Samples whose timestamp Oura could not supply in a parseable form are dropped rather
    /// than plotted at a guessed time.
    private var heartChartPoints: [HeartChartPoint] {
        let all = heartRates.compactMap { point -> HeartChartPoint? in
            guard let date = OuraClient.parseTimestamp(point.timestamp) else { return nil }
            return HeartChartPoint(id: "\(point.timestamp)-\(point.bpm)", date: date, bpm: Double(point.bpm))
        }
        .sorted { $0.date < $1.date }
        guard let newest = all.last?.date else { return [] }
        let cutoff = newest.addingTimeInterval(-86_400)
        return all.filter { $0.date >= cutoff }
    }

    private var heartChartFloor: Double {
        max(0, (heartChartPoints.map(\.bpm).min() ?? 40) - 8)
    }
}

private struct HeartChartPoint: Identifiable {
    var id: String
    var date: Date
    var bpm: Double
}
