import SwiftUI

/// The most recent daily activity summary and Oura's processed movement ribbon.
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

                    if let classes = activity.class_5_min, !classes.isEmpty {
                        OuraCategoricalRibbon(
                            values: Array(classes),
                            colors: movementColors,
                            fallback: .gray.opacity(0.2),
                            accessibilityText: "Processed daily movement timeline with \(classes.count) five-minute intervals"
                        )
                        .frame(height: 28)

                        OuraRibbonLegend(items: [
                            ("Rest", movementColors["1"]!),
                            ("Inactive", movementColors["2"]!),
                            ("Low", movementColors["3"]!),
                            ("Medium", movementColors["4"]!),
                            ("High", movementColors["5"]!),
                        ])
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

    /// Keys are Oura's `class_5_min` codes. The legend force-unwraps `"1"`–`"5"`, so those
    /// five keys must stay present.
    private var movementColors: [Character: Color] {
        [
            "0": .gray.opacity(0.22),
            "1": .indigo.opacity(0.45),
            "2": .blue.opacity(0.50),
            "3": .teal.opacity(0.72),
            "4": .green,
            "5": .orange,
        ]
    }
}
