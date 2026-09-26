import Foundation

/// Evidence about one Bluetooth connection: what the peripheral exposes, what arrived, and what
/// happened to each packet.
///
/// The point is to tell apart states that look identical on a device row: a characteristic
/// that is silent, one whose packets are all rejected, and a vendor ring that is waiting for a
/// command. Measurement packets are counted *before* any parser or admission guard, and every
/// rejection names its reason, so "no data" is never a guess.
///
/// Raw bytes are health data. They are captured only during an explicit, time-bounded
/// diagnostic session, held in memory, bounded in count, and leave the app only through the
/// user's own export. They are never logged.
struct BluetoothDiagnostics: Equatable, Sendable {

    enum Rejection: String, CaseIterable, Hashable, Sendable {
        case malformed
        case offBody
        case invalidQuality
        case invalidTimestamp
        case outOfRange
        case throttled
        case unknownCharacteristic
        /// A standard heart-rate frame from a ring whose vendor protocol owns heart rate.
        case supersededByRingProtocol
        case crcMismatch
        case invalidFrameLength
        /// A vendor value inside a measurement that has not finished; kept out of history.
        case provisional

        /// Wording for "Receiving packets; readings rejected: \u{2026}".
        var explanation: String {
            switch self {
            case .malformed: "packets could not be decoded"
            case .offBody: "sensor reports no contact"
            case .invalidQuality: "sensor reports the reading as invalid or unreliable"
            case .invalidTimestamp: "the device timestamp is outside the accepted window"
            case .outOfRange: "values are outside the plausible range"
            case .throttled: "values arrive faster than HeartSync stores them"
            case .unknownCharacteristic: "packets come from a characteristic HeartSync does not read"
            case .supersededByRingProtocol: "the ring's own measurement protocol supplies heart rate instead"
            case .crcMismatch: "ring frames failed their checksum"
            case .invalidFrameLength: "ring frames declared an impossible length"
            case .provisional: "the ring has not finished its measurement"
            }
        }
    }

    enum SubscriptionStatus: Equatable, Sendable {
        case notAttempted
        case pending
        case subscribed
        case failed(String)
    }

    struct CharacteristicRecord: Equatable, Sendable {
        var uuid: String
        var serviceUUID: String
        var properties: [String]
        var subscription: SubscriptionStatus = .notAttempted
        var packets = 0
        var bytes = 0
        var firstReceivedAt: Date?
        var lastReceivedAt: Date?
        var callbackErrors = 0
        var lastError: String?
    }

    enum CommandStage: Equatable, Sendable {
        case sent
        case written
        case writeFailed(String)
    }

    struct CommandRecord: Equatable, Sendable {
        var at: Date
        var purpose: String
        var bytes: Int
        var stage: CommandStage
    }

    struct MetricRecord: Equatable, Sendable {
        var firstAt: Date
        var firstValue: Double
        var lastAt: Date
        var lastValue: Double
        /// Values handed to ingestion. `onReading` returns nothing, so this is not a count of
        /// rows committed to the database.
        var forwarded: Int
    }

    struct RawPacket: Equatable, Sendable {
        var at: Date
        var characteristic: String
        var hex: String
    }

    /// Why a subscribed connection shows no accepted value.
    enum StallDiagnosis: Equatable, Sendable {
        /// Nothing arrived on any measurement characteristic.
        case noPackets
        /// Packets arrived and were all rejected, most recently for this reason.
        case packetsRejected(Rejection)
        /// Values were accepted earlier, then stopped.
        case streamStopped

        func message(seconds: Int) -> String {
            switch self {
            case .noPackets:
                "Connected and subscribed, but no measurement packets arrived in \(seconds) seconds. Some sensors only measure while worn or after being started."
            case .packetsRejected(let reason):
                "Receiving packets; readings rejected: \(reason.explanation)."
            case .streamStopped:
                "The measurement stream stopped for \(seconds) seconds. Check the sensor, then use Reconnect."
            }
        }
    }

    static let maximumRawPackets = 200
    static let maximumCommands = 50
    static let maximumErrors = 20
    static let diagnosticCaptureDuration: TimeInterval = 60

    let startedAt: Date
    /// Increments for each app-side connection to this peripheral.
    let connectionSession: Int
    /// True when this connection ran full discovery (`discoverServices(nil)`).
    var fullDiscovery: Bool
    /// Raw capture runs until this time, and only in a diagnostic session.
    var captureUntil: Date?
    var selectedAdapter = "Standard GATT profiles"
    var adapterNote: String?
    var deviceIdentity: String?
    var ringPhase: String?

