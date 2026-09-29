import Foundation

/// Decoded Heart Rate Measurement characteristic (0x2A37).
struct HeartRateMeasurement: Equatable, Sendable {
    var beatsPerMinute: Int
    /// `nil` when the sensor does not support contact detection at all. `false` means it
    /// supports detection and is telling us it is *not* in contact \u{2014} readings taken then
    /// should be discarded, not compared.
    var isSensorContactDetected: Bool?
    var energyExpendedJoules: Int?
    /// R\u{2013}R intervals in milliseconds, oldest first. Present only on sensors that expose
    /// beat-to-beat timing; this is what makes real HRV possible.
    var rrIntervalsMS: [Double]

    /// Parses the characteristic value.
    ///
    /// Layout, per the Bluetooth SIG spec:
    /// - byte 0: flags \u{2014} bit0 HR is uint16 (else uint8), bit1 contact detected,
    ///   bit2 contact supported, bit3 energy expended present, bit4 R\u{2013}R present
    /// - HR value (1 or 2 bytes)
    /// - energy expended, uint16 kJ, if bit3
    /// - remaining bytes: R\u{2013}R intervals, uint16 each, in units of 1/1024 s, if bit4
    init?(data: Data) {
        var reader = BinaryReader(data)
        guard let flags = reader.uint8() else { return nil }

        let isWide          = flags & 0x01 != 0
        let contactDetected = flags & 0x02 != 0
        let contactSupported = flags & 0x04 != 0
        let hasEnergy       = flags & 0x08 != 0
        let hasRR           = flags & 0x10 != 0

        let hr: Int
        if isWide {
            guard let value = reader.uint16() else { return nil }
            hr = Int(value)
        } else {
            guard let value = reader.uint8() else { return nil }
            hr = Int(value)
        }
        self.beatsPerMinute = hr
        self.isSensorContactDetected = contactSupported ? contactDetected : nil

        if hasEnergy {
            guard let kj = reader.uint16() else { return nil }
            // The spec's unit is kilojoules; store joules so downstream maths is unitful.
            self.energyExpendedJoules = Int(kj) * 1000
        } else {
            self.energyExpendedJoules = nil
        }

        var intervals: [Double] = []
        if hasRR {
            while reader.remaining >= 2, let raw = reader.uint16() {
                // Units are 1/1024 of a second, not milliseconds. Getting this conversion
                // wrong scales every HRV figure by ~2.4%, which is enough to fabricate a
                // discrepancy against a device that does it right.
                intervals.append(Double(raw) * 1000.0 / 1024.0)
            }
        }
        self.rrIntervalsMS = intervals
    }
}

/// Decoded PLX measurement, from either the continuous (0x2A5F) or spot-check (0x2A5E)
/// characteristic of the Pulse Oximeter Service.
struct PulseOximeterMeasurement: Equatable, Sendable {
    enum SampleType: Sendable {
        case continuous
        case spotCheck
    }

    enum Quality: Equatable, Sendable {
        case accepted
        case provisional([QualityReason])
        case questionable([QualityReason])
        case invalid([QualityReason])

        var reasons: [QualityReason] {
            switch self {
            case .accepted: []
            case .provisional(let reasons), .questionable(let reasons), .invalid(let reasons): reasons
            }
        }

        /// Only fully accepted frames enter history, comparisons, or HealthKit write-back.
        /// Provisional continuous frames remain useful as a live diagnostic but must mature
        /// before becoming durable evidence; one-shot provisional/questionable frames cannot.
        var isDurable: Bool { self == .accepted }

        var title: String {
            switch self {
            case .accepted: "Accepted"
            case .provisional: "Provisional"
            case .questionable: "Questionable"
            case .invalid: "Invalid"
            }
        }

        var storedQuality: MeasurementQuality? {
            switch self {
            case .accepted: .accepted
            case .provisional: .provisional
            case .questionable: .questionable
            case .invalid: nil
            }
        }
    }

