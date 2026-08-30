import Foundation
import Testing
@testable import HeartSyncChecker

/// Test vectors are hand-built from the Bluetooth SIG characteristic definitions. Getting
/// these wrong is the failure mode that would quietly corrupt every comparison in the app,
/// so they are pinned here rather than trusted to review.
@Suite("GATT parsing")
struct ParsingTests {

    // MARK: IEEE-11073 SFLOAT

    @Test("SFLOAT decodes a positive integer mantissa with zero exponent")
    func sfloatInteger() {
        #expect(BinaryReader.decodeSFloat(0x0061) == 97)   // SpO2 97%
        #expect(BinaryReader.decodeSFloat(0x0048) == 72)   // pulse 72 bpm
    }

    @Test("SFLOAT applies a negative exponent")
    func sfloatNegativeExponent() {
        // exponent nibble 0xF -> -1, mantissa 100 -> 100 * 10^-1
        let value = try! #require(BinaryReader.decodeSFloat(0xF064))
        #expect(abs(value - 10.0) < 1e-9)
    }

    @Test("SFLOAT sign-extends a negative mantissa")
    func sfloatNegativeMantissa() {
        // mantissa 0xFFF is -1 once sign-extended across 12 bits
        #expect(BinaryReader.decodeSFloat(0x0FFF) == -1)
    }

    @Test("SFLOAT rejects the reserved special values")
    func sfloatSpecials() {
        // Treating these as numbers would inject values like 2047 into the record.
        for raw: UInt16 in [0x07FF, 0x0800, 0x07FE, 0x0802, 0x0801] {
            #expect(BinaryReader.decodeSFloat(raw) == nil)
        }
    }

    @Test("32-bit medical float decodes with a negative exponent")
    func medFloat32() {
        // exponent 0xFF -> -1, mantissa 368 -> 36.8
        let value = try! #require(BinaryReader.decodeMedFloat32(0xFF00_0170))
        #expect(abs(value - 36.8) < 1e-9)
    }

    // MARK: Heart Rate Measurement (0x2A37)

    @Test("8-bit heart rate")
    func heartRate8Bit() throws {
        let measurement = try #require(HeartRateMeasurement(data: Data([0x00, 0x48])))
        #expect(measurement.beatsPerMinute == 72)
        #expect(measurement.isSensorContactDetected == nil)   // not supported by this sensor
        #expect(measurement.rrIntervalsMS.isEmpty)
    }

    @Test("16-bit heart rate is little-endian")
    func heartRate16Bit() throws {
        // 0x012C == 300 would be implausible; use 200 to confirm byte order, not clamping.
        let measurement = try #require(HeartRateMeasurement(data: Data([0x01, 0xC8, 0x00])))
        #expect(measurement.beatsPerMinute == 200)
    }

    @Test("R\u{2013}R intervals convert from 1/1024 s to milliseconds")
    func heartRateRRIntervals() throws {
        // flags 0x10 -> R\u{2013}R present. 1024 units == exactly 1000 ms; 768 == 750 ms.
        let data = Data([0x10, 0x3C, 0x00, 0x04, 0x00, 0x03])
        let measurement = try #require(HeartRateMeasurement(data: data))
        #expect(measurement.beatsPerMinute == 60)
        #expect(measurement.rrIntervalsMS.count == 2)
        #expect(abs(measurement.rrIntervalsMS[0] - 1000) < 1e-9)
        #expect(abs(measurement.rrIntervalsMS[1] - 750) < 1e-9)
    }

    @Test("Sensor contact state is reported only when the sensor supports it")
    func heartRateSensorContact() throws {
        // flags 0x16: contact detected + contact supported + R\u{2013}R present
        let detected = try #require(HeartRateMeasurement(data: Data([0x16, 0x3C, 0x00, 0x04])))
        #expect(detected.isSensorContactDetected == true)

        // flags 0x04: supported but not detected -> off-body, readings must be discarded
        let notDetected = try #require(HeartRateMeasurement(data: Data([0x04, 0x3C])))
        #expect(notDetected.isSensorContactDetected == false)
    }

