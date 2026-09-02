import Foundation

/// Admission rules for values arriving from a live Bluetooth stream.
///
/// CoreBluetooth delivers callbacks on the main actor, so this small value type can be kept
/// beside the manager without a queue. It deliberately uses receipt time rather than a device
/// timestamp: a peripheral must not be able to bypass the cadence bound by changing its clock.
struct BluetoothReadingAdmission: Sendable {
    enum NotificationChannel: Hashable, Sendable {
        case heartRate
        case pulseOximeterSpO2
        case pulseOximeterPulse
        case temperature
        case battery
    }

    /// The fastest cadence HeartSync accepts for a live scalar metric. This still preserves an
    /// ordinary 1 Hz sensor stream, while preventing a burst of notifications from becoming an
    /// equally large burst of `Reading` values.
    static let minimumScalarInterval: TimeInterval = 0.5
    static let minimumNotificationInterval: TimeInterval = 0.5

    /// HRV values are already rate-limited by `HRVAccumulator`; keeping the same rule here
    /// protects the store if another caller ever emits a derived HRV value.
    static let minimumHRVInterval: TimeInterval = 60

    /// Battery level changes slowly and is metadata rather than a measurement stream. A
    /// separate cadence prevents battery notifications from bypassing reading admission and
    /// repeatedly scheduling persistence on the main actor.
    static let minimumBatteryInterval: TimeInterval = 30

    private struct Key: Hashable, Sendable {
        let sourceID: String
        let kind: MetricKind
    }

    private var lastAcceptedAt: [Key: Date] = [:]
    private struct NotificationKey: Hashable, Sendable {
        let sourceID: String
        let channel: NotificationChannel
    }
    private var lastNotificationAt: [NotificationKey: Date] = [:]

    /// Returns whether a value may be constructed and sent to the store.
    mutating func accept(sourceID: String, kind: MetricKind, receivedAt: Date) -> Bool {
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        let key = Key(sourceID: sourceID, kind: kind)
        let minimumInterval = Self.minimumInterval(for: kind)

        if let previous = lastAcceptedAt[key],
           receivedAt.timeIntervalSince(previous) < minimumInterval {
            return false
        }

        lastAcceptedAt[key] = receivedAt
        return true
    }

    mutating func reset(sourceID: String) {
        lastAcceptedAt = lastAcceptedAt.filter { $0.key.sourceID != sourceID }
        lastNotificationAt = lastNotificationAt.filter { $0.key.sourceID != sourceID }
    }

    /// Performs a per-channel admission check after the bounded measurement parser has accepted
    /// a frame and before a Reading or HRV accumulator can receive it. Keeping parsing first means
    /// malformed or out-of-window timestamps do not consume the slot for a following valid frame.
    mutating func acceptNotification(
        sourceID: String,
        channel: NotificationChannel,
        receivedAt: Date,
        minimumInterval: TimeInterval = Self.minimumNotificationInterval
    ) -> Bool {
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite,
              minimumInterval.isFinite
        else { return false }
        let key = NotificationKey(sourceID: sourceID, channel: channel)
        if let previous = lastNotificationAt[key],
           receivedAt.timeIntervalSince(previous) < max(0, minimumInterval) {
            return false
        }
        lastNotificationAt[key] = receivedAt
        return true
    }

    mutating func acceptBattery(sourceID: String, receivedAt: Date) -> Bool {
        acceptNotification(
            sourceID: sourceID,
            channel: .battery,
            receivedAt: receivedAt,
            minimumInterval: Self.minimumBatteryInterval
        )
    }

    static func minimumInterval(for kind: MetricKind) -> TimeInterval {
        switch kind {
        case .hrvSDNN, .hrvRMSSD:
            minimumHRVInterval
        default:
            minimumScalarInterval
        }
    }
}

/// Validates and normalises a timestamp supplied by a Bluetooth peripheral.
enum BluetoothTimestampPolicy {
    static let defaultMaximumAge: TimeInterval = 30 * 86_400

    /// A small amount of clock lead is common on consumer sensors. It is clamped to receipt time
    /// so even an accepted clock lead can never create a future reading or future HealthKit write.
    static let maximumFutureSkew: TimeInterval = 5 * 60

    /// The caller supplies the store's configured retention so a timestamp that would be thrown
    /// away immediately is rejected before it can affect ordering, source state, or write-back.
    static func normalized(
        deviceTimestamp: Date?,
        receivedAt: Date,
        maximumAge: TimeInterval
    ) -> Date? {
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        guard let deviceTimestamp else { return receivedAt }
        guard deviceTimestamp.timeIntervalSinceReferenceDate.isFinite else { return nil }

        let age = receivedAt.timeIntervalSince(deviceTimestamp)
        guard age <= max(0, maximumAge), age >= -maximumFutureSkew else { return nil }
        return min(deviceTimestamp, receivedAt)
    }
}
