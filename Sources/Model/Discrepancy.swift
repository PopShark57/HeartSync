import Foundation
import SwiftUI

enum DiscrepancySeverity: Int, Codable, Sendable, Comparable {
    case agreeing = 0
    case notable  = 1
    case major    = 2

    static func < (a: DiscrepancySeverity, b: DiscrepancySeverity) -> Bool {
        a.rawValue < b.rawValue
    }

    var title: String {
        switch self {
        case .agreeing: "In agreement"
        case .notable:  "Notable gap"
        case .major:    "Major gap"
        }
    }

    var tint: Color {
        switch self {
        case .agreeing: .green
        case .notable:  .orange
        case .major:    .red
        }
    }

    var systemImage: String {
        switch self {
        case .agreeing: "checkmark.circle.fill"
        case .notable:  "exclamationmark.triangle.fill"
        case .major:    "exclamationmark.octagon.fill"
        }
    }
}

/// One source's aggregated value inside a comparison window.
struct SourceValue: Identifiable, Hashable, Sendable {
    var sourceID: String
    var value: Double
    /// Number of raw samples that went into `value`. A one-sample average from a device
    /// that should be streaming is weak evidence, and the UI shows this.
    var sampleCount: Int
    /// Spread of the samples inside the window. High spread means the device itself is
    /// unstable, which is a different problem from two devices disagreeing.
    var standardDeviation: Double
    var provenance: Provenance

    var id: String { sourceID }
}

/// A single time window in which two or more sources reported the same metric.
///
/// The app's headline feature is showing these side by side; flagging the gap is the
/// secondary read on the same data, not a separate pipeline.
struct ComparisonWindow: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue)-\(Int(start.timeIntervalSince1970))" }

    var kind: MetricKind
    var start: Date
    var duration: TimeInterval
    /// Sorted by `sourceID` so ordering is stable between refreshes.
    var values: [SourceValue]

    var end: Date { start.addingTimeInterval(duration) }

    var minimum: SourceValue? { values.min { $0.value < $1.value } }
    var maximum: SourceValue? { values.max { $0.value < $1.value } }

    /// Largest gap between any two sources in this window.
    var spread: Double {
        guard let lo = minimum, let hi = maximum else { return 0 }
        return hi.value - lo.value
    }

    var severity: DiscrepancySeverity {
        guard values.count >= 2 else { return .agreeing }
        return kind.agreement.severity(forDelta: spread)
    }

    /// Mean across sources — the app's best single answer when devices disagree.
    var consensus: Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + $1.value } / Double(values.count)
    }

    func value(for sourceID: String) -> SourceValue? {
        values.first { $0.sourceID == sourceID }
    }
}

/// A persistent disagreement between exactly two sources, summarised over a longer span.
///
/// Distinct from `ComparisonWindow`: a single window disagreeing is usually motion
/// artefact, but the same pair disagreeing in the same direction for hours is a real
/// calibration difference worth surfacing.
struct Discrepancy: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue)-\(sourceA)-\(sourceB)" }

    var kind: MetricKind
    var sourceA: String
    var sourceB: String
    /// Mean signed difference, A minus B. Sign carries meaning: a consistent sign is bias,
    /// an alternating sign is noise.
    var meanBias: Double
    /// Mean of the absolute differences.
    var meanAbsoluteDifference: Double
    /// Standard deviation of the signed differences \u{2014} the "limits of agreement" width
    /// from a Bland\u{2013}Altman analysis, which is the standard way to compare two
    /// measurement devices against each other when neither is a gold standard.
    var differenceSD: Double
    var windowCount: Int
    var span: DateInterval

    var severity: DiscrepancySeverity {
        kind.agreement.severity(forDelta: meanAbsoluteDifference)
    }

    /// Bland\u{2013}Altman 95% limits of agreement.
    var limitsOfAgreement: ClosedRange<Double> {
        let lo = meanBias - 1.96 * differenceSD
        let hi = meanBias + 1.96 * differenceSD
        return lo...hi
    }

    /// True when the gap is consistently in one direction rather than scattering around
    /// zero \u{2014} i.e. one device really does read higher than the other.
    var isSystematicBias: Bool {
        guard meanAbsoluteDifference > 0 else { return false }
        // A zero spread with a non-zero bias is the most systematic case there is, so it
        // must not fall through the `> differenceSD` comparison.
        if differenceSD == 0 { return abs(meanBias) > 0 }
        return abs(meanBias) > differenceSD
    }
}
