import Foundation
import SwiftUI

/// Where a reading came from.
///
/// The three transports are genuinely different and the app does not pretend otherwise:
/// `bluetooth` is a live GATT connection this app owns, `healthKit` is data Apple already
/// collected (Apple Watch and anything else writing to Health), and `oura` is a cloud pull.
enum SourceTransport: String, Codable, Sendable, CaseIterable {
    case bluetooth
    case healthKit
    case oura
    case manual

    /// Human-readable transport name **for the screen**.
    ///
    /// Localized. Three of the four are product names that stay as they are in every
    /// language; they are still routed through the catalog so a translator can see them in
    /// context and adapt the one that is ordinary prose. The English `defaultValue`s are
    /// byte-identical to `exportTitle`.
    var title: String {
        switch self {
        case .bluetooth:
            String(localized: "transport.bluetooth", defaultValue: "Bluetooth", comment: "Transport name: a direct Bluetooth Low Energy sensor. Bluetooth is a trademark and is not translated.")
        case .healthKit:
            String(localized: "transport.healthKit", defaultValue: "Apple Health", comment: "Transport name: data Apple Health already collected, including anything an Apple Watch synced. Use Apple's own localized name for the Health app.")
        case .oura:
            String(localized: "transport.oura", defaultValue: "Oura Cloud", comment: "Transport name: data pulled from the Oura web API. Oura is a brand name and is not translated.")
        case .manual:
            String(localized: "transport.manual", defaultValue: "Manual Entry", comment: "Transport name: a value the user typed in themselves rather than a device reporting it")
        }
    }

    /// Human-readable transport name **for exports**, in English regardless of the device
    /// language.
    ///
    /// `PairwiseExporter` writes it into the plain-text summary ("Transport: Bluetooth"),
    /// which is a stable exported artefact rather than screen copy: two users comparing
    /// their summaries must not find the same device described by two different words.
    /// The CSV uses `rawValue` and is unaffected either way.
    var exportTitle: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .healthKit: "Apple Health"
        case .oura:      "Oura Cloud"
        case .manual:    "Manual Entry"
        }
    }

    var systemImage: String {
        switch self {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .healthKit: "heart.text.square.fill"
        case .oura:      "circle.circle.fill"
        case .manual:    "square.and.pencil"
        }
    }

    var tint: Color {
        switch self {
        case .bluetooth: .blue
        case .healthKit: .pink
        case .oura:      .indigo
        case .manual:    .gray
        }
    }

    /// Whether this transport streams in real time. Cloud and Health are pull-based and
    /// will always lag; the UI says so rather than showing a stale value as "live".
    var isLive: Bool { self == .bluetooth }
}

