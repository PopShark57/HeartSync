import Foundation

/// Direct-Bluetooth session for a ring that exposes the YCBT vendor service (sold, among other
/// names, as R11M). Pure state machine: `BluetoothManager` feeds it CoreBluetooth outcomes and
/// performs the `Action`s it returns, so every transition is testable without a radio.
///
/// The session exists because such a ring can accept a standard Heart Rate subscription and
/// still never measure: its optical sensor runs on request, through a vendor command. The rules
/// below follow `RingFix.md`:
///
/// - The adapter is chosen from GATT topology (service plus both characteristics with usable
///   properties), never from the advertised name.
/// - No command is written until both vendor channels have confirmed their subscription.
/// - The only command sent unprompted is a read-only identity query. A measurement command is
///   sent only after that query produced a CRC-valid reply, and only when the user asks.
/// - Live values during a measurement are provisional. The ring's early values are a warm-up
///   (a steady, wrong figure) and it signals the end of a measurement separately, so a heart
///   rate is emitted only when the ring reports the measurement complete, using the last live
///   value received before that event. A zero is never a heart rate.
/// - A write that CoreBluetooth completed is only a transport result. Acceptance is the
///   protocol acknowledgement, and success is a decoded, completed measurement.
///
/// SpO2 frames are recognized for diagnostics only. Their start procedure has not been
/// verified for this ring, so HeartSync neither requests nor stores them.
struct R11MRingSession: Equatable, Sendable {

    // MARK: Identity

    static let serviceUUID = "BE940000-7333-BE46-B7AE-689E71722BD5"
    static let commandCharacteristicUUID = "BE940001-7333-BE46-B7AE-689E71722BD5"
    static let eventCharacteristicUUID = "BE940003-7333-BE46-B7AE-689E71722BD5"

    /// The two vendor channels. Replies can arrive on either.
    enum Channel: String, CaseIterable, Hashable, Sendable {
        /// Command writes and their replies.
        case command
        /// Ring-initiated measurement events.
        case events
    }

    /// The characteristic properties the adapter depends on, as plain flags so topology
    /// matching needs no CoreBluetooth objects.
    struct Traits: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let write = Traits(rawValue: 1 << 0)
        static let writeWithoutResponse = Traits(rawValue: 1 << 1)
        static let notify = Traits(rawValue: 1 << 2)
        static let indicate = Traits(rawValue: 1 << 3)
        static let read = Traits(rawValue: 1 << 4)

