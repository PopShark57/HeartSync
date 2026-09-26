import SwiftUI

/// The most recent detailed sleep document: totals, efficiency, and the five-minute stage
/// ribbon Oura publishes.
///
/// The ribbon renders Oura's own stage classification. HeartSync does not stage sleep itself
/// and must not present these bands as an independent measurement.
struct OuraSleepSection: View {
    var sleep: OuraClient.SleepDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Sleep",
                subtitle: "Stages and overnight recovery",
                systemImage: "bed.double.fill"
            )

            VStack(alignment: .leading, spacing: 16) {
                if let sleep {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(OuraFormat.durationText(sleep.total_sleep_duration) ?? "—")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("total sleep · \(OuraFormat.dayLabel(sleep.day))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let efficiency = sleep.efficiency {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(efficiency)%")
                                    .font(.title2.bold().monospacedDigit())
                                Text("efficiency")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let phases = sleep.sleep_phase_5_min, !phases.isEmpty {
                        OuraCategoricalRibbon(
                            values: Array(phases),
                            colors: Self.stageColors,
                            fallback: .gray.opacity(0.25),
                            patterned: Self.patternedCodes,
                            accessibilityText: "Sleep-stage timeline with \(phases.count) five-minute intervals"
                        )
                        .frame(height: 28)

                        OuraRibbonLegend(
                            items: OuraSleepStage.allCases.map { ($0.title, $0.fill.color) },
                            patterned: Set(OuraSleepStage.allCases.filter(\.isPatterned).map(\.title))
                        )
                    }

                    LazyVGrid(columns: OuraCardLayout.metricColumns, alignment: .leading, spacing: 12) {
                        OuraMiniStat(title: "Deep", value: OuraFormat.durationText(sleep.deep_sleep_duration) ?? "—")
                        OuraMiniStat(title: "REM", value: OuraFormat.durationText(sleep.rem_sleep_duration) ?? "—")
                        OuraMiniStat(title: "Light", value: OuraFormat.durationText(sleep.light_sleep_duration) ?? "—")
                        OuraMiniStat(title: "Awake", value: OuraFormat.durationText(sleep.awake_time) ?? "—")
                        OuraMiniStat(title: "Time in bed", value: OuraFormat.durationText(sleep.time_in_bed) ?? "—")
                        OuraMiniStat(title: "Latency", value: OuraFormat.durationText(sleep.latency) ?? "—")
                        OuraMiniStat(title: "Restless periods", value: sleep.restless_periods.map(String.init) ?? "—")
                        OuraMiniStat(title: "Bedtime", value: OuraFormat.bedtimeText(sleep.bedtime_start))
                    }
                } else {
                    OuraInlineEmptyState(icon: "moon.zzz", text: "No detailed sleep record is available yet.")
                }
            }
            .ouraCard()
        }
    }

    /// Keyed by Oura's `sleep_phase_5_min` codes: a lightness ramp that follows depth, so
    /// deep is darkest and awake palest. See `OuraSleepStage`.
    private static let stageColors: [Character: Color] = Dictionary(
        uniqueKeysWithValues: OuraSleepStage.allCases.map { ($0.code, $0.fill.color) }
    )

    /// Awake is hatched as well as coloured, so it never depends on colour alone.
    private static let patternedCodes: Set<Character> = Set(
        OuraSleepStage.allCases.filter(\.isPatterned).map(\.code)
    )
}
