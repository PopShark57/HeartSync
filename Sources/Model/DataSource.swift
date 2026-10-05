import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// Last known battery level, 0...100, from the Battery Service or a ring's identity reply.
    var batteryPercent: Int?
    /// True while the device last reported charging. Only a vendor ring reports it; nil
    /// otherwise. Optional keeps older source archives backward-decodable.
    var batteryIsCharging: Bool?
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
    /// `HKSourceRevision.productType` values seen for a HealthKit writer ("Watch7,12",
    /// "iPhone17,2"): the hardware the writing software ran on. `HealthKitWatchRelay` uses it
    /// to tell a watch's own writer from the iPhone that relays the watch's Blood Oxygen.
    /// Metadata, not identity. Optional keeps older source archives backward-decodable.
    var writerProductTypes: Set<String>?
    /// True once the user has renamed this source. A transport upsert then leaves the name
    /// alone: Bluetooth updates reuse the stored name anyway, but a Health or Oura source
    /// re-reports its own name on every sync, which would undo the user's alias. Optional
    /// keeps older source archives backward-decodable.
    var displayNameIsUserChosen: Bool?

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

    /// Source colour slots, in `colorIndex` order. Sources are assigned round-robin on add.
    ///
    /// Measured, not asserted. `ColourVisionTests` requires a CAM02-UCS ΔE of at least 15
    /// between every two slots in ordinary vision, and between every slot and the neutral
    /// ink reserved for statistical reference lines, in both appearances. The first six
    /// slots also hold that floor under simulated protan, deutan, and tritan deficiency
    /// (Machado et al. 2009, full severity); the four added later (red, gold, teal, orchid)
    /// do not, so each slot's shape (`SourceSymbol`) is what keeps devices apart there.
    /// Each slot keeps at least 3:1 contrast against the list backgrounds it is drawn on.
    ///
    /// `colorIndex` persists, so slots are changed in place and never renumbered: every
    /// device keeps its slot, and its shape (`SourceSymbol`), across this change.
    static let paletteSlots: [SourcePaletteSlot] = [
        SourcePaletteSlot(
            name: "blue",
            light: SRGBColor(red: 0.22, green: 0.27, blue: 0.67),    // #3845AB
            dark: SRGBColor(red: 0.42, green: 0.65, blue: 1.00)      // #6BA6FF
        ),
        SourcePaletteSlot(
            name: "amber",
            light: SRGBColor(red: 0.48, green: 0.22, blue: 0.00),    // #7A3800
            dark: SRGBColor(red: 0.75, green: 0.46, blue: 0.00)      // #BF7500
        ),
        SourcePaletteSlot(
            name: "green",
            light: SRGBColor(red: 0.28, green: 0.53, blue: 0.00),    // #478700
            dark: SRGBColor(red: 0.67, green: 1.00, blue: 0.31)      // #ABFF4F
        ),
        SourcePaletteSlot(
            name: "violet",
            light: SRGBColor(red: 0.51, green: 0.26, blue: 1.00),    // #8242FF
            dark: SRGBColor(red: 0.52, green: 0.38, blue: 1.00)      // #8561FF
        ),
        SourcePaletteSlot(
            name: "magenta",
            light: SRGBColor(red: 0.70, green: 0.00, blue: 0.39),    // #B20063
            dark: SRGBColor(red: 0.85, green: 0.00, blue: 0.66)      // #D900A8
        ),
        SourcePaletteSlot(
            name: "cyan",
            light: SRGBColor(red: 0.09, green: 0.59, blue: 0.78),    // #1796C7
            dark: SRGBColor(red: 0.07, green: 0.87, blue: 1.00)      // #12DEFF
        ),
        SourcePaletteSlot(
            name: "red",
            light: SRGBColor(red: 0.71, green: 0.06, blue: 0.02),    // #B51005
            dark: SRGBColor(red: 0.65, green: 0.34, blue: 0.32)      // #A75751
        ),
        SourcePaletteSlot(
            name: "gold",
            light: SRGBColor(red: 0.56, green: 0.44, blue: 0.11),    // #8F701D
            dark: SRGBColor(red: 1.00, green: 0.87, blue: 0.22)      // #FFDE37
        ),
        SourcePaletteSlot(
            name: "teal",
            light: SRGBColor(red: 0.03, green: 0.59, blue: 0.52),    // #089684
            dark: SRGBColor(red: 0.13, green: 0.62, blue: 0.51)      // #219F81
        ),
        SourcePaletteSlot(
            name: "orchid",
            light: SRGBColor(red: 0.56, green: 0.13, blue: 0.62),    // #8F229E
            dark: SRGBColor(red: 0.96, green: 0.47, blue: 0.98)      // #F479FB
        ),
    ]

    /// The slot for a source about to be added: one of those the fewest devices wear,
    /// preferring slots that no enabled device wears, and chosen at random among equals so
    /// a new device does not always arrive in the same colour. The colour is then stored
    /// in `colorIndex`, so it stays with the device. Sharing only starts once every slot is
    /// worn; this keeps it to the least possible.
    static func leastUsedColorIndex(
        among sources: [DataSource],
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        let count = paletteSlots.count
        var enabled = [Int](repeating: 0, count: count)
        var total = [Int](repeating: 0, count: count)
        for source in sources {
            let slot = slotIndex(source.colorIndex)
            total[slot] += 1
            if source.isEnabled { enabled[slot] += 1 }
        }
        return leastUsedSlot(enabled: enabled, total: total, using: &generator)
    }

    static func leastUsedColorIndex(among sources: [DataSource]) -> Int {
        var generator = SystemRandomNumberGenerator()
        return leastUsedColorIndex(among: sources, using: &generator)
    }

    private static func leastUsedSlot(
        enabled: [Int],
        total: [Int],
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        let slots = enabled.indices
        let best = slots.map { (enabled[$0], total[$0]) }.min { $0 < $1 } ?? (0, 0)
        let candidates = slots.filter { (enabled[$0], total[$0]) == best }
        return candidates.randomElement(using: &generator) ?? 0
    }

    /// New slots for sources whose colour another source already wears, keyed by source ID.
    ///
    /// Sources persisted before the store spread them (a seventh device took
    /// `count % 6`, and removals left gaps) can share a slot, which drew two devices in one
    /// colour. Enabled sources are placed first, oldest first, and keep their slot unless an
    /// earlier one holds it; only the later one moves, to a least used slot chosen at random. Sources that
    /// keep their slot are never listed, so an unshared device keeps its colour and shape,
    /// and running this again on its own result changes nothing.
    static func colorIndexRepairs(for sources: [DataSource]) -> [String: Int] {
        var generator = SystemRandomNumberGenerator()
        return colorIndexRepairs(for: sources, using: &generator)
    }

    static func colorIndexRepairs(
        for sources: [DataSource],
        using generator: inout some RandomNumberGenerator
    ) -> [String: Int] {
        let count = paletteSlots.count
        var enabledUse = [Int](repeating: 0, count: count)
        var totalUse = [Int](repeating: 0, count: count)
        var repairs: [String: Int] = [:]
        let ordered = sources.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return lhs.id < rhs.id
        }
        for source in ordered {
            var slot = slotIndex(source.colorIndex)
            let keeps = source.isEnabled ? enabledUse[slot] == 0 : totalUse[slot] == 0
            if !keeps {
                slot = leastUsedSlot(enabled: enabledUse, total: totalUse, using: &generator)
            }
            totalUse[slot] += 1
            if source.isEnabled { enabledUse[slot] += 1 }
            if slot != source.colorIndex { repairs[source.id] = slot }
        }
        return repairs
    }

    private static func slotIndex(_ colorIndex: Int) -> Int {
        let count = paletteSlots.count
        return ((colorIndex % count) + count) % count
    }

    /// The slots as colours that follow the system appearance.
    static let palette: [Color] = paletteSlots.map(\.color)

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

