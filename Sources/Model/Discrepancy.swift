import Foundation
import SwiftUI

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
    /// Earliest start through latest end of the readings behind `value`.
    ///
    /// A window is a bucket the app imposed; this is when the device actually reported
    /// inside it. Nil when the contributing timestamps no longer exist, which is the case
    /// for a compacted median — unknown, and never to be replaced with the window bounds.
    var observedInterval: DateInterval? = nil
    /// Median of the contributing readings' midpoints: one representative instant for this
    /// source in this window, used to measure how far apart two sources actually were.
    /// Nil for the same reason as `observedInterval`.
    var representativeTime: Date? = nil

    var id: String { sourceID }
}

/// How well a paired observation supports the claim that both devices describe one moment.
///
/// Epoch-aligned bucketing pairs anything that lands in the same bucket, so two samples
/// 59 seconds apart can be paired while two samples 2 seconds apart across a boundary are
/// not. That is a deliberate, stable grid — but it means "paired" alone does not mean
/// "simultaneous", and the difference has to be visible rather than assumed.
enum PairTimingQuality: String, Hashable, Sendable, CaseIterable {
    /// Both sources reported within the metric's timing tolerance of each other.
    case simultaneous
    /// Both timestamps are known, and further apart than the tolerance allows.
    case separated
    /// At least one side's contributing timestamps are gone, so separation is unknowable.
    /// Deliberately distinct from `separated`: unknown is not evidence of either.
    case unknown
    /// The metric summarises a long interval (a daily resting rate, a VO2 max estimate),
    /// so a sub-window separation figure would be meaningless rather than merely unknown.
    case notApplicable

    /// Whether this observation should count toward a supported agreement conclusion.
    /// Only an affirmative timing check does; unknown does not qualify by default.
    var supportsConclusion: Bool {
        self == .simultaneous || self == .notApplicable
    }

    var title: String {
        switch self {
        case .simultaneous:
            String(localized: "pairTiming.simultaneous", defaultValue: "Simultaneous", comment: "Pair timing: both devices reported within the metric's timing tolerance")
        case .separated:
            String(localized: "pairTiming.separated", defaultValue: "Separated in time", comment: "Pair timing: the two devices reported further apart than the metric allows")
        case .unknown:
            String(localized: "pairTiming.unknown", defaultValue: "Timing unknown", comment: "Pair timing: a timestamp needed to judge the separation is no longer available")
        case .notApplicable:
            String(localized: "pairTiming.notApplicable", defaultValue: "Interval summary", comment: "Pair timing: the metric summarises a long interval, so a separation figure would be meaningless")
        }
    }
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
    /// How well this pair supports "both devices describe the same moment".
    var timing: PairTimingQuality = .unknown

    var id: String {
        "\(sourceA.sourceID)\u{001F}\(sourceB.sourceID)\u{001F}\(start.timeIntervalSinceReferenceDate.bitPattern)"
    }

    var end: Date { start.addingTimeInterval(duration) }

    /// Distance between the two sources' representative observation times. Nil when either
    /// side's contributing timestamps are unavailable.
    var timingSeparation: TimeInterval? {
        guard let a = sourceA.representativeTime, let b = sourceB.representativeTime else { return nil }
        return abs(a.timeIntervalSince(b))
    }

    /// Span actually covered by contributing readings, per source. Nil where unknown.
    var contributingDurationA: TimeInterval? { sourceA.observedInterval?.duration }
    var contributingDurationB: TimeInterval? { sourceB.observedInterval?.duration }
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

    var title: String {
        switch self {
        case .limited:
            String(localized: "evidenceGrade.limited", defaultValue: "Limited", comment: "Evidence grade for a device comparison: too little to conclude anything")
        case .weak:
            String(localized: "evidenceGrade.weak", defaultValue: "Weak", comment: "Evidence grade for a device comparison: enough windows, but with clear weaknesses")
        case .moderate:
            String(localized: "evidenceGrade.moderate", defaultValue: "Moderate", comment: "Evidence grade for a device comparison")
        case .strong:
            String(localized: "evidenceGrade.strong", defaultValue: "Strong", comment: "Evidence grade for a device comparison: many windows, good overlap and timing")
        }
    }
}

