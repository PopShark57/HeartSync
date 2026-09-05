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

/// One source's aggregated value inside a comparison window.
struct SourceValue: Identifiable, Hashable, Sendable {
    var sourceID: String
    var value: Double
    /// Number of raw samples that went into `value`. A one-sample average from a device
    /// that should be streaming is weak evidence, and the UI shows this.
    var sampleCount: Int?
    /// Spread of the samples inside the window. High spread means the device itself is
    /// unstable, which is a different problem from two devices disagreeing.
    var standardDeviation: Double?
    var provenance: Provenance
    var isCompacted: Bool = false
    var qualityCaveatCount: Int = 0

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

/// One epoch-aligned window in which exactly two selected sources both reported a metric.
///
/// `sourceA` and `sourceB` use the containing analysis's canonical source order. That makes
/// `signedDifference` stable even when callers request the devices in the opposite order.
struct PairwiseObservation: Identifiable, Hashable, Sendable {
    var start: Date
    var duration: TimeInterval
    var sourceA: SourceValue
    var sourceB: SourceValue
    var severity: DiscrepancySeverity

    var id: String {
        "\(sourceA.sourceID)\u{001F}\(sourceB.sourceID)\u{001F}\(start.timeIntervalSinceReferenceDate.bitPattern)"
    }

    var end: Date { start.addingTimeInterval(duration) }
    var pairedMean: Double { (sourceA.value + sourceB.value) / 2 }
    /// Signed device difference in the canonical direction, A minus B.
    var signedDifference: Double { sourceA.value - sourceB.value }
    var absoluteDifference: Double { abs(signedDifference) }
}

/// A descriptive reading of the difference pattern. This is deliberately not an
/// inferential claim and does not identify either source as medically correct.
enum PairwiseDifferenceClassification: String, Hashable, Sendable {
    case noApparentDifference
    case systematicBias
    case measurementNoise
}

/// Bland–Altman statistics exposed only after the evidence threshold is met.
struct PairwiseSummaryStatistics: Hashable, Sendable {
    var meanBias: Double
    var meanAbsoluteDifference: Double
    /// Sample standard deviation of paired differences (denominator `n - 1`).
    var differenceSD: Double
    var limitsOfAgreement: ClosedRange<Double>
    var severity: DiscrepancySeverity
    var classification: PairwiseDifferenceClassification
    var meanBiasConfidenceInterval: ClosedRange<Double>? = nil
    var lowerLimitConfidenceInterval: ClosedRange<Double>? = nil
    var upperLimitConfidenceInterval: ClosedRange<Double>? = nil
}

enum PairwiseEvidenceGrade: String, Hashable, Sendable {
    case limited
    case weak
    case moderate
    case strong

    var title: String { rawValue.capitalized }
}

struct PairwiseEvidenceAssessment: Hashable, Sendable {
    var grade: PairwiseEvidenceGrade
    var hasUnknownSampleDepth: Bool
    var compactedWindowCount: Int
    var qualityCaveatCount: Int
    var reasons: [String]
}

/// Evidence state for a selected metric and device pair.
enum PairwiseAnalysisState: Hashable, Sendable {
    /// Neither selected source shares an eligible epoch-aligned window with the other.
    case noOverlap
    /// Some overlap exists, but not enough to make an agreement claim.
    case collecting(pairedWindowCount: Int, requiredWindowCount: Int)
    /// Enough paired windows exist to expose descriptive summary statistics.
    case ready(PairwiseSummaryStatistics)
}

/// Complete, on-demand comparison of one metric from exactly two selected sources.
///
/// Candidate windows are the union of eligible windows from A and B; paired windows are
/// the intersection. `overlapPercentage` is therefore `paired / candidate * 100` and is
/// always in `0...100`. Estimated readings are excluded by the comparison engine.
struct PairwiseAnalysis: Identifiable, Hashable, Sendable {
    var kind: MetricKind
    /// Canonically ordered source identifier (lexicographically first).
    var sourceA: String
    /// Canonically ordered source identifier (lexicographically second).
    var sourceB: String
    /// Requested analysis range, even when the pair has no overlapping observations.
    var range: DateInterval
    var windowSize: TimeInterval
    var observations: [PairwiseObservation]
    var candidateWindowCount: Int
    var pairedWindowCount: Int
    /// Percentage in `0...100`, not a fractional ratio.
    var overlapPercentage: Double
    /// First paired-window start through last paired-window end; nil without overlap.
    var analyzedSpan: DateInterval?
    /// Raw samples from A and B that contributed to paired observations.
    var rawSampleCountA: Int?
    var rawSampleCountB: Int?
    var state: PairwiseAnalysisState
    var evidence: PairwiseEvidenceAssessment = PairwiseEvidenceAssessment(
        grade: .limited,
        hasUnknownSampleDepth: false,
        compactedWindowCount: 0,
        qualityCaveatCount: 0,
        reasons: []
    )

