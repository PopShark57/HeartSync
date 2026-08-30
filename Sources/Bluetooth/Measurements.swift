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
    var spo2Percent: Double?
    var pulseRateBPM: Double?
    /// Perfusion strength, when reported. Low perfusion is the usual reason a finger-worn
    /// sensor disagrees with a chest strap, so it is worth keeping.
    var pulseAmplitudeIndex: Double?
    /// Device timestamp from a spot-check reading, when present.
    var timestamp: Date?
    var measurementStatus: UInt16?
    var deviceAndSensorStatus: UInt32?

    /// True when the device's own status bits say the measurement is unreliable
    /// (bit 5 "Measurement Ongoing" and bit 6 "Early Estimated Data" are fine; the
    /// validity bits below are not).
    var isDeviceReportedInvalid: Bool {
        guard let status = deviceAndSensorStatus else { return false }
        // Device and Sensor Status bits that mean "do not trust this value":
        // 0 Extended Display Update Ongoing, 1 Equipment Malfunction,
        // 2 Signal Processing Irregularity, 3 Inadequate Signal,
        // 4 Poor Perfusion, 5 Erratic Signal, 6 Nonpulsatile Signal,
        // 7 Questionable Pulse, 8 Signal Analysis Ongoing, 9 Sensor Interference,
        // 10 Sensor Unconnected, 11 Unknown Sensor Connected, 12 Sensor Displaced,
        // 13 Sensor Malfunction, 14 Sensor Disconnected.
        let invalidMask: UInt32 = 0b0111_1111_1111_1110
        return status & invalidMask != 0
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

        if flags & 0x01 != 0 { _ = reader.sfloat(); _ = reader.sfloat() }   // fast
        if flags & 0x02 != 0 { _ = reader.sfloat(); _ = reader.sfloat() }   // slow
        if flags & 0x04 != 0 { result.measurementStatus = reader.uint16() }
        if flags & 0x08 != 0 { result.deviceAndSensorStatus = reader.uint24() }
        if flags & 0x10 != 0 { result.pulseAmplitudeIndex = reader.sfloat() }

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

        if flags & 0x01 != 0 { result.timestamp = reader.dateTime() }
        if flags & 0x02 != 0 { result.measurementStatus = reader.uint16() }
        if flags & 0x04 != 0 { result.deviceAndSensorStatus = reader.uint24() }
        if flags & 0x08 != 0 { result.pulseAmplitudeIndex = reader.sfloat() }

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

        if flags & 0x02 != 0 { self.timestamp = reader.dateTime() } else { self.timestamp = nil }
        if flags & 0x04 != 0 { self.temperatureType = reader.uint8() } else { self.temperatureType = nil }
    }
}