extension SourcePaletteSlot {
    /// Resolves to the light or dark value with the trait environment it is drawn in, as
    /// the system colours around it do. A fixed sRGB value tuned for white lost contrast on
    /// the dark list background.
    var color: Color {
        #if canImport(UIKit)
        let light = self.light
        let dark = self.dark
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
        #else
        // Only the macOS scratch test harness (AGENTS.md) builds without UIKit. It draws
        // nothing, so the light value keeps the model layer compiling there.
        return Color(red: light.red, green: light.green, blue: light.blue)
        #endif
    }
}

/// How a sensor acquires a signal, only when explicitly known.
enum SensorTechnology: String, Codable, Hashable, Sendable, CaseIterable {
    case opticalPPG
    case electricalECG
    case other

    var title: String {
        switch self {
        case .opticalPPG:
            String(localized: "sensorTechnology.opticalPPG", defaultValue: "Optical (PPG)", comment: "How a sensor acquires its signal: light through the skin")
        case .electricalECG:
            String(localized: "sensorTechnology.electricalECG", defaultValue: "Electrical (ECG)", comment: "How a sensor acquires its signal: electrical activity of the heart")
        case .other:
            String(localized: "sensorTechnology.other", defaultValue: "Other", comment: "How a sensor acquires its signal: something else")
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

    /// An average over an interval longer than its metric's comparison window: Oura's
    /// whole-night heart rate, breathing rate, and HRV, or its daily SpO\u{2082}.
    ///
    /// Such a value belongs to its whole interval, not to the window around its midpoint.
    /// Pairing it there would compare a night's mean with one minute of another device, so
    /// `ComparisonEngine.windows` leaves it out by default, compaction never folds it into a
    /// window median, and charts draw it as a span. A compacted median spans exactly one
    /// window and is not one of these.
    var isIntervalAverage: Bool {
        end.timeIntervalSince(start) > kind.comparisonWindow
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
    /// Set on values HeartSync computed itself rather than read from a device, so a
    /// reconciliation pass can recognise them positively instead of by provenance alone.
    /// Optional and absent from older rows, which decode unchanged.
    var modelledBy: String?

    /// The `modelledBy` value HeartSync's own estimators write.
    static let heartSyncModel = "heartsync.estimator"

    init(
        quality: MeasurementQuality? = nil,
        pulseAmplitudeIndex: Double? = nil,
        observationDuration: TimeInterval? = nil,
        acceptedBeatCount: Int? = nil,
        artefactFraction: Double? = nil,
        pnn50: Double? = nil,
        impliedHeartRate: Double? = nil,
        aggregation: AggregationMetadata? = nil,
        modelledBy: String? = nil
    ) {
        self.quality = quality
        self.pulseAmplitudeIndex = pulseAmplitudeIndex
        self.observationDuration = observationDuration
        self.acceptedBeatCount = acceptedBeatCount
        self.artefactFraction = artefactFraction
        self.pnn50 = pnn50
        self.impliedHeartRate = impliedHeartRate
        self.aggregation = aggregation
        self.modelledBy = modelledBy
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