struct PairwiseEvidenceAssessment: Hashable, Sendable {
    var grade: PairwiseEvidenceGrade
    var hasUnknownSampleDepth: Bool
    var compactedWindowCount: Int
    var qualityCaveatCount: Int
    var reasons: [String]
    /// Paired windows whose two sources were further apart in time than the metric allows.
    /// They still contribute to the statistics — the paired set is not silently filtered —
    /// but they hold the evidence grade down and are named in `reasons`.
    var temporallySeparatedCount: Int = 0
    /// Paired windows where at least one side's contributing timestamps are gone, so the
    /// separation cannot be checked either way.
    var unknownTimingCount: Int = 0
    /// Median separation across the paired windows where both sides are known.
    var medianTimingSeparation: TimeInterval? = nil
    /// How much of the analyzed span the paired windows actually occupy, in `0...1`.
    /// Below 1 means the pair's shared coverage is sparse rather than continuous.
    var coverageFraction: Double? = nil

    /// Paired windows whose timing affirmatively supports a same-moment reading.
    func temporallySupportedCount(of pairedWindowCount: Int) -> Int {
        max(0, pairedWindowCount - temporallySeparatedCount - unknownTimingCount)
    }
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
    /// Pairs whose two sources are confirmed paths to the same upstream device.
    ///
    /// They remain fully inspectable — two paths disagreeing is a real sync problem worth
    /// seeing — but they are not two devices agreeing, so they must not inflate a count of
    /// independent corroboration.
    var sameDevicePairCount: Int = 0

    /// Real gaps the user's alert threshold keeps out of the detail list. They still block
    /// a green claim: choosing not to be told about a gap is not the same as agreement.
    var suppressedCount: Int { outsideToleranceCount - flaggedCount }

    /// - Parameter alertThreshold: the user's "flag disagreements at" preference. It
    ///   controls how much detail the overview lists, never `status`, so lowering the
    ///   alert level can hide a row but can never turn a real gap green.
    /// - Parameter sameDevicePairs: pair keys (`sourceA` + `sourceB`) the caller has
    ///   confirmed describe one upstream device through two transports. Passing them in
    ///   rather than looking them up keeps this type free of the source list.
    init(
        analyses: [PairwiseAnalysis],
        alertThreshold: DiscrepancySeverity = .agreeing,
        sameDevicePairs: Set<String> = []
    ) {
        let readyStatistics = analyses.compactMap(\.statistics)
        let outsideTolerance = readyStatistics.filter { $0.severity != .agreeing }

        self.sameDevicePairCount = analyses.count { sameDevicePairs.contains(Self.pairKey($0)) }
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

    /// Canonical key for one pair, matching `PairwiseAnalysis`'s ordering.
    static func pairKey(_ analysis: PairwiseAnalysis) -> String {
        "\(analysis.sourceA)\u{001F}\(analysis.sourceB)"
    }

    /// Pair keys for analyses whose two sources are confirmed paths to one upstream device.
    ///
    /// Uses the existing `upstreamDeviceRelationshipID` and its `describesSameDevice`
    /// rule; it never infers identity from similar names or models, so an unknown
    /// relationship stays unknown.
    static func sameDevicePairKeys(
        analyses: [PairwiseAnalysis],
        sources: [DataSource]
    ) -> Set<String> {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(
            analyses
                .filter { analysis in
                    guard let a = byID[analysis.sourceA], let b = byID[analysis.sourceB] else { return false }
                    return a.likelyRepresentsSameDevice(as: b)
                }
                .map(pairKey)
        )
    }
}
