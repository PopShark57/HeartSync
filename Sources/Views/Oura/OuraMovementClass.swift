import Foundation

/// Oura's `class_5_min` activity classes, from non-wear to high activity.
///
/// One enum owns every code, its name, and its row on the movement chart, and the legend,
/// the chart's rows, and the colour map are all built from `allCases`. The legend used to
/// list five hand-picked entries while the colour map drew a sixth — code `"0"`, non-wear,
/// as unexplained grey — so a new or missing code could never again be drawn without being
/// named.
///
/// These are Oura's own processed classes, not HeartSync's, and not raw accelerometer data.
enum OuraMovementClass: CaseIterable, Sendable {
    case nonWear, rest, inactive, low, medium, high

    /// Oura's `class_5_min` code for this class.
    var code: Character {
        switch self {
        case .nonWear:  "0"
        case .rest:     "1"
        case .inactive: "2"
        case .low:      "3"
        case .medium:   "4"
        case .high:     "5"
        }
    }

    init?(code: Character) {
        guard let movement = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = movement
    }

    var title: String {
        switch self {
        case .nonWear:  "Non-wear"
        case .rest:     "Rest"
        case .inactive: "Inactive"
        case .low:      "Low"
        case .medium:   "Medium"
        case .high:     "High"
        }
    }

    /// 0 for non-wear, rising with activity. The chart stacks its rows by this, so the
    /// most active time sits highest and the ring being off the finger sits lowest.
    var level: Int {
        switch self {
        case .nonWear:  0
        case .rest:     1
        case .inactive: 2
        case .low:      3
        case .medium:   4
        case .high:     5
        }
    }
}
