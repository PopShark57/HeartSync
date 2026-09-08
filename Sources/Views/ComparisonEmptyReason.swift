import Foundation

/// Why Compare has nothing to list. These are genuinely different situations and only two
/// of them are improved by widening the range, so they must not share one message.
enum ComparisonEmptyReason: Equatable, Sendable {
    /// No readings are stored at all: a new install, or history that was deleted.
    case noStoredData
    /// Readings exist, but none of them fall inside the selected range.
    case noDataInRange
    /// Exactly one source reported in this range, so no pair can exist.
    case singleSourceInRange
    /// Two or more sources reported, but no single metric was measured by two of them.
    case noSharedMetric

    /// Chooses the reason from facts the snapshot already resolved.
    ///
    /// Kept separate from the view so the distinction between "you have no data",
    /// "you have data but not here", and "you have one device" is unit-testable without
    /// rendering SwiftUI.
    ///
    /// - Parameters:
    ///   - comparableMetricCount: metrics measured by two or more sources in the range.
    ///   - sourcesInRange: distinct non-estimated sources reporting anything in the range.
    ///   - hasStoredReadings: whether the database holds any readings at all.
    static func resolve(
        comparableMetricCount: Int,
        sourcesInRange: Int,
        hasStoredReadings: Bool
    ) -> ComparisonEmptyReason {
        if comparableMetricCount > 0 { return .noSharedMetric }
        if sourcesInRange >= 2 { return .noSharedMetric }
        if sourcesInRange == 1 { return .singleSourceInRange }
        return hasStoredReadings ? .noDataInRange : .noStoredData
    }

    var systemImage: String {
        switch self {
        case .noStoredData:        "tray"
        case .noDataInRange:       "clock.arrow.circlepath"
        case .singleSourceInRange: "plus.circle"
        case .noSharedMetric:      "chart.xyaxis.line"
        }
    }

    var title: String {
        switch self {
        case .noStoredData:        "No measurements yet"
        case .noDataInRange:       "No measurements in this range"
        case .singleSourceInRange: "Only one device reported"
        case .noSharedMetric:      "No metric measured by two devices"
        }
    }

    /// Widening cannot conjure data that was never stored, and it cannot add a second
    /// device, so those two cases do not offer the action.
    var suggestsWidening: Bool {
        switch self {
        case .noStoredData:                             false
        case .noDataInRange, .singleSourceInRange, .noSharedMetric: true
        }
    }

    func message(range: TimeRange, wider: TimeRange?) -> String {
        let widerHint = wider.map { " Try \($0.title.lowercased())." } ?? ""
        switch self {
        case .noStoredData:
            return "Connect a device on the Devices tab, or allow Apple Health access in Settings. Comparison needs measured data from two or more devices for the same metric."
        case .noDataInRange:
            return "Measurements are stored, but none of them fall in \(range.title.lowercased()).\(widerHint)"
        case .singleSourceInRange:
            return "Only one device reported in \(range.title.lowercased()). Comparison needs two.\(widerHint)"
        case .noSharedMetric:
            return "Two or more devices reported in \(range.title.lowercased()), but no single metric was measured by two of them. Their timestamps do not need to overlap \u{2014} they do need to measure the same thing.\(widerHint)"
        }
    }
}
