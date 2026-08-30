import Foundation

/// Biometrics the estimators need, plus the cuff calibration that the blood-pressure
/// feature is anchored to.
struct UserProfile: Codable, Hashable, Sendable {
    enum BiologicalSex: String, Codable, Sendable, CaseIterable, Identifiable {
        case female, male, unspecified
        var id: String { rawValue }
        var title: String {
            switch self {
            case .female: "Female"
            case .male: "Male"
            case .unspecified: "Prefer not to say"
            }
        }
    }

    var birthDate: Date?
    var sex: BiologicalSex = .unspecified
    var heightCM: Double?
    var weightKG: Double?

    /// A real cuff measurement the user entered, used to anchor the blood-pressure trend
    /// index. Without it the app refuses to show a BP estimate at all.
    var bpCalibration: BPCalibration?

    var age: Int? {
        guard let birthDate else { return nil }
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: .now).year
        guard let years, years > 0, years < 130 else { return nil }
        return years
    }

    /// Tanaka et al. (2001), `HRmax = 208 - 0.7 * age`. More accurate across ages than the
    /// old `220 - age` rule, particularly for older adults.
    var estimatedMaxHeartRate: Double? {
        guard let age else { return nil }
        return 208 - 0.7 * Double(age)
    }

    struct BPCalibration: Codable, Hashable, Sendable {
        var systolic: Double
        var diastolic: Double
        /// Resting heart rate at the moment of the cuff reading; the index is expressed
        /// relative to this operating point.
        var referenceRestingHR: Double
        /// Resting HRV (RMSSD) at the moment of the cuff reading, when available.
        var referenceRMSSD: Double?
        var takenAt: Date

        /// Calibrations decay. After this long the anchor is too old to lean on and the
        /// app stops showing the index until the user re-calibrates.
        static let validity: TimeInterval = 30 * 86_400

        var isExpired: Bool { Date.now.timeIntervalSince(takenAt) > Self.validity }
        var expiresAt: Date { takenAt.addingTimeInterval(Self.validity) }
    }
}
