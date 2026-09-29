import Foundation

/// What the watch sends a mirrored workout session on iPhone (improvement 72).
///
/// Apple Watch starts a workout, mirrors it to the paired iPhone
/// (`HKWorkoutSession.startMirroringToCompanionDevice`), and sends one of these with each
/// heart-rate update through `sendToRemoteWorkoutSession(data:)`. iPhone shows it beside a
/// chest strap on Now, and that is all it does with it.
///
/// **Display only.** A mirrored value is never stored, compared, exported, or written to
/// Health. The workout's own heart-rate samples reach iPhone the usual way, through the
/// HealthKit import after Apple Watch syncs, with their HealthKit UUIDs; a second copy from
/// here would duplicate them under an identity HealthKit never issued.
///
/// Versioned and bounded like `WatchSnapshot`, and validated on arrival: a value outside the
/// metric's plausible range, or a timestamp far from now, is dropped rather than shown.
struct MirroredWorkoutPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumBytes = 1_024
    /// Heart rate older than this is shown as not live, as the watch's own workout screen
    /// does (`WorkoutHeartRate`).
    static let liveWindow: TimeInterval = 15

    var version: Int = Self.currentVersion
    var heartRate: Double?
    /// When the watch measured `heartRate`, not when it was sent.
    var measuredAt: Date?
    var isPaused: Bool
    /// The workout's activity, for the card's title only.
    var activityTitle: String?

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Mirrored workout payload too large"))
        }
        return data
    }

    /// The payload, or nil when it is too large, from a newer version, or implausible.
    static func decoded(_ data: Data, now: Date = .now) -> MirroredWorkoutPayload? {
        guard data.count <= maximumBytes,
              var payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.version == currentVersion
        else { return nil }
        if let heartRate = payload.heartRate {
            let plausible = heartRate.isFinite && MetricKind.heartRate.plausibleRange.contains(heartRate)
            let dated = payload.measuredAt.map { abs($0.timeIntervalSince(now)) < 3_600 } ?? false
            if !plausible || !dated {
                payload.heartRate = nil
                payload.measuredAt = nil
            }
        }
        payload.activityTitle = payload.activityTitle.map { String($0.prefix(60)) }
        return payload
    }

    /// Whether `heartRate` is recent enough to be called live at `now`.
    func isLive(at now: Date) -> Bool {
        guard heartRate != nil, let measuredAt, !isPaused else { return false }
        return now.timeIntervalSince(measuredAt) <= Self.liveWindow
    }
}
