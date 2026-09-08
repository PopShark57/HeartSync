import Foundation
import Testing
@testable import HeartSyncChecker

/// Whether paired readings actually describe the same time (improvement 20).
///
/// The pairing rule itself is unchanged: windows stay epoch-aligned and a pair is still the
/// intersection of two sources' occupied buckets. What these cover is the qualification of
/// that pairing — the timing separation the grid implies, and the fact that it is now
/// visible instead of assumed.
@Suite("Pair timing and coverage")
struct PairTimingTests {

    private func reading(_ sourceID: String, _ kind: MetricKind, _ value: Double, _ start: Date, duration: TimeInterval = 0) -> Reading {
        Reading(
            sourceID: sourceID,
            kind: kind,
            value: value,
            start: start,
            end: start.addingTimeInterval(duration)
        )
    }

    /// A fixed epoch-aligned minute boundary, so every case below is deterministic.
    ///
    /// Must be an exact multiple of 60: the comparison grid is anchored to the Unix epoch,
    /// so an unaligned anchor would put "same bucket" fixtures on opposite sides of a
    /// boundary and quietly test something else.
    private var boundary: Date { Date(timeIntervalSince1970: 1_699_999_980) }

    private func analysis(_ readings: [Reading], kind: MetricKind = .heartRate) -> PairwiseAnalysis {
        ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: kind,
            sourceA: "a",
            sourceB: "b",
            range: DateInterval(
                start: boundary.addingTimeInterval(-86_400),
                end: boundary.addingTimeInterval(86_400)
            ),
            minimumPairedWindows: 1
        )
    }

    // MARK: - Within one bucket

    @Test("Two samples nearly a minute apart in one bucket are marked separated, not simultaneous")
    func farSamplesInsideOneBucketAreSeparated() throws {
        let result = analysis([
            reading("a", .heartRate, 70, boundary.addingTimeInterval(1)),
            reading("b", .heartRate, 74, boundary.addingTimeInterval(58)),
        ])
        let observation = try #require(result.observations.first)

        // They are still paired — the grid is unchanged — but no longer look simultaneous.
        #expect(result.pairedWindowCount == 1)
        #expect(observation.timing == .separated)
        #expect(observation.timingSeparation == 57)
        #expect(result.evidence.temporallySeparatedCount == 1)
    }

    @Test("Two samples seconds apart in one bucket are simultaneous")
    func closeSamplesInsideOneBucketAreSimultaneous() throws {
        let result = analysis([
            reading("a", .heartRate, 70, boundary.addingTimeInterval(10)),
            reading("b", .heartRate, 71, boundary.addingTimeInterval(14)),
        ])
        let observation = try #require(result.observations.first)

        #expect(observation.timing == .simultaneous)
        #expect(observation.timingSeparation == 4)
        #expect(result.evidence.temporallySeparatedCount == 0)
    }

    // MARK: - Across a boundary

    @Test("Close samples split by a bucket boundary still do not pair, and the analysis says so")
    func closeSamplesAcrossABoundaryDoNotPair() {
        let result = analysis([
            reading("a", .heartRate, 70, boundary.addingTimeInterval(59)),
            reading("b", .heartRate, 71, boundary.addingTimeInterval(61)),
        ])

        // Two seconds apart, but on opposite sides of an epoch-aligned minute. The engine's
        // documented behaviour is unchanged; this pins it down rather than hiding it.
        #expect(result.pairedWindowCount == 0)
        #expect(result.observations.isEmpty)
        if case .noOverlap = result.state {} else {
            Issue.record("Expected noOverlap, got \(result.state)")
        }
    }

    // MARK: - Bursty delivery

    @Test("A burst is summarised by its median instant, not its first or last sample")
    func burstUsesMedianInstant() throws {
        // A delivers a tight burst early in the window; B reports once, late.
        var readings = [reading("b", .heartRate, 75, boundary.addingTimeInterval(50))]
        for offset in [2.0, 3.0, 4.0, 5.0, 6.0] {
            readings.append(reading("a", .heartRate, 70, boundary.addingTimeInterval(offset)))
        }
        let result = analysis(readings)
        let observation = try #require(result.observations.first)

        // Median of 2,3,4,5,6 is 4; B is at 50; separation is 46, beyond the 30s tolerance.
        #expect(observation.sourceA.representativeTime == boundary.addingTimeInterval(4))
        #expect(observation.timingSeparation == 46)
        #expect(observation.timing == .separated)
        // The contributing span is retained so the burst is visible as a burst.
        #expect(observation.contributingDurationA == 4)
        #expect(observation.contributingDurationB == 0)
    }

    // MARK: - Interval summaries

    @Test("Daily interval summaries report notApplicable rather than a meaningless separation")
    func intervalSummariesAreNotTimedAgainstEachOther() throws {
        // Resting heart rate is a property of a day; asking how many seconds apart two of
        // them were is not a meaningful question.
        #expect(MetricKind.restingHeartRate.isIntervalSummary)
        #expect(MetricKind.restingHeartRate.timingTolerance == nil)
        #expect(MetricKind.vo2Max.isIntervalSummary)
        #expect(MetricKind.heartRate.isIntervalSummary == false)
        #expect(MetricKind.heartRate.timingTolerance == 30)

        let day = Date(timeIntervalSince1970: 1_699_920_000)
        let result = analysis(
            [
                reading("a", .restingHeartRate, 52, day.addingTimeInterval(3_600)),
                reading("b", .restingHeartRate, 55, day.addingTimeInterval(50_000)),
            ],
            kind: .restingHeartRate
        )
        let observation = try #require(result.observations.first)

        #expect(observation.timing == .notApplicable)
        #expect(observation.timing.supportsConclusion)
        // Hours apart, but not counted as a timing failure, because the metric is a summary.
        #expect(result.evidence.temporallySeparatedCount == 0)
    }

    // MARK: - Unknown timing

    @Test("A compacted median has unknown timing, which is not treated as simultaneous")
    func compactedWindowsHaveUnknownTiming() throws {
        let compacted = Reading(
            id: UUID(),
            sourceID: "a",
            kind: .heartRate,
            value: 70,
            start: boundary,
            end: boundary.addingTimeInterval(60),
            provenance: .measured,
            metadata: ReadingMetadata(
                aggregation: AggregationMetadata(originalSampleCount: 60, originalStandardDeviation: 2)
            )
        )
        let result = analysis([compacted, reading("b", .heartRate, 71, boundary.addingTimeInterval(30))])
        let observation = try #require(result.observations.first)

        #expect(observation.sourceA.representativeTime == nil)
        #expect(observation.sourceA.observedInterval == nil)
        #expect(observation.timingSeparation == nil)
        #expect(observation.timing == .unknown)
        // Unknown is not evidence of coincidence, so it does not support a conclusion.
        #expect(observation.timing.supportsConclusion == false)
        #expect(result.evidence.unknownTimingCount == 1)
    }

    // MARK: - Evidence grading

    @Test("Simultaneous pairs still reach a strong grade")
    func simultaneousPairsStillGradeStrong() throws {
        var readings: [Reading] = []
        for index in 0..<32 {
            let timestamp = boundary.addingTimeInterval(Double(index) * 120)
            readings.append(reading("a", .heartRate, 70 + Double(index % 3), timestamp))
            readings.append(reading("b", .heartRate, 72 + Double(index % 2), timestamp))
        }
        let result = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: DateInterval(start: boundary.addingTimeInterval(-1), end: boundary.addingTimeInterval(4_100))
        )

        #expect(result.evidence.grade == .strong)
        #expect(result.evidence.temporallySeparatedCount == 0)
        #expect(result.evidence.medianTimingSeparation == 0)
    }

    @Test("A pair that never coincided cannot reach a strong grade")
    func separatedPairsCannotGradeStrong() throws {
        var readings: [Reading] = []
        for index in 0..<32 {
            // A multiple of the 60-second window, so each pair sits at the same place in
            // its bucket and the separation under test is the only thing that varies.
            let bucket = boundary.addingTimeInterval(Double(index) * 120)
            // A reports at the top of its bucket, B nearly a minute later, every time.
            readings.append(reading("a", .heartRate, 70, bucket.addingTimeInterval(1)))
            readings.append(reading("b", .heartRate, 71, bucket.addingTimeInterval(56)))
        }
        let result = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: DateInterval(start: boundary.addingTimeInterval(-1), end: boundary.addingTimeInterval(4_100))
        )

        #expect(result.evidence.grade != .strong)
        #expect(result.evidence.temporallySeparatedCount == result.pairedWindowCount)
        #expect(result.evidence.reasons.contains { $0.contains("too far apart in time") })
        // The statistics are still computed from every paired window: the evidence is
        // marked, not silently filtered.
        #expect(result.statistics != nil)
        #expect(result.pairedWindowCount == 32)
    }

    @Test("Sparse coverage is reported even when the window count is high")
    func sparseCoverageIsVisible() throws {
        // 12 paired minutes scattered across a whole day.
        var readings: [Reading] = []
        for index in 0..<12 {
            let timestamp = boundary.addingTimeInterval(Double(index) * 3_600)
            readings.append(reading("a", .heartRate, 70, timestamp))
            readings.append(reading("b", .heartRate, 71, timestamp))
        }
        let result = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: DateInterval(start: boundary.addingTimeInterval(-1), end: boundary.addingTimeInterval(90_000))
        )

        let coverage = try #require(result.evidence.coverageFraction)
        // 12 one-minute windows across ~11 hours is a fraction of a percent.
        #expect(coverage < 0.05)
        #expect(result.evidence.reasons.contains { $0.contains("cover only part") })
    }

    @Test("Canonical A-minus-B ordering and raw timestamps are unchanged")
    func canonicalOrderingAndTimestampsPreserved() throws {
        let readings = [
            reading("b", .heartRate, 80, boundary.addingTimeInterval(10)),
            reading("a", .heartRate, 70, boundary.addingTimeInterval(12)),
        ]
        let forward = analysis(readings)
        let reversed = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "b",
            sourceB: "a",
            range: DateInterval(start: boundary.addingTimeInterval(-60), end: boundary.addingTimeInterval(120)),
            minimumPairedWindows: 1
        )

        #expect(forward.sourceA == "a")
        #expect(reversed.sourceA == "a")
        let observation = try #require(forward.observations.first)
        #expect(observation.signedDifference == -10)
        // Timestamps are reported as observed; nothing was shifted to improve agreement.
        #expect(observation.sourceA.representativeTime == boundary.addingTimeInterval(12))
        #expect(observation.sourceB.representativeTime == boundary.addingTimeInterval(10))
    }
}
