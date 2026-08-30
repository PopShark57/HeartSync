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

    var title: String {
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
/// writing source plus its device model, for Oura a constant.
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
        batteryPercent: Int? = nil
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

    var title: String {
        switch self {
        case .measured:  "Measured"
        case .derived:   "Derived"
        case .estimated: "Estimated"
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

    init(
        id: UUID = UUID(),
        sourceID: String,
        kind: MetricKind,
        value: Double,
        start: Date,
        end: Date? = nil,
        provenance: Provenance = .measured
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.value = value
        self.start = start
        self.end = end ?? start
        self.provenance = provenance
    }

    var midpoint: Date {
        Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)
    }

    /// Rejects values outside the metric's plausible range so obviously broken sensor
    /// frames never reach the comparison engine.
    var isPlausible: Bool { kind.plausibleRange.contains(value) }
}