/// A configured data source. One per physical device (or per cloud account).
///
/// `id` is stable across launches so historical readings keep pointing at the right device:
/// for Bluetooth it is the `CBPeripheral.identifier`, for HealthKit the bundle id of the
/// writing source (the device model is metadata, not identity), and for Oura a constant.
/// The HealthKit formula is migration-sensitive: adding the model now would split existing
/// sources and orphan their historical relationship.
struct DataSource: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var displayName: String
    var transport: SourceTransport
    /// Manufacturer/model string when the device reports one (Device Information Service,
    /// `HKDevice.model`, etc). Nil when unknown.
    var model: String?
    /// User-assigned colour index so the same device keeps the same colour in every chart.
    var colorIndex: Int
    var isEnabled: Bool
    var addedAt: Date
    var lastSeenAt: Date?
    /// Metrics this source has actually produced at least once. Populated as data arrives,
    /// so the UI never advertises a capability the device hasn't demonstrated.
    var observedMetrics: Set<MetricKind>
    /// Last known battery level, 0...100, when the device exposes the Battery Service.
    var batteryPercent: Int?
    /// Where on the body the sensor sits, when it reports Body Sensor Location (0x2A38).
    /// The characteristic says nothing about sensing technology; chest must not be treated
    /// as proof of ECG and wrist/finger must not be treated as proof of PPG.
    var bodyLocation: BodySensorLocation?
    /// Sensing technology only when it came from explicit device metadata, a reviewed model
    /// registry, or a user confirmation. Body Sensor Location never populates this field.
    var sensingTechnology: SensorTechnology?
    /// Device descriptors observed behind one HealthKit writer. HealthKit often identifies
    /// the writing app more reliably than the physical device, so retaining the set prevents
    /// one mutable `model` string from silently hiding a replacement or second device.
    var observedDeviceModels: Set<String>?
    /// Stable relationship key for sources that likely represent the same upstream device
    /// through different transports. This is a warning signal, never an automatic merge.
    var upstreamDeviceRelationshipID: String?
    /// True when the stable id identifies a HealthKit writing app rather than a proven
    /// physical instrument. Optional keeps older source archives backward-decodable.
    var identifiesHealthKitWriter: Bool?

    init(
        id: String,
        displayName: String,
        transport: SourceTransport,
        model: String? = nil,
        colorIndex: Int = 0,
        isEnabled: Bool = true,
        addedAt: Date = .now,
        lastSeenAt: Date? = nil,
        observedMetrics: Set<MetricKind> = [],
        batteryPercent: Int? = nil,
        bodyLocation: BodySensorLocation? = nil,
        sensingTechnology: SensorTechnology? = nil,
        observedDeviceModels: Set<String>? = nil,
        upstreamDeviceRelationshipID: String? = nil,
        identifiesHealthKitWriter: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.model = model
        self.colorIndex = colorIndex
        self.isEnabled = isEnabled
        self.addedAt = addedAt
        self.lastSeenAt = lastSeenAt
        self.observedMetrics = observedMetrics
        self.batteryPercent = batteryPercent
        self.bodyLocation = bodyLocation
        self.sensingTechnology = sensingTechnology
        self.observedDeviceModels = observedDeviceModels
        self.upstreamDeviceRelationshipID = upstreamDeviceRelationshipID
        self.identifiesHealthKitWriter = identifiesHealthKitWriter
    }

    var color: Color { Self.palette[colorIndex % Self.palette.count] }

    /// Distinct, colour-blind-tolerant hues. Sources are assigned round-robin on add.
    static let palette: [Color] = [
        Color(red: 0.00, green: 0.48, blue: 1.00),   // blue
        Color(red: 1.00, green: 0.42, blue: 0.21),   // orange
        Color(red: 0.20, green: 0.72, blue: 0.47),   // green
        Color(red: 0.69, green: 0.32, blue: 0.87),   // purple
        Color(red: 0.93, green: 0.26, blue: 0.45),   // rose
        Color(red: 0.12, green: 0.70, blue: 0.78),   // teal
    ]

    static let ouraSourceID = "oura.cloud"

    var hasMultipleReportedDevices: Bool {
        (observedDeviceModels?.count ?? 0) > 1
    }

    func likelyRepresentsSameDevice(as other: DataSource) -> Bool {
        guard id != other.id,
              let relationship = upstreamDeviceRelationshipID,
              !relationship.isEmpty
        else { return false }
        return relationship == other.upstreamDeviceRelationshipID
    }
}

/// How a sensor acquires a signal, only when explicitly known.
enum SensorTechnology: String, Codable, Hashable, Sendable, CaseIterable {
    case opticalPPG
    case electricalECG
    case other

    var title: String {
        switch self {
        case .opticalPPG: "Optical (PPG)"
        case .electricalECG: "Electrical (ECG)"
        case .other: "Other"
        }
    }
}

/// How much a value should be trusted, which matters a great deal when the app is
/// explicitly in the business of pointing at disagreements.
enum Provenance: String, Codable, Sendable {
    /// The sensor reported this number directly.
    case measured
    /// Computed by this app from raw sensor data (e.g. RMSSD from RR intervals).
    case derived
    /// A modelled guess, not a measurement. Never medical.
    case estimated

