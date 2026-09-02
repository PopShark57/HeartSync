import SwiftUI

/// "Today's signals": the five headline scores Oura has computed, each labelled with the day
/// it belongs to.
///
/// Takes the already-selected latest documents rather than `AppModel` so the section can be
/// previewed and reasoned about on its own. A score Oura has not produced renders as `—`; an
/// absent score is never filled in from another collection.
struct OuraScoresSection: View {
    var activity: OuraClient.DailyActivity?
    var readiness: OuraClient.DailyReadiness?
    var sleepScore: OuraClient.DailySleep?
    var resilience: OuraClient.DailyResilience?
    var stress: OuraClient.DailyStress?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Today's signals",
                subtitle: "Oura scores and recovery context",
                systemImage: "sparkles"
            )

            LazyVGrid(columns: OuraCardLayout.cardColumns, spacing: 12) {
                OuraScoreCard(
                    title: "Activity",
                    value: activity?.score.map(String.init) ?? "—",
                    progress: activity?.score.map { Double($0) / 100 },
                    detail: OuraFormat.dayLabel(activity?.day),
                    icon: "figure.walk",
                    tint: .orange
                )
                OuraScoreCard(
                    title: "Readiness",
                    value: readiness?.score.map(String.init) ?? "—",
                    progress: readiness?.score.map { Double($0) / 100 },
                    detail: OuraFormat.dayLabel(readiness?.day),
                    icon: "bolt.heart.fill",
                    tint: .green
                )
                OuraScoreCard(
                    title: "Sleep",
                    value: sleepScore?.score.map(String.init) ?? "—",
                    progress: sleepScore?.score.map { Double($0) / 100 },
                    detail: OuraFormat.dayLabel(sleepScore?.day),
                    icon: "moon.stars.fill",
                    tint: .indigo
                )
                OuraScoreCard(
                    title: "Resilience",
                    value: OuraFormat.pretty(resilience?.level) ?? "—",
                    progress: OuraFormat.resilienceProgress(resilience?.level),
                    detail: OuraFormat.dayLabel(resilience?.day),
                    icon: "shield.lefthalf.filled",
                    tint: .purple
                )
                OuraScoreCard(
                    title: "Stress",
                    value: OuraFormat.pretty(stress?.day_summary) ?? "—",
                    progress: nil,
                    detail: stressDetail,
                    icon: "brain.head.profile",
                    tint: .pink
                )
            }
        }
    }

    private var stressDetail: String {
        guard let stress else { return "No daily summary" }
        let stressTime = OuraFormat.durationText(stress.stress_high)
        let recoveryTime = OuraFormat.durationText(stress.recovery_high)
        if let stressTime, let recoveryTime { return "\(stressTime) stress · \(recoveryTime) recovery" }
        return OuraFormat.dayLabel(stress.day)
    }
}