    private(set) var characteristics: [String: CharacteristicRecord] = [:]
    private(set) var rejections: [Rejection: Int] = [:]
    private(set) var lastRejection: Rejection?
    private(set) var measurementPackets = 0
    private(set) var acceptedValues = 0
    private(set) var lastMeasurementPacketAt: Date?
    private(set) var lastValidMeasurementAt: Date?
    private(set) var commands: [CommandRecord] = []
    private(set) var metrics: [MetricKind: MetricRecord] = [:]
    private(set) var rawCapture: [RawPacket] = []
    private(set) var errors: [String] = []

    init(startedAt: Date, connectionSession: Int, fullDiscovery: Bool) {
        self.startedAt = startedAt
        self.connectionSession = connectionSession
        self.fullDiscovery = fullDiscovery
        if fullDiscovery {
            captureUntil = startedAt.addingTimeInterval(Self.diagnosticCaptureDuration)
        }
    }

    // MARK: Recording

    mutating func recordCharacteristic(key: String, uuid: String, serviceUUID: String, properties: [String]) {
        guard characteristics[key] == nil else { return }
        characteristics[key] = CharacteristicRecord(uuid: uuid, serviceUUID: serviceUUID, properties: properties)
    }

    mutating func recordSubscription(key: String, status: SubscriptionStatus) {
        characteristics[key]?.subscription = status
    }

    /// Counts a received value before any parsing. Battery and identity values are counted per
    /// characteristic but are not measurement packets.
    mutating func recordPacket(key: String, data: Data, at date: Date, isMeasurement: Bool) {
        if var record = characteristics[key] {
            record.packets += 1
            record.bytes += data.count
            if record.firstReceivedAt == nil { record.firstReceivedAt = date }
            record.lastReceivedAt = date
            characteristics[key] = record
        }
        if isMeasurement {
            measurementPackets += 1
            lastMeasurementPacketAt = date
        }
        if let captureUntil, date <= captureUntil, rawCapture.count < Self.maximumRawPackets {
            let uuid = characteristics[key]?.uuid ?? key
            rawCapture.append(RawPacket(
                at: date,
                characteristic: uuid,
                hex: data.map { String(format: "%02X", $0) }.joined(separator: " ")
            ))
        }
    }

    mutating func recordCallbackError(key: String?, _ description: String) {
        if let key, var record = characteristics[key] {
            record.callbackErrors += 1
            record.lastError = description
            characteristics[key] = record
        }
        appendError(description)
    }

    mutating func reject(_ reason: Rejection) {
        rejections[reason, default: 0] += 1
        // Packets from characteristics HeartSync does not read are not measurement
        // attempts, so they never become the explanation for a measurement stall.
        if reason != .unknownCharacteristic {
            lastRejection = reason
        }
    }

    mutating func accept(_ kind: MetricKind, value: Double, at date: Date) {
        acceptedValues += 1
        lastValidMeasurementAt = date
        if var record = metrics[kind] {
            record.lastAt = date
            record.lastValue = value
            record.forwarded += 1
            metrics[kind] = record
        } else {
            metrics[kind] = MetricRecord(firstAt: date, firstValue: value, lastAt: date, lastValue: value, forwarded: 1)
        }
    }

    mutating func recordCommand(purpose: String, bytes: Int, at date: Date) {
        commands.append(CommandRecord(at: date, purpose: purpose, bytes: bytes, stage: .sent))
        if commands.count > Self.maximumCommands {
            commands.removeFirst(commands.count - Self.maximumCommands)
        }
    }

    /// Marks the newest matching command's transport outcome. A written command is not an
    /// accepted one; acceptance appears as the ring's reply in the ring phase.
    mutating func recordWrite(purpose: String, error: String?) {
        guard let index = commands.lastIndex(where: { $0.purpose == purpose && $0.stage == .sent }) else { return }
        commands[index].stage = error.map(CommandStage.writeFailed) ?? .written
    }

    private mutating func appendError(_ description: String) {
        errors.append(description)
        if errors.count > Self.maximumErrors {
            errors.removeFirst(errors.count - Self.maximumErrors)
        }
    }

    // MARK: Reading

    /// Separates silence from rejection for a connection with no accepted value in the window.
    var stallDiagnosis: StallDiagnosis {
        if acceptedValues > 0 {
            if let lastRejection, let lastPacket = lastMeasurementPacketAt,
               let lastValid = lastValidMeasurementAt, lastPacket > lastValid {
                return .packetsRejected(lastRejection)
            }
            return .streamStopped
        }
        if measurementPackets == 0 { return .noPackets }
        return .packetsRejected(lastRejection ?? .malformed)
    }