        var canSubscribe: Bool { !isDisjoint(with: [.notify, .indicate]) }
        var canWrite: Bool { !isDisjoint(with: [.write, .writeWithoutResponse]) }
    }

    enum TopologyMatch: Equatable, Sendable {
        /// Both channels exist with usable properties. `writeWithResponse` is preferred when
        /// the command characteristic offers it, so the transport result is observable.
        case matched(writeWithResponse: Bool)
        case notMatched(reason: String)
    }

    /// Chooses the adapter from what the ring exposes after discovery.
    ///
    /// - Parameter services: service UUID to (characteristic UUID to traits). UUIDs compare
    ///   case-insensitively.
    static func match(services: [String: [String: Traits]]) -> TopologyMatch {
        let normalized = Dictionary(
            services.map { ($0.key.uppercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let characteristics = normalized[serviceUUID] else {
            return .notMatched(reason: "No YCBT vendor service")
        }
        let byID = Dictionary(
            characteristics.map { ($0.key.uppercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let command = byID[commandCharacteristicUUID] else {
            return .notMatched(reason: "Vendor service without its command characteristic")
        }
        guard let events = byID[eventCharacteristicUUID] else {
            return .notMatched(reason: "Vendor service without its event characteristic")
        }
        guard command.canWrite else {
            return .notMatched(reason: "Vendor command characteristic is not writable")
        }
        guard command.canSubscribe, events.canSubscribe else {
            return .notMatched(reason: "A vendor channel cannot notify or indicate")
        }
        return .matched(writeWithResponse: command.contains(.write))
    }

    // MARK: State

    enum Outcome: Equatable, Sendable {
        /// A completed measurement. `measuredAt` is the receipt time of the last live value.
        case measured(bpm: Int, measuredAt: Date)
        /// The ring finished and said the sensor had no contact.
        case noContact
        /// The ring finished successfully without ever sending a usable value.
        case finishedWithoutValue
        /// The ring answered the start request with a non-zero status.
        case requestRejected(status: UInt8)
        /// The start command could not be written.
        case writeFailed(String)
        /// No completion within the acquisition budget. `livePackets` separates silence from
        /// a ring that sent values but never finished.
        case timedOut(livePackets: Int)
        /// The ring finished with a result code HeartSync does not recognize.
        case unrecognizedResult(UInt8)
        case cancelled
    }

    enum Phase: Equatable, Sendable {
        case awaitingSubscriptions(pending: Set<Channel>)
        case subscriptionFailed(Channel, String)
        case identifying
        /// The ring never produced a valid identity reply. Measurement stays unavailable.
        case unidentified(String)
        /// Identified and idle. `last` is the previous measurement's outcome, if any.
        case ready(last: Outcome?)
        case starting
        case measuring(provisionalBPM: Int?)
    }

    enum Timeout: Equatable, Sendable {
        case identification
        case acquisition
    }

    enum Purpose: String, Equatable, Sendable {
        case identify = "Identity query"
        case startHeartRate = "Start heart-rate measurement"
        case stopHeartRate = "Stop heart-rate measurement"
    }

    enum Action: Equatable, Sendable {
        case write(Data, purpose: Purpose)
        /// Ask the owner to call `timeoutElapsed(_:token:)` after `seconds`. A newer request
        /// increments the token, which is how stale timers are ignored.
        case scheduleTimeout(Timeout, seconds: TimeInterval, token: Int)
        case emitHeartRate(bpm: Int, measuredAt: Date)
    }

    static let identificationTimeout: TimeInterval = 10
    /// The referenced ring finishes a spot heart rate in about 35 seconds. Ninety leaves room
    /// for a slow optical lock without leaving the user waiting indefinitely.
    static let defaultAcquisitionTimeout: TimeInterval = 90

    let writeWithResponse: Bool
    var acquisitionTimeout: TimeInterval
    private(set) var phase: Phase = .awaitingSubscriptions(pending: Set(Channel.allCases))
    private(set) var token = 0
    /// Live heart-rate frames in the current measurement, zeros included.
    private(set) var livePackets = 0
    private var lastLive: (bpm: Int, at: Date)?

    init(
        writeWithResponse: Bool,
        acquisitionTimeout: TimeInterval = Self.defaultAcquisitionTimeout
    ) {
        self.writeWithResponse = writeWithResponse
        self.acquisitionTimeout = acquisitionTimeout
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.phase == rhs.phase && lhs.token == rhs.token && lhs.livePackets == rhs.livePackets
            && lhs.writeWithResponse == rhs.writeWithResponse
            && lhs.lastLive?.bpm == rhs.lastLive?.bpm && lhs.lastLive?.at == rhs.lastLive?.at
    }

    /// True once the ring has answered the identity query. Only then does it own heart rate
    /// for this peripheral.
    var isIdentified: Bool {
        switch phase {
        case .ready, .starting, .measuring: true
        default: false
        }
    }

    /// True while the vendor path is expected to deliver heart rate, so the standard `2A37`
    /// stream from the same ring is not ingested a second time. The references report that
    /// this ring re-notifies `2A37` on a housekeeping tick whether or not it measured, so a
    /// recent `2A37` value is not evidence of a fresh measurement. If identification fails the
    /// standard path is left untouched.
    var suppressesStandardHeartRate: Bool {
        switch phase {
        case .subscriptionFailed, .unidentified: false
        default: true
        }
    }

    var canStartMeasurement: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isMeasuring: Bool {
        switch phase {
        case .starting, .measuring: true
        default: false
        }
    }

    // MARK: Events

    /// A subscription result for one vendor channel. Identification starts only when both
    /// channels have confirmed, so no command can race a missing reply channel.
    mutating func subscriptionFinished(_ channel: Channel, error: String?) -> [Action] {
        guard case .awaitingSubscriptions(var pending) = phase else { return [] }
        if let error {
            phase = .subscriptionFailed(channel, error)
            return []
        }
        pending.remove(channel)
        guard pending.isEmpty else {
            phase = .awaitingSubscriptions(pending: pending)
            return []
        }
        phase = .identifying
        token += 1
        return [
            .write(YCBTFrameCodec.deviceInfoRequest(), purpose: .identify),
            .scheduleTimeout(.identification, seconds: Self.identificationTimeout, token: token),
        ]
    }

    /// The user asked for one heart-rate measurement.
    mutating func startHeartRate() -> [Action] {
        guard canStartMeasurement else { return [] }
        phase = .starting
        token += 1
        livePackets = 0
        lastLive = nil
        return [
            .write(YCBTFrameCodec.measurementRequest(start: true, sensor: .heartRate), purpose: .startHeartRate),
            .scheduleTimeout(.acquisition, seconds: acquisitionTimeout, token: token),
        ]
    }

    /// Stops an in-flight measurement, for example when the user cancels or pauses the source.
    mutating func cancel() -> [Action] {
        guard isMeasuring else { return [] }
        token += 1
        phase = .ready(last: .cancelled)
        return [.write(YCBTFrameCodec.measurementRequest(start: false, sensor: .heartRate), purpose: .stopHeartRate)]
    }

    mutating func writeFinished(_ purpose: Purpose, error: String?) -> [Action] {
        guard let error else { return [] }
        switch (purpose, phase) {
        case (.identify, .identifying):
            token += 1
            phase = .unidentified("The identity query could not be written: \(error)")
        case (.startHeartRate, .starting), (.startHeartRate, .measuring):
            token += 1
            phase = .ready(last: .writeFailed(error))
        default:
            break
        }
        return []
    }

    mutating func timeoutElapsed(_ timeout: Timeout, token: Int) -> [Action] {
        guard token == self.token else { return [] }
        switch (timeout, phase) {
        case (.identification, .identifying):
            self.token += 1
            phase = .unidentified("The ring did not answer HeartSync's identity query, so its protocol is not the one this adapter supports.")
            return []
        case (.acquisition, .starting), (.acquisition, .measuring):
            self.token += 1
            phase = .ready(last: .timedOut(livePackets: livePackets))
            return [.write(YCBTFrameCodec.measurementRequest(start: false, sensor: .heartRate), purpose: .stopHeartRate)]
        default:
            return []
        }
    }

    /// Handles one decoded vendor frame, from either channel.
    mutating func received(_ message: YCBTFrameCodec.Message, at date: Date) -> [Action] {
        switch message {
        case .deviceInfo:
            guard case .identifying = phase else { return [] }
            token += 1
            phase = .ready(last: nil)
            return []

        case .measurementAck(let status):
            guard case .starting = phase else { return [] }
            if status == 0 {
                phase = .measuring(provisionalBPM: nil)
            } else {
                token += 1
                phase = .ready(last: .requestRejected(status: status))
            }
            return []

        case .liveHeartRate(let bpm):
            guard isMeasuring else { return [] }
            livePackets += 1
            // A live value before the acknowledgement still means the ring accepted.
            guard bpm > 0, MetricKind.heartRate.plausibleRange.contains(Double(bpm)) else {
                if case .starting = phase { phase = .measuring(provisionalBPM: nil) }
                return []
            }
            lastLive = (bpm, date)
            phase = .measuring(provisionalBPM: bpm)
            return []

        case .measurementFinished(let sensor, let result):
            guard isMeasuring, sensor == YCBTFrameCodec.Sensor.heartRate.rawValue else { return [] }
            token += 1
            switch result {
            case 0x01:
                guard let lastLive else {
                    phase = .ready(last: .finishedWithoutValue)
                    return []
                }
                phase = .ready(last: .measured(bpm: lastLive.bpm, measuredAt: lastLive.at))
                return [.emitHeartRate(bpm: lastLive.bpm, measuredAt: lastLive.at)]
            case 0x02:
                phase = .ready(last: .noContact)
            default:
                phase = .ready(last: .unrecognizedResult(result))
            }
            return []

        case .liveSpO2, .other, .truncated:
            return []
        }
    }

    // MARK: Presentation

    /// One evidence-tied sentence for the device row. Nothing here claims poor contact unless
    /// the ring itself reported it.
    var statusText: String {
        switch phase {
        case .awaitingSubscriptions:
            "Connected; enabling the ring's measurement channels\u{2026}"
        case .subscriptionFailed(let channel, let error):
            "The ring's \(channel == .command ? "command" : "event") channel could not be enabled: \(error)"
        case .identifying:
            "Identifying the ring\u{2026}"
        case .unidentified(let reason):
            reason
        case .ready(let last):
            switch last {
            case nil:
                "Connected; waiting for ring measurement."
            case .measured(let bpm, let date):
                "Last measured \(bpm) BPM at \(date.formatted(date: .omitted, time: .shortened))."
            case .noContact:
                "The ring reported no finger contact. Adjust the ring and measure again."
            case .finishedWithoutValue:
                "The ring finished without sending a heart rate."
            case .requestRejected(let status):
                "Ring rejected the measurement request (status \(String(format: "%02X", status)))."
            case .writeFailed(let error):
                "The measurement request could not be sent: \(error)"
            case .timedOut(let packets):
                packets == 0
                    ? "No measurement packets received after starting measurement."
                    : "The ring sent \(packets) live value\(packets == 1 ? "" : "s") but never finished the measurement."
            case .unrecognizedResult(let result):
                "The ring finished with an unrecognized result (\(String(format: "%02X", result)))."
            case .cancelled:
                "Measurement cancelled."
            }
        case .starting:
            "Starting heart-rate measurement\u{2026}"
        case .measuring(let bpm):
            if let bpm {
                "Measuring\u{2026} \(bpm) BPM so far (not saved until the ring finishes)"
            } else {
                "Measuring\u{2026} keep the ring still on your finger."
            }
        }
    }
}
