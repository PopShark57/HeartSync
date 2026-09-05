import Foundation

/// Transient state only; no raw samples or duplicate health archive are stored here.
enum WorkoutPhase: Equatable, Sendable {
    case idle, authorizing, starting, running, paused, stopping, review, saving, saved, failed

    var canStart: Bool { self == .idle || self == .saved || self == .failed }
    var isCollecting: Bool { self == .running || self == .paused }
    var isBusy: Bool { [.authorizing, .starting, .stopping, .saving].contains(self) }
}

struct WorkoutHeartRate: Equatable, Sendable {
    var value: Double
    var timestamp: Date

    static func validated(value: Double, timestamp: Date, now: Date) -> Self? {
        guard value.isFinite, MetricKind.heartRate.plausibleRange.contains(value),
              timestamp.timeIntervalSince1970.isFinite,
              timestamp <= now.addingTimeInterval(60) else { return nil }
        return Self(value: value, timestamp: timestamp)
    }

    func isCurrent(at now: Date) -> Bool {
        now.timeIntervalSince(timestamp) <= 15
    }
}