    /// A plain-text report for the user's explicit export. Contains no credentials.
    func exportText(deviceName: String, generatedAt: Date = .now) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func time(_ date: Date?) -> String { date.map { iso.string(from: $0) } ?? "never" }

        var lines: [String] = [
            "HeartSync Bluetooth diagnostics",
            "Device: \(deviceName)",
            "Generated: \(time(generatedAt))",
            "Connection session: \(connectionSession), started \(time(startedAt))",
            "Discovery: \(fullDiscovery ? "full (all services)" : "targeted (supported services)")",
            "Adapter: \(selectedAdapter)",
        ]
        if let adapterNote { lines.append("Adapter note: \(adapterNote)") }
        if let deviceIdentity { lines.append("Device information: \(deviceIdentity)") }
        if let ringPhase { lines.append("Ring protocol: \(ringPhase)") }
        lines.append("")
        lines.append("Measurement packets received: \(measurementPackets); last \(time(lastMeasurementPacketAt))")
        lines.append("Values forwarded to storage: \(acceptedValues); last \(time(lastValidMeasurementAt))")
        if !rejections.isEmpty {
            lines.append("Rejections:")
            for reason in Rejection.allCases {
                if let count = rejections[reason] {
                    lines.append("  \(reason.rawValue): \(count) (\(reason.explanation))")
                }
            }
        }
        if !metrics.isEmpty {
            lines.append("Metrics forwarded:")
            for kind in MetricKind.allCases {
                guard let record = metrics[kind] else { continue }
                lines.append("  \(kind.rawValue): \(record.forwarded); first \(record.firstValue) at \(time(record.firstAt)); last \(record.lastValue) at \(time(record.lastAt))")
            }
        }
        lines.append("")
        lines.append("Characteristics:")
        for (_, record) in characteristics.sorted(by: { ($0.value.serviceUUID, $0.value.uuid) < ($1.value.serviceUUID, $1.value.uuid) }) {
            let subscription: String = switch record.subscription {
            case .notAttempted: "not subscribed"
            case .pending: "subscribing"
            case .subscribed: "subscribed"
            case .failed(let error): "subscription failed: \(error)"
            }
            lines.append("  service \(record.serviceUUID) characteristic \(record.uuid) [\(record.properties.joined(separator: ", "))] \(subscription); \(record.packets) packets, \(record.bytes) bytes, first \(time(record.firstReceivedAt)), last \(time(record.lastReceivedAt))\(record.callbackErrors > 0 ? ", \(record.callbackErrors) errors (last: \(record.lastError ?? ""))" : "")")
        }
        if !commands.isEmpty {
            lines.append("")
            lines.append("Commands:")
            for command in commands {
                let stage: String = switch command.stage {
                case .sent: "sent, awaiting transport result"
                case .written: "written (transport only; see ring protocol for acceptance)"
                case .writeFailed(let error): "write failed: \(error)"
                }
                lines.append("  \(time(command.at)) \(command.purpose), \(command.bytes) bytes: \(stage)")
            }
        }
        if !errors.isEmpty {
            lines.append("")
            lines.append("Callback errors:")
            lines.append(contentsOf: errors.map { "  \($0)" })
        }
        if !rawCapture.isEmpty {
            lines.append("")
            lines.append("Raw packets (first \(rawCapture.count), diagnostic session only):")
            for packet in rawCapture {
                lines.append("  \(time(packet.at)) \(packet.characteristic): \(packet.hex)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// How long a continuous stream may stay quiet before it is called stalled.
///
/// A fixed 30 seconds suits a 1 Hz strap but misdescribes a sensor that reports every minute.
/// The threshold therefore follows the stream's own observed cadence: four typical intervals,
/// never less than the initial acquisition budget and never more than ten minutes.
struct StreamCadence: Equatable, Sendable {
    static let initialAcquisitionBudget: TimeInterval = 30
    static let maximumThreshold: TimeInterval = 600
    static let retainedIntervals = 8

    private(set) var lastAcceptedAt: Date?
    private(set) var intervals: [TimeInterval] = []

    mutating func record(_ date: Date) {
        if let lastAcceptedAt {
            let interval = date.timeIntervalSince(lastAcceptedAt)
            if interval > 0 {
                intervals.append(interval)
                if intervals.count > Self.retainedIntervals {
                    intervals.removeFirst(intervals.count - Self.retainedIntervals)
                }
            }
        }
        lastAcceptedAt = date
    }

    var stallThreshold: TimeInterval {
        guard !intervals.isEmpty else { return Self.initialAcquisitionBudget }
        let sorted = intervals.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        return min(max(median * 4, Self.initialAcquisitionBudget), Self.maximumThreshold)
    }
}
