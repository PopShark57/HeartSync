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

/// The last five minutes of a workout's heart rate, for the small trend on the watch.
///
/// Memory only and bounded: it holds samples the workout builder already delivered, never
/// writes them anywhere, and forgets them when a workout starts or is discarded. Health
/// remains the only store of workout samples. A pause or a silent sensor leaves a gap,
/// and the trend breaks there rather than drawing through it.
struct WorkoutHeartRateTrend: Equatable, Sendable {
    static let window: TimeInterval = 5 * 60
    /// Samples further apart than this are drawn as separate runs.
    static let gapThreshold: TimeInterval = 30
    static let maximumSamples = 600

    struct Point: Equatable, Sendable, Identifiable {
        var date: Date
        var bpm: Double
        /// Run number; it advances at every gap longer than `gapThreshold`.
        var segment: Int

        var id: Date { date }
    }

    private(set) var samples: [WorkoutHeartRate] = []

    /// Adds a sample unless it repeats or precedes the newest one. The builder reports its
    /// most recent quantity on every statistics update, so repeats are normal.
    mutating func append(_ sample: WorkoutHeartRate) {
        if let last = samples.last, sample.timestamp <= last.timestamp { return }
        samples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-Self.window)
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    mutating func reset() {
        samples.removeAll()
    }

    /// Samples within the window ending at `now`, with their gap segments.
    func points(at now: Date) -> [Point] {
        let cutoff = now.addingTimeInterval(-Self.window)
        var segment = 0
        var previous: Date?
        return samples.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.map { sample in
            if let previous, sample.timestamp.timeIntervalSince(previous) > Self.gapThreshold {
                segment += 1
            }
            previous = sample.timestamp
            return Point(date: sample.timestamp, bpm: sample.value, segment: segment)
        }
    }
}
