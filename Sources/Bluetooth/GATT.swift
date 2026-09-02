@preconcurrency import CoreBluetooth
import Foundation

/// Bluetooth SIG assigned numbers for the services and characteristics HeartSync speaks.
///
/// Everything here is from the public GATT specification, which is what generic
/// heart-rate straps, most chest sensors, and standards-compliant rings and pulse
/// oximeters actually advertise. There is deliberately no vendor-proprietary path: a
/// device that does not speak these standard profiles is not supported, and
/// `BluetoothManager` reports that rather than guessing at a private protocol.
enum GATT {

    // MARK: Services

    /// Heart Rate Service. Carries HR and, on better sensors, R\u{2013}R intervals.
    static let heartRateService = CBUUID(string: "180D")
    /// Pulse Oximeter Service. Carries SpO2 and pulse rate.
    static let pulseOximeterService = CBUUID(string: "1822")
    /// Health Thermometer Service.
    static let healthThermometerService = CBUUID(string: "1809")
    /// Battery Service.
    static let batteryService = CBUUID(string: "180F")
    /// Device Information Service. Model/manufacturer strings for display.
    static let deviceInformationService = CBUUID(string: "180A")

    /// Services worth scanning for. Advertising one of these is a strong signal the
    /// device has data HeartSync can read without a vendor SDK.
    static let scanServices: [CBUUID] = [
        heartRateService,
        pulseOximeterService,
        healthThermometerService,
    ]

    /// Services to interrogate once connected.
    static let discoverServices: [CBUUID] = scanServices + [
        batteryService,
        deviceInformationService,
    ]

    // MARK: Characteristics

    /// Heart Rate Measurement (notify). Flags byte + HR + optional energy + optional R\u{2013}R.
    static let heartRateMeasurement = CBUUID(string: "2A37")
    /// Body Sensor Location (read). Wrist, finger, chest, etc.
    static let bodySensorLocation = CBUUID(string: "2A38")

    /// PLX Spot-check Measurement (indicate). One-shot SpO2 reading.
    static let plxSpotCheckMeasurement = CBUUID(string: "2A5E")
    /// PLX Continuous Measurement (notify). Streaming SpO2 + pulse rate.
    static let plxContinuousMeasurement = CBUUID(string: "2A5F")
    /// PLX Features (read). Declares which optional fields the device populates.
    ///
    /// Deliberately absent from `readOnceCharacteristics`. The measurement parsers already
    /// discover the populated optional fields from each frame's own flags byte, so this
    /// characteristic tells the app nothing it does not already know, and nothing in the
    /// UI consumes it. Requesting it only to discard the answer would be a read the user
    /// pays for in radio time. The constant stays because it is the spec identifier a
    /// future "which fields does this oximeter support?" screen would need.
    static let plxFeatures = CBUUID(string: "2A60")

    /// Temperature Measurement (indicate).
    static let temperatureMeasurement = CBUUID(string: "2A1C")
    /// Intermediate Temperature (notify).
    static let intermediateTemperature = CBUUID(string: "2A1E")

    /// Battery Level (read/notify), a single uint8 percentage.
    static let batteryLevel = CBUUID(string: "2A19")

    static let manufacturerNameString = CBUUID(string: "2A29")
    static let modelNumberString = CBUUID(string: "2A24")
    static let firmwareRevisionString = CBUUID(string: "2A26")

    /// Characteristics to subscribe to for continuous data.
    static let notifyCharacteristics: Set<CBUUID> = [
        heartRateMeasurement,
        plxContinuousMeasurement,
        plxSpotCheckMeasurement,
        temperatureMeasurement,
        intermediateTemperature,
        batteryLevel,
    ]

    /// Characteristics to read once on connect.
    ///
    /// Every entry has a consumer in `BluetoothManager.didUpdateValueFor`; a characteristic
    /// whose value would be discarded does not belong here.
    static let readOnceCharacteristics: Set<CBUUID> = [
        bodySensorLocation,
        batteryLevel,
        manufacturerNameString,
        modelNumberString,
        firmwareRevisionString,
    ]

    static func title(for uuid: CBUUID) -> String {
        switch uuid {
        case heartRateService:          "Heart Rate"
        case pulseOximeterService:      "Pulse Oximeter"
        case healthThermometerService:  "Thermometer"
        case batteryService:            "Battery"
        case deviceInformationService:  "Device Info"
        default:                        uuid.uuidString
        }
    }
}

/// Body Sensor Location (characteristic 0x2A38) enumeration.
///
/// The raw values are the Bluetooth SIG assigned numbers and are persisted inside
/// `DataSource` in `sources.json`, so they are a storage contract: never renumber a case.
/// `Codable`/`Hashable` exist for that persistence and for `DataSource`'s synthesized
/// conformances; `CaseIterable` so a picker can offer the full list.
enum BodySensorLocation: UInt8, Sendable, Codable, Hashable, CaseIterable {
    case other = 0, chest = 1, wrist = 2, finger = 3, hand = 4, earLobe = 5, foot = 6

    /// Where the device says it is worn, for display. Only the display text is localized;
    /// the raw values above remain the persisted SIG numbers.
    var title: String {
        switch self {
        case .other:
            String(localized: "bodySensorLocation.other", defaultValue: "Other", comment: "Body sensor location the device did not specify")
        case .chest:
            String(localized: "bodySensorLocation.chest", defaultValue: "Chest", comment: "Body sensor location: chest")
        case .wrist:
            String(localized: "bodySensorLocation.wrist", defaultValue: "Wrist", comment: "Body sensor location: wrist")
        case .finger:
            String(localized: "bodySensorLocation.finger", defaultValue: "Finger", comment: "Body sensor location: finger")
        case .hand:
            String(localized: "bodySensorLocation.hand", defaultValue: "Hand", comment: "Body sensor location: hand")
        case .earLobe:
            String(localized: "bodySensorLocation.earLobe", defaultValue: "Ear", comment: "Body sensor location: ear lobe")
        case .foot:
            String(localized: "bodySensorLocation.foot", defaultValue: "Foot", comment: "Body sensor location: foot")
        }
    }

    /// Finger and wrist sensors are optical (PPG); chest sensors are electrical (ECG).
    /// This matters for interpreting a discrepancy: PPG and ECG disagreeing on HRV is
    /// expected behaviour, not a fault.
    var isOptical: Bool { self != .chest }

    /// How the sensor acquires a beat, for the interpretation text on a comparison.
    ///
    /// Note that `.other` is reported by devices that decline to say, so it is grouped
    /// with the optical majority rather than claimed as electrical: overstating a sensor
    /// as ECG would let the UI dismiss a real disagreement as an expected one.
    var sensingTechnology: String {
        isOptical
            ? String(localized: "sensingTechnology.optical", defaultValue: "Optical (PPG)", comment: "Sensing technology: a photoplethysmography sensor that times a pulse wave at the skin. Keep the PPG abbreviation, which is international.")
            : String(localized: "sensingTechnology.electrical", defaultValue: "Electrical (ECG)", comment: "Sensing technology: an electrocardiography sensor that times the heartbeat's R wave directly. Keep the ECG abbreviation, which is international.")
    }
}
