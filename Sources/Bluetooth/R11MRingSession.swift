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
/// - The only command sent unprompted is a read-only identity query. A measurement command or
///   a history request is sent only after that query produced a CRC-valid reply, and only
///   when the user asks.
/// - Live values during a measurement are provisional. The ring's early values are a warm-up
///   (a steady, wrong figure) and it signals the end of a measurement separately, so a value
///   is emitted only when the ring reports that measurement complete, using the last live
///   value received before that event. A zero is never a measurement.
/// - Stored history is imported only when its transfer's length and CRC check out, and only
///   records with a plausible timestamp (see `YCBTHistory`). Nothing is ever deleted from the
///   ring.
/// - A write that CoreBluetooth completed is only a transport result. Acceptance is the
///   protocol acknowledgement, and success is a decoded, completed measurement.
///
/// Heart rate, blood oxygen, and blood pressure can be measured on request. Blood pressure
/// from a finger's optical sensor is a vendor model, not a cuff measurement, so it is stored
/// as an estimate; so is the ring's temperature, which is a vendor-adjusted finger reading
/// rather than a body-temperature measurement (`provenance(for:)`).
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

    // MARK: Measurements

    /// What the user can ask the ring to measure.
    enum Measurement: String, CaseIterable, Hashable, Sendable {
        case heartRate
        case bloodOxygen
        case bloodPressure

        var sensor: YCBTFrameCodec.Sensor {
            switch self {
            case .heartRate:     .heartRate
            case .bloodOxygen:   .bloodOxygen
            case .bloodPressure: .bloodPressure
            }
        }

        /// Lower-case, for use inside sentences.
        var title: String {
            switch self {
            case .heartRate:     "heart rate"
            case .bloodOxygen:   "blood oxygen"
            case .bloodPressure: "blood pressure"
            }
        }

        /// Sentence case, for the Measure menu.
        var menuTitle: String {
            switch self {
            case .heartRate:     "Heart rate"
            case .bloodOxygen:   "Blood oxygen"
            case .bloodPressure: "Blood pressure (estimate)"
            }
        }

        var systemImage: String {
            switch self {
            case .heartRate:     "heart.text.square"
            case .bloodOxygen:   "lungs"
            case .bloodPressure: "gauge.with.dots.needle.33percent"
            }
        }
    }

    /// One completed or provisional value from a live measurement.
    enum RingValue: Equatable, Hashable, Sendable {
        case heartRate(bpm: Int)
        case bloodOxygen(percent: Int)
        case bloodPressure(systolic: Int, diastolic: Int)

        var measurement: Measurement {
            switch self {
            case .heartRate:     .heartRate
            case .bloodOxygen:   .bloodOxygen
            case .bloodPressure: .bloodPressure
            }
        }

        /// The metrics this value is stored as. Blood pressure is always a pair.
        var metrics: [(kind: MetricKind, value: Double)] {
            switch self {
            case .heartRate(let bpm):
                [(kind: .heartRate, value: Double(bpm))]
            case .bloodOxygen(let percent):
                [(kind: .spo2, value: Double(percent))]
            case .bloodPressure(let systolic, let diastolic):
                [
                    (kind: .bloodPressureSystolic, value: Double(systolic)),
                    (kind: .bloodPressureDiastolic, value: Double(diastolic)),
                ]
            }
        }

        var text: String {
            switch self {
            case .heartRate(let bpm):                  "\(bpm) BPM"
            case .bloodOxygen(let percent):            "\(percent)% SpO\u{2082}"
            case .bloodPressure(let systolic, let diastolic): "\(systolic)/\(diastolic) mmHg (estimate)"
            }
        }

        /// A live frame's value, or nil for a warm-up placeholder or an implausible figure.
        static func validated(_ candidate: Self) -> Self? {
            let usable = candidate.metrics.allSatisfy { $0.value > 0 && $0.kind.plausibleRange.contains($0.value) }
            guard usable else { return nil }
            if case .bloodPressure(let systolic, let diastolic) = candidate, systolic <= diastolic { return nil }
            return candidate
        }
    }

    /// How HeartSync labels a value from this ring. Heart rate, SpO2, and respiratory rate
    /// are the ring's own sensor readings, stored as measured like any vendor-reported value.
    /// Cuffless blood pressure is a vendor model of a finger's optical signal, and the ring's
    /// temperature is a vendor-adjusted finger reading presented as body temperature, so both
    /// are estimates: they stay out of device agreement by default and are never written to
    /// Apple Health.
    static func provenance(for kind: MetricKind) -> Provenance {
        switch kind {
        case .bloodPressureSystolic, .bloodPressureDiastolic, .bodyTemperature:
            .estimated
        case .heartRate, .restingHeartRate, .hrvSDNN, .hrvRMSSD, .spo2, .respiratoryRate, .vo2Max:
            .measured
        }
    }

    // MARK: State

    struct HistorySummary: Equatable, Sendable {
        var imported = 0
        var skipped = 0
        /// Types whose transfer failed its length or CRC check, or stopped answering.
        var failed: [YCBTHistory.Kind] = []
    }

    enum Outcome: Equatable, Sendable {
        /// A completed measurement. `measuredAt` is the receipt time of the last live value.
        case measured(RingValue, measuredAt: Date)
        /// The ring finished and said the sensor had no contact.
        case noContact
        /// The ring finished successfully without ever sending a usable value.
        case finishedWithoutValue
        /// The ring answered the start request with a non-zero status.
        case requestRejected(status: UInt8)
        /// A command could not be written.
        case writeFailed(String)
        /// No completion within the acquisition budget. `livePackets` separates silence from
        /// a ring that sent values but never finished.
        case timedOut(livePackets: Int)
        /// The ring finished with a result code HeartSync does not recognize.
        case unrecognizedResult(UInt8)
        case cancelled
        case historyImported(HistorySummary)
    }

    /// Progress through a history import: one type at a time, in `YCBTHistory.Kind` order.
    struct HistoryProgress: Equatable, Sendable {
        var current: YCBTHistory.Kind
        var remaining: [YCBTHistory.Kind]
        var buffer: [UInt8] = []
        /// More bytes arrived than `YCBTHistory.maximumTransferBytes`; the type is not decoded.
        var overflowed = false
        /// The first reply for the current type; the per-type cap runs from here.
        var firstReplyAt: Date?
        var summary = HistorySummary()
    }

    enum Phase: Equatable, Sendable {
        case awaitingSubscriptions(pending: Set<Channel>)
        case subscriptionFailed(Channel, String)
        case identifying
        /// The ring never produced a valid identity reply. Measurement stays unavailable.
        case unidentified(String)
        /// Identified and idle. `last` is the previous operation's outcome, if any.
        case ready(last: Outcome?)
        case starting(Measurement)
        case measuring(Measurement, provisional: RingValue?)
        case importingHistory(HistoryProgress)
    }

    enum Timeout: Equatable, Sendable {
        case identification
        case acquisition
        /// No history frame for `historyInactivityTimeout`.
        case history
    }

    enum Purpose: Equatable, Sendable {
        case identify
        case start(Measurement)
        case stop(Measurement)
        case historyRequest(YCBTHistory.Kind)
        case historyAcknowledgement

        /// Diagnostic wording.
        var rawValue: String {
            switch self {
            case .identify:               "Identity query"
            case .start(let measurement): "Start \(measurement.title) measurement"
            case .stop(let measurement):  "Stop \(measurement.title) measurement"
            case .historyRequest(let kind): "Request stored \(kind.title) history"
            case .historyAcknowledgement: "Acknowledge history transfer"
            }
        }
    }

    enum Action: Equatable, Sendable {
        case write(Data, purpose: Purpose)
        /// Ask the owner to call `timeoutElapsed(_:token:)` after `seconds`. A newer request
        /// increments the token, which is how stale timers are ignored.
        case scheduleTimeout(Timeout, seconds: TimeInterval, token: Int)
        /// A completed live measurement, to be stored under this ring's Bluetooth source.
        case emit(RingValue, measuredAt: Date)
        /// Records from the ring's memory whose transfer checked out.
        case emitHistory([YCBTHistory.Sample])
    }

    static let identificationTimeout: TimeInterval = 10
    /// The referenced ring finishes a spot heart rate in about 35 seconds. Ninety leaves room
    /// for a slow optical lock without leaving the user waiting indefinitely.
    static let defaultAcquisitionTimeout: TimeInterval = 90
    /// Re-armed on every history frame; the reference implementation uses the same figure.
    static let historyInactivityTimeout: TimeInterval = 10
    /// A single history type that keeps streaming past this is abandoned, so a misbehaving
    /// peripheral cannot hold the session in an import indefinitely.
    static let historyTypeCap: TimeInterval = 120

    let writeWithResponse: Bool
    var acquisitionTimeout: TimeInterval
    /// The zone the ring's wall clock is read in. The vendor app sets that clock from the
    /// phone's local time.
    var historyTimeZone: TimeZone
    private(set) var phase: Phase = .awaitingSubscriptions(pending: Set(Channel.allCases))
    private(set) var token = 0
    /// Live frames of the running measurement's kind, placeholders included.
    private(set) var livePackets = 0
    private var lastLiveValue: RingValue?
    private var lastLiveAt: Date?

    init(
        writeWithResponse: Bool,
        acquisitionTimeout: TimeInterval = Self.defaultAcquisitionTimeout,
        historyTimeZone: TimeZone = .current
    ) {
        self.writeWithResponse = writeWithResponse
        self.acquisitionTimeout = acquisitionTimeout
        self.historyTimeZone = historyTimeZone
    }

    /// True once the ring has answered the identity query. Only then does it own heart rate
    /// for this peripheral.
    var isIdentified: Bool {
        switch phase {
        case .ready, .starting, .measuring, .importingHistory: true
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

    /// Whether a measurement or a history import can start now.
    var canStartMeasurement: Bool {
        if case .ready = phase { return true }
        return false
    }

    var activeMeasurement: Measurement? {
        switch phase {
        case .starting(let measurement), .measuring(let measurement, _): measurement
        default: nil
        }
    }

    var isMeasuring: Bool { activeMeasurement != nil }

    var isImportingHistory: Bool {
        if case .importingHistory = phase { return true }
        return false
    }

    /// A measurement or an import is running; the Cancel control applies to either.
    var isBusy: Bool { isMeasuring || isImportingHistory }

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

    /// The user asked for one measurement.
    mutating func start(_ measurement: Measurement) -> [Action] {
        guard canStartMeasurement else { return [] }
        phase = .starting(measurement)
        token += 1
        livePackets = 0
        lastLiveValue = nil
        lastLiveAt = nil
        return [
            .write(YCBTFrameCodec.measurementRequest(start: true, sensor: measurement.sensor), purpose: .start(measurement)),
            .scheduleTimeout(.acquisition, seconds: acquisitionTimeout, token: token),
        ]
    }

    mutating func startHeartRate() -> [Action] {
        start(.heartRate)
    }

    /// The user asked to import the ring's stored readings. Read-only: nothing on the ring is
    /// changed or deleted.
    mutating func importHistory() -> [Action] {
        guard canStartMeasurement, let first = YCBTHistory.Kind.allCases.first else { return [] }
        phase = .importingHistory(HistoryProgress(
            current: first,
            remaining: Array(YCBTHistory.Kind.allCases.dropFirst())
        ))
        return requestHistoryActions(first)
    }

    /// Stops an in-flight measurement or import, for example when the user cancels or pauses
    /// the source. Values an import already emitted stay stored; they were complete.
    mutating func cancel() -> [Action] {
        if let measurement = activeMeasurement {
            token += 1
            phase = .ready(last: .cancelled)
            return [.write(YCBTFrameCodec.measurementRequest(start: false, sensor: measurement.sensor), purpose: .stop(measurement))]
        }
        if case .importingHistory = phase {
            token += 1
            phase = .ready(last: .cancelled)
        }
        return []
    }

    mutating func writeFinished(_ purpose: Purpose, error: String?) -> [Action] {
        guard let error else { return [] }
        switch (purpose, phase) {
        case (.identify, .identifying):
            token += 1
            phase = .unidentified("The identity query could not be written: \(error)")
        case (.start(let measurement), _) where activeMeasurement == measurement:
            token += 1
            phase = .ready(last: .writeFailed(error))
        case (.historyRequest, .importingHistory):
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
        case (.acquisition, .starting(let measurement)), (.acquisition, .measuring(let measurement, _)):
            self.token += 1
            phase = .ready(last: .timedOut(livePackets: livePackets))
            return [.write(YCBTFrameCodec.measurementRequest(start: false, sensor: measurement.sensor), purpose: .stop(measurement))]
        case (.history, .importingHistory(var progress)):
            progress.summary.failed.append(progress.current)
            return advanceHistory(progress)
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
            guard case .starting(let measurement) = phase else { return [] }
            if status == 0 {
                phase = .measuring(measurement, provisional: nil)
            } else {
                token += 1
                phase = .ready(last: .requestRejected(status: status))
            }
            return []

        case .liveHeartRate(let bpm):
            return receivedLive(.heartRate(bpm: bpm), at: date)
        case .liveSpO2(let percent):
            return receivedLive(.bloodOxygen(percent: percent), at: date)
        case .liveBloodPressure(let systolic, let diastolic):
            return receivedLive(.bloodPressure(systolic: systolic, diastolic: diastolic), at: date)

        case .measurementFinished(let sensor, let result):
            guard let measurement = activeMeasurement, sensor == measurement.sensor.rawValue else { return [] }
            token += 1
            switch result {
            case 0x01:
                guard let value = lastLiveValue, let at = lastLiveAt else {
                    phase = .ready(last: .finishedWithoutValue)
                    return []
                }
                phase = .ready(last: .measured(value, measuredAt: at))
                return [.emit(value, measuredAt: at)]
            case 0x02:
                phase = .ready(last: .noContact)
            default:
                phase = .ready(last: .unrecognizedResult(result))
            }
            return []

        case .historyHeader(let kind, let announcedBytes):
            guard case .importingHistory(let progress) = phase, progress.current == kind else { return [] }
            guard announcedBytes != nil else { return advanceHistory(progress) }
            return rearmHistory(progress, at: date)

        case .historyData(let kind, let payload):
            guard case .importingHistory(var progress) = phase, progress.current == kind else { return [] }
            if progress.buffer.count + payload.count > YCBTHistory.maximumTransferBytes {
                progress.overflowed = true
            } else {
                progress.buffer += payload
            }
            return rearmHistory(progress, at: date)

        case .historyBlockEnd(let end):
            guard case .importingHistory(var progress) = phase else { return [] }
            let accepted = !progress.overflowed && YCBTHistory.verify(progress.buffer, against: end)
            var actions: [Action] = [
                .write(YCBTHistory.blockAcknowledgement(accepted: accepted), purpose: .historyAcknowledgement),
            ]
            if accepted {
                let decoded = YCBTHistory.decode(progress.current, records: progress.buffer, timeZone: historyTimeZone, now: date)
                progress.summary.imported += decoded.samples.count
                progress.summary.skipped += decoded.skipped
                if !decoded.samples.isEmpty { actions.append(.emitHistory(decoded.samples)) }
            } else {
                progress.summary.failed.append(progress.current)
            }
            return actions + advanceHistory(progress)

        case .other, .truncated:
            return []
        }
    }

    // MARK: Helpers

    private mutating func receivedLive(_ candidate: RingValue, at date: Date) -> [Action] {
        guard let measurement = activeMeasurement, candidate.measurement == measurement else { return [] }
        livePackets += 1
        // A live value before the acknowledgement still means the ring accepted.
        guard let value = RingValue.validated(candidate) else {
            if case .starting = phase { phase = .measuring(measurement, provisional: nil) }
            return []
        }
        lastLiveValue = value
        lastLiveAt = date
        phase = .measuring(measurement, provisional: value)
        return []
    }

    private mutating func requestHistoryActions(_ kind: YCBTHistory.Kind) -> [Action] {
        token += 1
        return [
            .write(YCBTHistory.request(kind), purpose: .historyRequest(kind)),
            .scheduleTimeout(.history, seconds: Self.historyInactivityTimeout, token: token),
        ]
    }

    /// Keeps the import alive after a frame of the current type, unless that type has run
    /// past its cap.
    private mutating func rearmHistory(_ progress: HistoryProgress, at date: Date) -> [Action] {
        var progress = progress
        let firstReply = progress.firstReplyAt ?? date
        progress.firstReplyAt = firstReply
        guard date.timeIntervalSince(firstReply) <= Self.historyTypeCap else {
            progress.summary.failed.append(progress.current)
            return advanceHistory(progress)
        }
        phase = .importingHistory(progress)
        token += 1
        return [.scheduleTimeout(.history, seconds: Self.historyInactivityTimeout, token: token)]
    }

    private mutating func advanceHistory(_ progress: HistoryProgress) -> [Action] {
        var progress = progress
        guard !progress.remaining.isEmpty else {
            token += 1
            phase = .ready(last: .historyImported(progress.summary))
            return []
        }
        progress.current = progress.remaining.removeFirst()
        progress.buffer = []
        progress.overflowed = false
        progress.firstReplyAt = nil
        phase = .importingHistory(progress)
        return requestHistoryActions(progress.current)
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
            case .measured(let value, let date):
                "Last measured \(value.text) at \(date.formatted(date: .omitted, time: .shortened))."
            case .noContact:
                "The ring reported no finger contact. Adjust the ring and measure again."
            case .finishedWithoutValue:
                "The ring finished without sending a value."
            case .requestRejected(let status):
                "Ring rejected the measurement request (status \(String(format: "%02X", status)))."
            case .writeFailed(let error):
                "The request could not be sent: \(error)"
            case .timedOut(let packets):
                packets == 0
                    ? "No measurement packets received after starting measurement."
                    : "The ring sent \(packets) live value\(packets == 1 ? "" : "s") but never finished the measurement."
            case .unrecognizedResult(let result):
                "The ring finished with an unrecognized result (\(String(format: "%02X", result)))."
            case .cancelled:
                "Cancelled."
            case .historyImported(let summary):
                Self.historyText(summary)
            }
        case .starting(let measurement):
            "Starting \(measurement.title) measurement\u{2026}"
        case .measuring(let measurement, let value):
            if let value {
                "Measuring\u{2026} \(value.text) so far (not saved until the ring finishes)"
            } else {
                "Measuring \(measurement.title)\u{2026} keep the ring still on your finger."
            }
        case .importingHistory(let progress):
            "Reading the ring's stored \(progress.current.title)\u{2026}"
        }
    }

    /// Short enough for the one-line device row: counts first, details only when they
    /// change what the user should do.
    private static func historyText(_ summary: HistorySummary) -> String {
        var parts = [summary.imported == 0
            ? "The ring had no stored readings to import."
            // Counted before the store drops ones already imported, so "read", not "added".
            : "Read \(summary.imported) stored value\(summary.imported == 1 ? "" : "s")."]
        if summary.skipped > 0 {
            parts.append("\(summary.skipped) skipped (old, future, or clock not set).")
        }
        if !summary.failed.isEmpty {
            parts.append("Not read: \(summary.failed.map(\.title).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
