import Foundation

/// Selectable spans used by the comparison and history views.
enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1H"
    case sixHours = "6H"
    case day = "24H"
    case week = "7D"
    case month = "30D"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .hour:     3_600
        case .sixHours: 21_600
        case .day:      86_400
        case .week:     604_800
        case .month:    2_592_000
        }
    }

    var interval: DateInterval {
        DateInterval(start: .now.addingTimeInterval(-duration), end: .now)
    }

    /// Bucket size for charts at this zoom, chosen so a range never renders more than a
    /// few hundred points \u{2014} otherwise a week of 1 Hz strap data melts the chart.
    var chartBucket: TimeInterval {
        switch self {
        case .hour:     60
        case .sixHours: 300
        case .day:      900
        case .week:     3_600
        case .month:    21_600
        }
    }

    var title: String {
        switch self {
        case .hour:     "Last hour"
        case .sixHours: "Last 6 hours"
        case .day:      "Last 24 hours"
        case .week:     "Last 7 days"
        case .month:    "Last 30 days"
        }
    }

    /// The shortest preset at least `duration` long, or the widest preset.
    ///
    /// A saved session's span is arbitrary; this picks the zoom level whose chart bucket and
    /// axis labels suit it, so a one-hour walk is drawn like the 1H preset rather than with
    /// the six-hour buckets of a month.
    static func fitting(duration: TimeInterval) -> TimeRange {
        allCases.first { $0.duration >= duration } ?? .month
    }

    /// The next longer span, or nil at the widest. Screens that tell the user to widen the
    /// range use this to offer the action directly rather than only describing it.
    var wider: TimeRange? {
        switch self {
        case .hour:     .sixHours
        case .sixHours: .day
        case .day:      .week
        case .week:     .month
        case .month:    nil
        }
    }
}
