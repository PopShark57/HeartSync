import Foundation

/// Lookups the interactive charts run while a finger is on them.
///
/// Swift Charts re-evaluates a chart on every touch-move of a selection, so nothing here may
/// read the store or scan every mark. The snapshots sort what they need once, when they
/// load, and these searches answer each move in O(log n).
///
/// The screen-distance rules exist so a touch in empty plot area can mean "nothing": a
/// selection snaps to a plotted window only when one is drawn close enough to the finger,
/// and a touch farther from every window than that clears the selection instead of
/// jumping to a window hours away.
enum ChartLookup {

    /// Half of Apple's 44 × 44 pt minimum hit target: a touch this close to a drawn point
    /// selects it. Farther than this, the touch is in empty plot area.
    static let selectionRadius: Double = 22

    /// Index of the value nearest `target` in an ascending array; the earlier on a tie,
    /// matching `min(by:)` over the same list.
    static func nearestIndex(in sorted: [Double], to target: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(sorted[low - 1] - target) <= abs(sorted[low] - target) {
            return low - 1
        }
        return low
    }

    /// Index of the last value at or before `target` in an ascending array, or nil when
    /// every value is after it.
    static func lastIndex(atOrBefore target: Double, in sorted: [Double]) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= target { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The nearest value within `tolerance` of `target`, or nil when the nearest one is
    /// farther away than that. A nil tolerance accepts the nearest value however far it is.
    static func nearestIndex(in sorted: [Double], to target: Double, within tolerance: Double?) -> Int? {
        guard let index = nearestIndex(in: sorted, to: target) else { return nil }
        if let tolerance, abs(sorted[index] - target) > tolerance { return nil }
        return index
    }

    /// The span of time `points` of screen width cover on a date axis `plotWidth` wide.
    ///
    /// Used to turn the on-screen selection radius into seconds for a chart whose
    /// selection arrives as a date. Nil while the chart has not been measured yet, so the
    /// caller falls back to plain nearest-window snapping rather than refusing everything.
    static func timeTolerance(points: Double, plotWidth: Double, domain: ClosedRange<Date>) -> TimeInterval? {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard plotWidth > 0, span > 0, points > 0 else { return nil }
        return span * points / plotWidth
    }

    /// Index of the position nearest `target` in both x and y, if it lies within `radius`.
    ///
    /// Two-dimensional on purpose. A Bland–Altman plot exists to show outliers, and
    /// outliers often share a paired mean with the dense cluster: a lookup on the
    /// horizontal axis alone could never select them apart from it. Positions that could
    /// not be placed on screen are nil and never selected. Ties go to the earlier index.
    static func nearestIndex(to target: CGPoint, in positions: [CGPoint?], within radius: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, position) in positions.enumerated() {
            guard let position else { continue }
            let distance = hypot(Double(position.x - target.x), Double(position.y - target.y))
            guard distance <= radius else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }
}
