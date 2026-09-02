import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Now", systemImage: "heart.fill") {
                DashboardView()
            }
            Tab("Oura", systemImage: "circle.circle.fill") {
                OuraDashboardView()
            }
            Tab("Compare", systemImage: "chart.xyaxis.line") {
                CompareView()
            }
            Tab("Devices", systemImage: "dot.radiowaves.left.and.right") {
                DevicesView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tint(HeartSyncTheme.accent)
    }
}

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
}