    /// How the value was obtained, for the badge shown next to a reading.
    ///
    /// Safe to localize: the export writes `rawValue`, never this, so translating it cannot
    /// move a `provenance` CSV field. The distinction it names is load-bearing — an
    /// estimate must never read as a measurement — so the wording must stay exact in
    /// every language.
    var title: String {
        switch self {
        case .measured:
            String(localized: "provenance.measured", defaultValue: "Measured", comment: "Badge: the sensor reported this value directly")
        case .derived:
            String(localized: "provenance.derived", defaultValue: "Derived", comment: "Badge: HeartSync computed this value from raw sensor data, such as RMSSD from R-R intervals")
        case .estimated:
            String(localized: "provenance.estimated", defaultValue: "Estimated", comment: "Badge: a modelled guess, never a measurement and never medical")
        }
    }

    var systemImage: String {
        switch self {
        case .measured:  "sensor.tag.radiowaves.forward.fill"
        case .derived:   "function"
        case .estimated: "questionmark.circle"
        }
    }
}

/// One sample of one metric from one source.
struct Reading: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourceID: String
    var kind: MetricKind
    var value: Double
    var start: Date
    var end: Date
    var provenance: Provenance
    /// Optional interpretation facts. Missing means an older archive or a transport that
    /// did not report these facts; absence must never be converted into false precision.
    var metadata: ReadingMetadata?

    init(
        id: UUID = UUID(),
        sourceID: String,
        kind: MetricKind,
        value: Double,
        start: Date,
        end: Date? = nil,
        provenance: Provenance = .measured,
        metadata: ReadingMetadata? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.value = value
        self.start = start
        self.end = end ?? start
        self.provenance = provenance
        self.metadata = metadata
    }

    var midpoint: Date {
        Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)
    }

    /// Rejects values outside the metric's plausible range so obviously broken sensor
    /// frames never reach the comparison engine.
    var isPlausible: Bool { kind.plausibleRange.contains(value) }
}

/// Measurement and aggregation facts that qualify a reading without changing its value.
struct ReadingMetadata: Codable, Hashable, Sendable {
    var quality: MeasurementQuality?
    var pulseAmplitudeIndex: Double?
    var observationDuration: TimeInterval?
    var acceptedBeatCount: Int?
    var artefactFraction: Double?
    var pnn50: Double?
    var impliedHeartRate: Double?
    var aggregation: AggregationMetadata?

    init(
        quality: MeasurementQuality? = nil,
        pulseAmplitudeIndex: Double? = nil,
        observationDuration: TimeInterval? = nil,
        acceptedBeatCount: Int? = nil,
        artefactFraction: Double? = nil,
        pnn50: Double? = nil,
        impliedHeartRate: Double? = nil,
        aggregation: AggregationMetadata? = nil
    ) {
        self.quality = quality
        self.pulseAmplitudeIndex = pulseAmplitudeIndex
        self.observationDuration = observationDuration
        self.acceptedBeatCount = acceptedBeatCount
        self.artefactFraction = artefactFraction
        self.pnn50 = pnn50
        self.impliedHeartRate = impliedHeartRate
        self.aggregation = aggregation
    }
}

enum MeasurementQuality: String, Codable, Hashable, Sendable {
    case accepted
    case provisional
    case questionable
}

/// Provenance retained when raw rows are irreversibly reduced to a window median.
struct AggregationMetadata: Codable, Hashable, Sendable {
    /// Number of original raw rows, when known. Nil is honest for a compacted archive whose
    /// older schema did not retain it.
    var originalSampleCount: Int?
    /// Population standard deviation of the original rows, when known.
    var originalStandardDeviation: Double?
    var correctionsAreFinal: Bool

    init(
        originalSampleCount: Int?,
        originalStandardDeviation: Double?,
        correctionsAreFinal: Bool = true
    ) {
        self.originalSampleCount = originalSampleCount
        self.originalStandardDeviation = originalStandardDeviation
        self.correctionsAreFinal = correctionsAreFinal
    }
}
