import SwiftUI

/// A merged, newest-first list of the discrete events Oura reports: workouts, guided
/// sessions, tags, and rest-mode periods.
///
/// Entries whose start time cannot be parsed are dropped rather than placed at a guessed
/// moment, and the list is capped at `maximumRows` so one busy collection cannot crowd the
/// rest out.
struct OuraTimelineSection: View {
    var workouts: [OuraClient.Workout]
    var sessions: [OuraClient.SessionDocument]
    var enhancedTags: [OuraClient.EnhancedTagDocument]
    var tags: [OuraClient.TagDocument]
    var restModePeriods: [OuraClient.RestModePeriod]

    /// Presentation-only cap. It bounds the rendered rows, never the cached records.
    private let maximumRows = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Timeline",
                subtitle: "Workouts, sessions, tags, and rest mode",
                systemImage: "list.bullet.rectangle.portrait"
            )

            VStack(alignment: .leading, spacing: 0) {
                let items = timelineItems
                if items.isEmpty {
                    OuraInlineEmptyState(icon: "calendar.badge.clock", text: "No recent Oura events are available.")
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        OuraTimelineRow(item: item)
                        if index < items.count - 1 { Divider().padding(.leading, 42) }
                    }
                }
            }
            .ouraCard()
        }
    }

    private var timelineItems: [OuraTimelineItem] {
        var result: [OuraTimelineItem] = []

        result += workouts.compactMap { workout in
            guard let date = OuraClient.parseTimestamp(workout.start_datetime) else { return nil }
            let duration = OuraFormat.intervalDuration(start: workout.start_datetime, end: workout.end_datetime)
            let calories = workout.calories.map { " · \(Int($0.rounded())) kcal" } ?? ""
            return OuraTimelineItem(
                id: "workout-\(workout.id)",
                date: date,
                title: workout.label ?? OuraFormat.pretty(workout.activity) ?? "Workout",
                subtitle: "\(OuraFormat.pretty(workout.intensity) ?? "Workout")\(duration.map { " · \($0)" } ?? "")\(calories)",
                icon: "figure.run",
                tint: .orange
            )
        }

        result += sessions.compactMap { session in
            guard let date = OuraClient.parseTimestamp(session.start_datetime) else { return nil }
            let motion = session.motion_count?.items.compactMap { $0 }.count ?? 0
            let detail = [OuraFormat.pretty(session.mood), motion > 0 ? "\(motion) motion samples" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
            return OuraTimelineItem(
                id: "session-\(session.id)",
                date: date,
                title: OuraFormat.pretty(session.type) ?? "Session",
                subtitle: detail.isEmpty ? "Oura session" : detail,
                icon: "figure.mind.and.body",
                tint: .purple
            )
        }

        result += enhancedTags.compactMap { tag in
            guard let date = OuraClient.parseTimestamp(tag.start_time) else { return nil }
            let title = tag.custom_name ?? OuraFormat.pretty(tag.tag_type_code) ?? "Tag"
            return OuraTimelineItem(
                id: "enhanced-tag-\(tag.id)",
                date: date,
                title: title,
                subtitle: tag.comment ?? "Oura tag",
                icon: "tag.fill",
                tint: .blue
            )
        }

        result += tags.compactMap { tag in
            guard let date = OuraClient.parseTimestamp(tag.timestamp) else { return nil }
            let title = tag.tags.first.map(OuraFormat.pretty) ?? nil
            return OuraTimelineItem(
                id: "tag-\(tag.id)",
                date: date,
                title: title ?? "Tag",
                subtitle: tag.text ?? tag.tags.dropFirst().joined(separator: ", "),
                icon: "tag",
                tint: .blue
            )
        }

        result += restModePeriods.compactMap { period in
            let date = OuraClient.parseTimestamp(period.start_time) ?? OuraClient.parseDay(period.start_day)
            guard let date else { return nil }
            return OuraTimelineItem(
                id: "rest-\(period.id)",
                date: date,
                title: "Rest mode",
                subtitle: period.end_day.map { "Through \(OuraFormat.dayLabel($0))" } ?? "Currently recorded",
                icon: "bed.double.circle.fill",
                tint: .indigo
            )
        }

        return Array(result.sorted { $0.date > $1.date }.prefix(maximumRows))
    }
}
