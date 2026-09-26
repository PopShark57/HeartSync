import SwiftUI

/// The most recent detailed sleep document: totals, efficiency, and a hypnogram of the
/// five-minute stages Oura publishes.
///
/// The hypnogram renders Oura's own stage classification on a clock, from `bedtime_start`
/// in five-minute steps, with Awake on top and Deep at the bottom. HeartSync does not stage
/// sleep itself and must not present these bands as an independent measurement. A document
/// without a bedtime keeps the untimed ribbon, because its stages cannot be placed in time.
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

                    if let hypnogram = OuraCategoryTimeline<OuraSleepStage>(sleep: sleep) {
                        OuraTimelineChart(
                            timeline: hypnogram,
                            rows: OuraSleepStage.allCases.sorted { $0.depth < $1.depth },
                            title: { $0.title },
                            color: { $0.fill.color },
                            hourStride: 2,
                            summary: hypnogramSummary(hypnogram)
                        )
                        .heartSyncChartHeight(HeartSyncTheme.Chart.ouraHypnogramHeight)
                        .accessibilityIdentifier("oura.hypnogram")

                        Text("Oura's stage classification, not HeartSync's. Drag across the chart to read a stage and its times.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let phases = sleep.sleep_phase_5_min, !phases.isEmpty {
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

    /// The night as VoiceOver reads the chart as a whole; each run is its own element too.
    private func hypnogramSummary(_ hypnogram: OuraCategoryTimeline<OuraSleepStage>) -> String {
        let start = hypnogram.start.formatted(date: .omitted, time: .shortened)
        let end = hypnogram.end.formatted(date: .omitted, time: .shortened)
        let totals = OuraSleepStage.allCases
            .sorted { $0.depth > $1.depth }
            .compactMap { stage -> String? in
                let seconds = hypnogram.duration(of: stage)
                guard seconds > 0, let text = OuraFormat.durationText(Int(seconds)) else { return nil }
                return "\(stage.title) \(text)"
            }
        return "Sleep stages as Oura classified them, from \(start) to \(end): \(totals.joined(separator: ", "))"
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
