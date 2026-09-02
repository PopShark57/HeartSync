import SwiftUI

/// Supporting types for `MetricDetailView` (snapshot, chart points, rows).
/// Kept alongside the view so the metric-detail chart fix stays a small surface area.

// MARK: - Snapshot

struct ChartPoint: Identifiable {
    var id: String
    var date: Date
    var value: Double
    var sourceName: String
    var isEstimate: Bool
}

struct BandPoint: Identifiable {
    var id: String
    var date: Date
    var value: Double
    var low: Double
    var high: Double
    var severity: DiscrepancySeverity
}