    @Test("Energy expended is skipped correctly before R\u{2013}R intervals")
    func heartRateEnergyThenRR() throws {
        // flags 0x18: energy present + R\u{2013}R present. Energy 1000 kJ, then one interval.
        let data = Data([0x18, 0x50, 0xE8, 0x03, 0x00, 0x04])
        let measurement = try #require(HeartRateMeasurement(data: data))
        #expect(measurement.beatsPerMinute == 80)
        #expect(measurement.energyExpendedJoules == 1_000_000)
        // If the energy field were not skipped, this interval would be misparsed.
        #expect(measurement.rrIntervalsMS.count == 1)
        #expect(abs(measurement.rrIntervalsMS[0] - 1000) < 1e-9)
    }

    @Test("Truncated heart rate frames are rejected rather than half-parsed")
    func heartRateTruncated() {
        #expect(HeartRateMeasurement(data: Data()) == nil)
        #expect(HeartRateMeasurement(data: Data([0x00])) == nil)
        #expect(HeartRateMeasurement(data: Data([0x01, 0x48])) == nil)   // claims uint16, has one byte
    }

    // MARK: Pulse Oximeter (0x2A5E / 0x2A5F)

    @Test("Continuous PLX measurement reads SpO2 and pulse")
    func plxContinuous() throws {
        let data = Data([0x00, 0x61, 0x00, 0x48, 0x00])
        let measurement = try #require(PulseOximeterMeasurement.continuous(data: data))
        #expect(measurement.spo2Percent == 97)
        #expect(measurement.pulseRateBPM == 72)
        #expect(!measurement.isDeviceReportedInvalid)
    }

    @Test("Optional PLX fields are skipped in the order the spec defines")
    func plxOptionalFieldOrder() throws {
        // flags 0x11: SpO2PR-Fast present (bit0) and pulse amplitude index present (bit4).
        // The fast pair must be consumed before the amplitude index is read.
        let data = Data([
            0x11,
            0x61, 0x00,          // SpO2 normal 97
            0x48, 0x00,          // pulse normal 72
            0x62, 0x00,          // SpO2 fast 98 (skipped)
            0x4A, 0x00,          // pulse fast 74 (skipped)
            0x0A, 0x00,          // pulse amplitude index 10
        ])
        let measurement = try #require(PulseOximeterMeasurement.continuous(data: data))
        #expect(measurement.spo2Percent == 97)
        #expect(measurement.pulseAmplitudeIndex == 10)
    }

    @Test("A device-flagged bad measurement is recognised as invalid")
    func plxInvalidStatus() throws {
        // flags 0x08 -> device and sensor status present; bit 10 is "sensor unconnected".
        let data = Data([0x08, 0x61, 0x00, 0x48, 0x00, 0x00, 0x04, 0x00])
        let measurement = try #require(PulseOximeterMeasurement.continuous(data: data))
        #expect(measurement.isDeviceReportedInvalid)
    }

    @Test("Spot-check PLX parses a device timestamp")
    func plxSpotCheckTimestamp() throws {
        // flags 0x01 -> timestamp present. 2024-03-05 14:30:00.
        let data = Data([
            0x01,
            0x61, 0x00,
            0x48, 0x00,
            0xE8, 0x07, 0x03, 0x05, 0x0E, 0x1E, 0x00,
        ])
        let measurement = try #require(PulseOximeterMeasurement.spotCheck(data: data))
        #expect(measurement.spo2Percent == 97)
        let timestamp = try #require(measurement.timestamp)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        #expect(parts.year == 2024)
        #expect(parts.month == 3)
        #expect(parts.day == 5)
        #expect(parts.hour == 14)
        #expect(parts.minute == 30)
    }

    // MARK: Thermometer (0x2A1C)

    @Test("Celsius temperature parses directly")
    func temperatureCelsius() throws {
        let measurement = try #require(TemperatureMeasurement(data: Data([0x00, 0x70, 0x01, 0x00, 0xFF])))
        #expect(abs(measurement.celsius - 36.8) < 1e-9)
    }

    @Test("Fahrenheit temperature is converted to Celsius at parse time")
    func temperatureFahrenheit() throws {
        // flags 0x01 -> Fahrenheit. 98.6 F == 37.0 C.
        let measurement = try #require(TemperatureMeasurement(data: Data([0x01, 0xDA, 0x03, 0x00, 0xFF])))
        #expect(abs(measurement.celsius - 37.0) < 1e-9)
    }
}
