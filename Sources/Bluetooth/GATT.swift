@preconcurrency import CoreBluetooth

/// Bluetooth SIG assigned numbers for the services and characteristics HeartSync speaks.
///
/// Everything here is from the public GATT specification, which is what generic
/// heart-rate straps, most chest sensors, and standards-compliant rings and pulse
/// oximeters actually advertise. Vendor-proprietary profiles are handled separately \u{2014}
/// see `DeviceProfile`.
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
    static let readOnceCharacteristics: Set<CBUUID> = [
        bodySensorLocation,
        plxFeatures,
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
enum BodySensorLocation: UInt8, Sendable {
    case other = 0, chest = 1, wrist = 2, finger = 3, hand = 4, earLobe = 5, foot = 6

    var title: String {
        switch self {
        case .other:   "Other"
        case .chest:   "Chest"
        case .wrist:   "Wrist"
        case .finger:  "Finger"
        case .hand:    "Hand"
        case .earLobe: "Ear"
        case .foot:    "Foot"
        }
    }

    /// Finger and wrist sensors are optical (PPG); chest sensors are electrical (ECG).
    /// This matters for interpreting a discrepancy: PPG and ECG disagreeing on HRV is
    /// expected behaviour, not a fault.
    var isOptical: Bool { self != .chest }
}
