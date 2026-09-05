import Foundation

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
