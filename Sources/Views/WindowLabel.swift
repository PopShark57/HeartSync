import Foundation

/// Wording for the epoch-aligned comparison grid.
///
/// The Now card and the metric-detail chart both name bucket lengths to the user, and a
/// window called "1-minute" on one screen must not be called "60-second" on the other, so
/// the phrasing lives in one place.
enum WindowLabel {

    /// Length of a comparison or chart bucket, e.g. `"1-minute"`, `"24-hour"`.
    static func length(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))-hour" }
        return "\(max(1, Int(seconds / 60)))-minute"
    }

    /// Coarse elapsed time, e.g. `"12 min"`, used inside sentences that explain why two
    /// readings were not compared. Deliberately vague: the exact age is already on the row.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let elapsed = max(0, seconds)
        if elapsed < 60    { return "\(Int(elapsed.rounded())) sec" }
        if elapsed < 3_600 { return "\(Int((elapsed / 60).rounded())) min" }
        if elapsed < 86_400 { return "\(Int((elapsed / 3_600).rounded())) hr" }
        return "\(Int((elapsed / 86_400).rounded())) days"
    }
}