    enum QualityReason: String, CaseIterable, Sendable {
        case measurementOngoing
        case earlyEstimatedData
        case dataFromStorage
        case demonstrationData
        case testingData
        case calibrationOngoing
        case measurementUnavailable
        case questionableMeasurement
        case invalidMeasurement
        case extendedDisplayUpdateOngoing
        case equipmentMalfunction
        case signalProcessingIrregularity
        case inadequateSignal
        case poorSignal
        case lowPerfusion
        case erraticSignal
        case nonPulsatileSignal
        case questionablePulse
        case signalAnalysisOngoing
        case sensorInterference
        case sensorUnconnectedFromUser
        case unknownSensorConnected
        case sensorDisplaced
        case sensorMalfunction
        case sensorDisconnected

        var title: String {
            switch self {
            case .measurementOngoing: String(localized: "plx.reason.measurementOngoing", defaultValue: "measurement ongoing", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .earlyEstimatedData: String(localized: "plx.reason.earlyEstimatedData", defaultValue: "early estimate", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .dataFromStorage: String(localized: "plx.reason.dataFromStorage", defaultValue: "stored historical data", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .demonstrationData: String(localized: "plx.reason.demonstrationData", defaultValue: "demonstration data", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .testingData: String(localized: "plx.reason.testingData", defaultValue: "testing data", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .calibrationOngoing: String(localized: "plx.reason.calibrationOngoing", defaultValue: "calibration ongoing", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .measurementUnavailable: String(localized: "plx.reason.measurementUnavailable", defaultValue: "measurement unavailable", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .questionableMeasurement: String(localized: "plx.reason.questionableMeasurement", defaultValue: "questionable measurement", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .invalidMeasurement: String(localized: "plx.reason.invalidMeasurement", defaultValue: "invalid measurement", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .extendedDisplayUpdateOngoing: String(localized: "plx.reason.extendedDisplayUpdateOngoing", defaultValue: "display update ongoing", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .equipmentMalfunction: String(localized: "plx.reason.equipmentMalfunction", defaultValue: "equipment malfunction", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .signalProcessingIrregularity: String(localized: "plx.reason.signalProcessingIrregularity", defaultValue: "signal processing irregularity", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .inadequateSignal: String(localized: "plx.reason.inadequateSignal", defaultValue: "inadequate signal", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .poorSignal: String(localized: "plx.reason.poorSignal", defaultValue: "poor signal", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .lowPerfusion: String(localized: "plx.reason.lowPerfusion", defaultValue: "low perfusion", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .erraticSignal: String(localized: "plx.reason.erraticSignal", defaultValue: "erratic signal", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .nonPulsatileSignal: String(localized: "plx.reason.nonPulsatileSignal", defaultValue: "non-pulsatile signal", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .questionablePulse: String(localized: "plx.reason.questionablePulse", defaultValue: "questionable pulse", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .signalAnalysisOngoing: String(localized: "plx.reason.signalAnalysisOngoing", defaultValue: "signal analysis ongoing", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .sensorInterference: String(localized: "plx.reason.sensorInterference", defaultValue: "sensor interference", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .sensorUnconnectedFromUser: String(localized: "plx.reason.sensorUnconnectedFromUser", defaultValue: "sensor not on user", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .unknownSensorConnected: String(localized: "plx.reason.unknownSensorConnected", defaultValue: "unknown sensor", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .sensorDisplaced: String(localized: "plx.reason.sensorDisplaced", defaultValue: "sensor displaced", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .sensorMalfunction: String(localized: "plx.reason.sensorMalfunction", defaultValue: "sensor malfunction", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            case .sensorDisconnected: String(localized: "plx.reason.sensorDisconnected", defaultValue: "sensor disconnected", comment: "Why a pulse-oximeter reading is doubtful or not saved (Bluetooth status flag)")
            }
        }
    }

    var spo2Percent: Double?
    var pulseRateBPM: Double?
    /// Perfusion strength, when reported. Low perfusion is the usual reason a finger-worn
    /// sensor disagrees with a chest strap, so it is worth keeping.
    var pulseAmplitudeIndex: Double?
    /// Device timestamp from a spot-check reading, when present.
    var timestamp: Date?
    var measurementStatus: UInt16?
    var deviceAndSensorStatus: UInt32?

    /// Interprets the independent PLX Measurement Status and Device and Sensor Status fields.
    /// Bit positions follow PLXS 1.0.1 Tables 3.4 and 3.5 exactly.
    func quality(for sampleType: SampleType) -> Quality {
        let measurement = measurementStatus ?? 0
        let device = deviceAndSensorStatus ?? 0

        let invalid = Self.reasons(in: measurement, masks: Self.invalidMeasurementMasks)
            + Self.reasons(in: device, masks: Self.invalidDeviceMasks)
        if !invalid.isEmpty { return .invalid(invalid) }

        let questionable = Self.reasons(in: measurement, masks: Self.questionableMeasurementMasks)
            + Self.reasons(in: device, masks: Self.questionableDeviceMasks)
        if !questionable.isEmpty { return .questionable(questionable) }

        let provisional = Self.reasons(in: measurement, masks: Self.provisionalMeasurementMasks)
            + Self.reasons(in: device, masks: Self.provisionalDeviceMasks)
        if !provisional.isEmpty {
            // Continuous frames can mature in a later notification; a spot-check cannot.
            // In both cases this individual early/calibrating/stored frame stays visible only
            // as a live caveat and never enters durable evidence.
            switch sampleType {
            case .continuous, .spotCheck:
                return .provisional(provisional)
            }
        }

        return .accepted
    }

    private static let provisionalMeasurementMasks: [(UInt16, QualityReason)] = [
        (1 << 5, .measurementOngoing),
        (1 << 6, .earlyEstimatedData),
        (1 << 9, .dataFromStorage),
        (1 << 12, .calibrationOngoing),
    ]
    private static let questionableMeasurementMasks: [(UInt16, QualityReason)] = [
        (1 << 14, .questionableMeasurement),
    ]
    private static let invalidMeasurementMasks: [(UInt16, QualityReason)] = [
        (1 << 13, .measurementUnavailable),
        (1 << 10, .demonstrationData),
        (1 << 11, .testingData),
        (1 << 15, .invalidMeasurement),
    ]
    private static let provisionalDeviceMasks: [(UInt32, QualityReason)] = [
        (1 << 0, .extendedDisplayUpdateOngoing),
        (1 << 9, .signalAnalysisOngoing),
    ]
    private static let questionableDeviceMasks: [(UInt32, QualityReason)] = [
        (1 << 2, .signalProcessingIrregularity),
        (1 << 3, .inadequateSignal),
        (1 << 4, .poorSignal),
        (1 << 5, .lowPerfusion),
        (1 << 6, .erraticSignal),
        (1 << 7, .nonPulsatileSignal),
        (1 << 8, .questionablePulse),
        (1 << 10, .sensorInterference),
    ]
    private static let invalidDeviceMasks: [(UInt32, QualityReason)] = [
        (1 << 1, .equipmentMalfunction),
        (1 << 11, .sensorUnconnectedFromUser),
        (1 << 12, .unknownSensorConnected),
        (1 << 13, .sensorDisplaced),
        (1 << 14, .sensorMalfunction),
        (1 << 15, .sensorDisconnected),
    ]

    private static func reasons<T: BinaryInteger>(
        in value: T,
        masks: [(T, QualityReason)]
    ) -> [QualityReason] {
        masks.compactMap { mask, reason in value & mask == 0 ? nil : reason }
    }

    /// Continuous Measurement (0x2A5F).
    ///
    /// Layout: flags byte, then the always-present SpO2PR-Normal pair (two SFLOATs),
    /// then optional SpO2PR-Fast (bit0), SpO2PR-Slow (bit1), Measurement Status (bit2),
    /// Device and Sensor Status (bit3, uint24), Pulse Amplitude Index (bit4).
    static func continuous(data: Data) -> PulseOximeterMeasurement? {
        var reader = BinaryReader(data)
        guard let flags = reader.uint8() else { return nil }

        let spo2 = reader.sfloat()
        let pulse = reader.sfloat()
        guard spo2 != nil || pulse != nil else { return nil }

        var result = PulseOximeterMeasurement(spo2Percent: spo2, pulseRateBPM: pulse)

        // Every field a flag declares must be present. A frame cut off inside a declared
        // field is malformed, not "clean": `quality(for:)` scores an absent status as zero,
        // so a truncated frame would otherwise be admitted as `.accepted` evidence and
        // bypass the invalid and questionable checks. A flag that is clear leaves its field
        // absent, which is a different fact and stays valid.
        if flags & 0x01 != 0, !reader.skipSFloatPair() { return nil }   // fast
        if flags & 0x02 != 0, !reader.skipSFloatPair() { return nil }   // slow
        if flags & 0x04 != 0 {
            guard let status = reader.uint16() else { return nil }
            result.measurementStatus = status
        }
        if flags & 0x08 != 0 {
            guard let status = reader.uint24() else { return nil }
            result.deviceAndSensorStatus = status
        }
        if flags & 0x10 != 0 {
            guard let index = reader.presentSFloat() else { return nil }
            result.pulseAmplitudeIndex = index.value
        }

        return result
    }

    /// Spot-check Measurement (0x2A5E).
    ///
    /// Layout: flags byte, SpO2 SFLOAT, pulse-rate SFLOAT, then optional Timestamp
    /// (bit0, 7 bytes), Measurement Status (bit1), Device and Sensor Status (bit2,
    /// uint24), Pulse Amplitude Index (bit3).
    static func spotCheck(data: Data) -> PulseOximeterMeasurement? {
        var reader = BinaryReader(data)
        guard let flags = reader.uint8() else { return nil }

        let spo2 = reader.sfloat()
        let pulse = reader.sfloat()
        guard spo2 != nil || pulse != nil else { return nil }

        var result = PulseOximeterMeasurement(spo2Percent: spo2, pulseRateBPM: pulse)

        if flags & 0x01 != 0 {
            switch reader.dateTimeResult() {
            case .valid(let timestamp):
                result.timestamp = timestamp
            case .unknown:
                // Year 0 is the SIG-defined "unknown" value. Preserve the manager's
                // receipt-time fallback for this valid-but-unspecified timestamp.
                result.timestamp = nil
            case .invalid:
                // A flagged field with malformed components is not the same as an unknown
                // timestamp and must not be converted into a current reading.
                return nil
            }
        }
        // See `continuous(data:)`: a declared field that cannot be read rejects the frame.
        if flags & 0x02 != 0 {
            guard let status = reader.uint16() else { return nil }
            result.measurementStatus = status
        }
        if flags & 0x04 != 0 {
            guard let status = reader.uint24() else { return nil }
            result.deviceAndSensorStatus = status
        }
        if flags & 0x08 != 0 {
            guard let index = reader.presentSFloat() else { return nil }
            result.pulseAmplitudeIndex = index.value
        }

        return result
    }
}

/// Decoded Temperature Measurement (0x2A1C) or Intermediate Temperature (0x2A1E).
struct TemperatureMeasurement: Equatable, Sendable {
    /// Always stored in Celsius; Fahrenheit payloads are converted at parse time so the
    /// rest of the app never has to ask.
    var celsius: Double
    var timestamp: Date?
    var temperatureType: UInt8?

    /// Layout: flags byte \u{2014} bit0 unit is Fahrenheit (else Celsius), bit1 timestamp
    /// present, bit2 temperature type present \u{2014} then a 32-bit IEEE-11073 FLOAT.
    init?(data: Data) {
        var reader = BinaryReader(data)
        guard let flags = reader.uint8(), let raw = reader.medfloat32() else { return nil }

        let isFahrenheit = flags & 0x01 != 0
        self.celsius = isFahrenheit ? (raw - 32) * 5.0 / 9.0 : raw

        if flags & 0x02 != 0 {
            switch reader.dateTimeResult() {
            case .valid(let timestamp):
                self.timestamp = timestamp
            case .unknown:
                self.timestamp = nil
            case .invalid:
                return nil
            }
        } else {
            self.timestamp = nil
        }
        if flags & 0x04 != 0 { self.temperatureType = reader.uint8() } else { self.temperatureType = nil }
    }
}
