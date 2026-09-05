import Foundation
import SwiftUI

enum DiscrepancySeverity: Int, Codable, Sendable, Comparable {
    case agreeing = 0
    case notable  = 1
    case major    = 2

    static func < (a: DiscrepancySeverity, b: DiscrepancySeverity) -> Bool {
        a.rawValue < b.rawValue
    }

    /// Evidence wording for the agreement badge **on screen**.
    ///
    /// Localized. This is the wording that decides whether a reader believes their two
    /// devices match, so a translation must keep the three levels clearly separated and must
    /// never soften a gap into agreement: "In agreement" is a claim the app is only allowed
    /// to make when the evidence supports it, and no other case may borrow that phrasing.
    /// The English `defaultValue`s are byte-identical to `exportTitle`.
    var title: String {
        switch self {
        case .agreeing:
            String(localized: "severity.agreeing", defaultValue: "In agreement", comment: "Agreement level: the devices differ by less than the metric's tolerance. This is the only case allowed to read as agreement; never reuse this wording for the other two.")
        case .notable:
            String(localized: "severity.notable", defaultValue: "Notable gap", comment: "Agreement level: the devices differ by at least the metric's warning tolerance. Must read as a real disagreement, not a caveat on agreement.")
        case .major:
            String(localized: "severity.major", defaultValue: "Major gap", comment: "Agreement level: the devices differ by at least the metric's alert tolerance, so one reading is probably wrong. Must read as stronger than the notable level.")
        }
    }

    /// Evidence wording **for exports**, in English regardless of the device language.
    ///
    /// `PairwiseExporter` writes it verbatim as the summary's "Severity:" line, and
    /// `PairwiseExportTests` pins both the positive form ("Severity: Notable gap") and the
    /// safety-critical negative one — that a withheld conclusion never prints
    /// "Severity: In agreement". That negative guarantee is only checkable if the exported
    /// phrase is fixed: a translated summary would let an insufficient-evidence export print
    /// some other language's word for agreement past the assertion. Keep this locale-free.
    var exportTitle: String {
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