    var id: String {
        "\(kind.rawValue)\u{001F}\(sourceA)\u{001F}\(sourceB)\u{001F}\(range.start.timeIntervalSinceReferenceDate.bitPattern)\u{001F}\(range.end.timeIntervalSinceReferenceDate.bitPattern)\u{001F}\(windowSize.bitPattern)"
    }

    /// Convenience access to the ready-state statistics. Nil means the evidence threshold
    /// has not been met, not that the devices agree.
    var statistics: PairwiseSummaryStatistics? {
        guard case let .ready(statistics) = state else { return nil }
        return statistics
    }
}

extension PairwiseAnalysis {
    /// A drawable subset of `observations`, in chronological order.
    ///
    /// Swift Charts emits one mark per observation per series, and a 30-day range of a
    /// 60-second metric can pair tens of thousands of windows. Statistics, the evidence
    /// card, and the export always use every paired window — only the plotted set is
    /// thinned, and the widest differences are always kept, so thinning can never hide
    /// the outliers a Bland–Altman plot exists to show.
    ///
    /// - Parameters:
    ///   - limit: how many evenly spaced observations to sample. Non-positive returns none.
    ///   - extremes: how many of the observations furthest from the mean bias to keep on
    ///     top of the even sample.
    func plotSample(limit: Int, extremes: Int) -> [PairwiseObservation] {
        guard limit > 0 else { return [] }
        guard observations.count > limit else { return observations }

        let step = Double(observations.count) / Double(limit)
        var keep = Set((0..<limit).map { Int(Double($0) * step) })
        keep.insert(observations.count - 1)

        if extremes > 0 {
            let bias = statistics?.meanBias ?? 0
            keep.formUnion(
                observations.indices
                    .sorted {
                        abs(observations[$0].signedDifference - bias)
                            > abs(observations[$1].signedDifference - bias)
                    }
                    .prefix(extremes)
            )
        }

        return keep.sorted().map { observations[$0] }
    }
}

/// The evidence-level decision used by the Compare overview.
///
/// Keeping this rule outside the view makes the important negative guarantee testable:
/// collecting or no-overlap pairs can never be translated into a green agreement state.
enum PairwiseEvidenceOverviewStatus: Hashable, Sendable {
    case insufficientEvidence
    case allReadyPairsWithinTolerance
    case readyPairOutsideTolerance
}

struct PairwiseEvidenceOverview: Hashable, Sendable {
    var status: PairwiseEvidenceOverviewStatus
    var readyCount: Int
    var incompleteCount: Int
    /// Ready pairs whose mean absolute difference exceeds the metric's fixed tolerance.
    var outsideToleranceCount: Int
    /// Of those, the ones at or above the user's alert threshold — the pairs shown in full.
    var flaggedCount: Int

    /// Real gaps the user's alert threshold keeps out of the detail list. They still block
    /// a green claim: choosing not to be told about a gap is not the same as agreement.
    var suppressedCount: Int { outsideToleranceCount - flaggedCount }

    /// - Parameter alertThreshold: the user's "flag disagreements at" preference. It
    ///   controls how much detail the overview lists, never `status`, so lowering the
    ///   alert level can hide a row but can never turn a real gap green.
    init(analyses: [PairwiseAnalysis], alertThreshold: DiscrepancySeverity = .agreeing) {
        let readyStatistics = analyses.compactMap(\.statistics)
        let outsideTolerance = readyStatistics.filter { $0.severity != .agreeing }

        self.readyCount = readyStatistics.count
        self.incompleteCount = analyses.count - readyStatistics.count
        self.outsideToleranceCount = outsideTolerance.count
        self.flaggedCount = outsideTolerance.count { $0.severity >= alertThreshold }

        if readyStatistics.isEmpty {
            status = .insufficientEvidence
        } else if outsideTolerance.isEmpty {
            status = .allReadyPairsWithinTolerance
        } else {
            status = .readyPairOutsideTolerance
        }
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
