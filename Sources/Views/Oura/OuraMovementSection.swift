import SwiftUI

/// The most recent daily activity summary and Oura's processed movement classes over the
/// activity day.
///
/// The classes are drawn on a clock from the day's own start (4 a.m. in the ring's zone),
/// one row per class from non-wear up to high. A cache written before HeartSync read that
/// start keeps the untimed ribbon until the next sync, rather than guessing a clock.
///
/// The closing note is a stated limitation, not decoration: Oura's public API exposes
/// classified movement, MET values, and session motion counts only. HeartSync cannot read the
/// ring's raw accelerometer stream, and this section must never imply that it can.
struct OuraMovementSection: View {
    var activity: OuraClient.DailyActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Movement & activity",
                subtitle: "Processed movement from the Oura cloud",
                systemImage: "figure.walk.motion"
            )

            VStack(alignment: .leading, spacing: 16) {
                if let activity {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.steps.formatted())
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("steps · \(OuraFormat.dayLabel(activity.day))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(activity.active_calories) kcal")
                                .font(.title3.bold().monospacedDigit())
                            Text("active energy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let movement = OuraCategoryTimeline<OuraMovementClass>(activity: activity) {
                        OuraTimelineChart(
                            timeline: movement,
                            rows: OuraMovementClass.allCases.sorted { $0.level > $1.level },
                            title: { $0.title },
                            color: { $0.color },
                            hourStride: 4,
                            summary: movementSummary(movement)
                        )
                        .frame(height: 150)
                        .accessibilityIdentifier("oura.movement")

                        Text("Oura's activity classes, not HeartSync's. Drag across the chart to read a class and its times.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let classes = activity.class_5_min, !classes.isEmpty {
                        OuraCategoricalRibbon(
                            values: Array(classes),
                            colors: Self.movementColors,
                            fallback: .gray.opacity(0.2),
                            accessibilityText: "Processed daily movement timeline with \(classes.count) five-minute intervals"
                        )
                        .frame(height: 28)

                        // Every class the colour map can draw, non-wear included.
                        OuraRibbonLegend(items: OuraMovementClass.allCases.map { ($0.title, $0.color) })
                    }

                    LazyVGrid(columns: OuraCardLayout.metricColumns, alignment: .leading, spacing: 12) {
                        OuraMiniStat(title: "Walking equivalent", value: OuraFormat.distanceText(activity.equivalent_walking_distance))
                        OuraMiniStat(title: "Active time", value: OuraFormat.durationText(activity.low_activity_time + activity.medium_activity_time + activity.high_activity_time) ?? "—")
                        OuraMiniStat(title: "Sedentary", value: OuraFormat.durationText(activity.sedentary_time) ?? "—")
                        OuraMiniStat(title: "Resting", value: OuraFormat.durationText(activity.resting_time) ?? "—")
                        OuraMiniStat(title: "Non-wear", value: OuraFormat.durationText(activity.non_wear_time) ?? "—")
                        OuraMiniStat(title: "Inactivity alerts", value: String(activity.inactivity_alerts))
                        OuraMiniStat(title: "Total energy", value: "\(activity.total_calories) kcal")
                        OuraMiniStat(title: "Average MET", value: activity.average_met_minutes.formatted(.number.precision(.fractionLength(1))))
                    }
                } else {
                    OuraInlineEmptyState(icon: "figure.walk", text: "No daily activity summary is available yet.")
                }

                Divider()

                Label("Movement ribbons use Oura's processed activity classes. HeartSync cannot access or display the ring's raw accelerometer stream.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .ouraCard()
        }
    }

    /// The day as VoiceOver reads the chart as a whole; each run is its own element too.
    private func movementSummary(_ movement: OuraCategoryTimeline<OuraMovementClass>) -> String {
        let start = movement.start.formatted(date: .omitted, time: .shortened)
        let end = movement.end.formatted(date: .omitted, time: .shortened)
        let totals = OuraMovementClass.allCases
            .sorted { $0.level > $1.level }
            .compactMap { movementClass -> String? in
                let seconds = movement.duration(of: movementClass)
                guard seconds > 0, let text = OuraFormat.durationText(Int(seconds)) else { return nil }
                return "\(movementClass.title) \(text)"
            }
        return "Activity classes as Oura classified them, from \(start) to \(end): \(totals.joined(separator: ", "))"
    }

    /// Keyed by Oura's `class_5_min` codes, and built from the same enum as the legend, so
    /// a code can never be drawn without being named.
    private static let movementColors: [Character: Color] = Dictionary(
        uniqueKeysWithValues: OuraMovementClass.allCases.map { ($0.code, $0.color) }
    )
}

extension OuraMovementClass {
    /// The class's colour on the chart, the ribbon, and the legend alike. The row a run
    /// sits on names its class as well, so no class depends on this colour alone.
    var color: Color {
        switch self {
        case .nonWear:  .gray.opacity(0.22)
        case .rest:     .indigo.opacity(0.45)
        case .inactive: .blue.opacity(0.50)
        case .low:      .teal.opacity(0.72)
        case .medium:   .green
        case .high:     .orange
        }
    }
}
