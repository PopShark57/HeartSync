import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("HRV")
struct HRVTests {

    @Test("A perfectly regular rhythm has zero variability")
    func regularRhythm() throws {
        let metrics = try #require(HRVCalculator.metrics(from: Array(repeating: 800.0, count: 30)))
        #expect(metrics.rmssd == 0)
        #expect(metrics.sdnn == 0)
        #expect(abs(metrics.meanHeartRate - 75) < 1e-9)   // 60000 / 800
    }

    @Test("RMSSD and SDNN match hand-computed values")
    func knownValues() throws {
        // Alternating 800/850: successive differences are all \u{00B1}50, so RMSSD is exactly 50.
        // Mean is 825 and every value sits 25 away, so SDNN is exactly 25.
        let intervals = (0..<40).map { $0.isMultiple(of: 2) ? 800.0 : 850.0 }
        let metrics = try #require(HRVCalculator.metrics(from: intervals))
        #expect(abs(metrics.rmssd - 50) < 1e-9)
        #expect(abs(metrics.sdnn - 25) < 1e-9)
        // pNN50 counts differences strictly greater than 50 ms, so exactly 50 does not count.
        #expect(metrics.pnn50 == 0)
    }

    @Test("Intervals outside the physiological range are discarded")
    func rejectsImpossibleIntervals() throws {
        var intervals = Array(repeating: 800.0, count: 30)
        intervals.append(2500)   // 24 bpm \u{2014} a dropped beat, not a heartbeat
        intervals.append(150)    // 400 bpm \u{2014} a doubled detection
        let (clean, rejected) = HRVCalculator.filterArtefacts(intervals)
        #expect(rejected == 2)
        #expect(clean.count == 30)
    }

    @Test("A single ectopic beat does not inflate RMSSD")
    func rejectsEctopicBeat() throws {
        let clean = Array(repeating: 800.0, count: 40)
        var withEctopic = clean
        withEctopic.insert(400, at: 20)   // in range, but a 50% jump from its neighbours

        let baseline = try #require(HRVCalculator.metrics(from: clean))
        let contaminated = try #require(HRVCalculator.metrics(from: withEctopic))
        // Without relative filtering this single beat would push RMSSD from 0 to ~90 ms.
        #expect(contaminated.rmssd == baseline.rmssd)
        #expect(contaminated.artefactFraction > 0)
    }

    @Test("Too few clean beats is reported as unreliable rather than as a number")
    func unreliableBelowMinimumBeats() throws {
        let metrics = try #require(HRVCalculator.metrics(from: [800, 850, 800, 820, 830]))
        #expect(!metrics.isReliable)
    }

    @Test("The accumulator waits for enough beats before emitting")
    func accumulatorGating() {
        var accumulator = HRVAccumulator()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        accumulator.add(intervals: Array(repeating: 800.0, count: 5), at: start)
        #expect(accumulator.emitIfReady(at: start) == nil)

        accumulator.add(intervals: (0..<40).map { $0.isMultiple(of: 2) ? 800.0 : 850.0 },
                        at: start.addingTimeInterval(30))
        let emitted = accumulator.emitIfReady(at: start.addingTimeInterval(30))
        #expect(emitted != nil)

        // The emit interval throttles the next one.
        #expect(accumulator.emitIfReady(at: start.addingTimeInterval(31)) == nil)
    }

    @Test("Intervals older than the window are dropped")
    func accumulatorWindowing() {
        var accumulator = HRVAccumulator()
        accumulator.window = 60
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        accumulator.add(intervals: Array(repeating: 800.0, count: 10), at: start)
        accumulator.add(intervals: Array(repeating: 800.0, count: 10), at: start.addingTimeInterval(120))
        #expect(accumulator.bufferedBeats == 10)
    }
}

@Suite("Comparison engine")
struct ComparisonEngineTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func reading(
        _ source: String,
        _ value: Double,
        offset: TimeInterval,
        kind: MetricKind = .heartRate,
        provenance: Provenance = .measured
    ) -> Reading {
        Reading(
            sourceID: source,
            kind: kind,
            value: value,
            start: epoch.addingTimeInterval(offset),
            provenance: provenance
        )
    }

    @Test("Samples from different devices land in the same window")
    func windowAlignment() {
        // Heart rate buckets at 60 s; both samples sit inside the same epoch-aligned bucket.
        let windows = ComparisonEngine.windows(
            from: [reading("a", 70, offset: 0), reading("b", 78, offset: 10)],
            kind: .heartRate
        )
        #expect(windows.count == 1)
        #expect(windows[0].values.count == 2)
        #expect(windows[0].spread == 8)
        #expect(windows[0].severity == .notable)   // warn 5, alert 12
    }

    @Test("Window boundaries are anchored to the epoch, not to the first sample")
    func windowBoundariesAreStable() {
        // Same data offset by an hour must produce the same grid, so repeated refreshes
        // do not shuffle points between buckets.
        let a = ComparisonEngine.windows(from: [reading("a", 70, offset: 0)], kind: .heartRate)
        let b = ComparisonEngine.windows(from: [reading("a", 70, offset: 3600)], kind: .heartRate)
        #expect(a[0].start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
        #expect(b[0].start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
    }

    @Test("A single motion spike does not manufacture a discrepancy")
    func medianResistsSpikes() {
        // Source b reports 70 five times plus one 180 bpm artefact. A mean would give 88
        // and flag a major gap; the median gives 70 and correctly reports agreement.
        var readings = [reading("a", 70, offset: 0)]
        readings += (0..<5).map { reading("b", 70, offset: Double($0) * 2) }
        readings.append(reading("b", 180, offset: 12))

        let windows = ComparisonEngine.windows(from: readings, kind: .heartRate)
        #expect(windows.count == 1)
        #expect(windows[0].spread == 0)
        #expect(windows[0].severity == .agreeing)
    }

    @Test("Implausible values never reach the comparison")
    func rejectsImplausibleValues() {
        let windows = ComparisonEngine.windows(
            from: [reading("a", 70, offset: 0), reading("b", 400, offset: 5)],
            kind: .heartRate
        )
        #expect(windows[0].values.count == 1)
    }

    @Test("Estimated values are excluded from comparison unless asked for")
    func excludesEstimatesByDefault() {
        let readings = [
            reading("a", 45, offset: 0, kind: .vo2Max),
            reading("b", 52, offset: 0, kind: .vo2Max, provenance: .estimated),
        ]
        #expect(ComparisonEngine.windows(from: readings, kind: .vo2Max)[0].values.count == 1)
        #expect(ComparisonEngine.windows(from: readings, kind: .vo2Max, includeEstimated: true)[0].values.count == 2)
    }

    @Test("A consistent offset is reported as systematic bias")
    func detectsSystematicBias() throws {
        // Six windows where a reads 8 bpm below b, every time.
        var readings: [Reading] = []
        for index in 0..<6 {
            let offset = Double(index) * 60
            readings.append(reading("a", 70, offset: offset))
            readings.append(reading("b", 78, offset: offset + 5))
        }
        let found = ComparisonEngine.discrepancies(from: readings, kind: .heartRate)
        let discrepancy = try #require(found.first)

        #expect(discrepancy.windowCount == 6)
        #expect(abs(discrepancy.meanBias + 8) < 1e-9)          // a minus b
        #expect(abs(discrepancy.meanAbsoluteDifference - 8) < 1e-9)
        #expect(discrepancy.differenceSD == 0)
        #expect(discrepancy.isSystematicBias)
        #expect(discrepancy.severity == .notable)
    }

    @Test("Alternating differences are reported as noise, not bias")
    func detectsNoise() throws {
        var readings: [Reading] = []
        for index in 0..<8 {
            let offset = Double(index) * 60
            readings.append(reading("a", 70, offset: offset))
            readings.append(reading("b", index.isMultiple(of: 2) ? 78 : 62, offset: offset + 5))
        }
        let discrepancy = try #require(ComparisonEngine.discrepancies(from: readings, kind: .heartRate).first)
        #expect(abs(discrepancy.meanBias) < 1e-9)              // cancels out
        #expect(abs(discrepancy.meanAbsoluteDifference - 8) < 1e-9)
        #expect(!discrepancy.isSystematicBias)
    }

    @Test("A pair needs enough overlapping windows before it is called a disagreement")
    func requiresEnoughPairedWindows() {
        var readings: [Reading] = []
        for index in 0..<3 {
            let offset = Double(index) * 60
            readings.append(reading("a", 70, offset: offset))
            readings.append(reading("b", 90, offset: offset + 5))
        }
        // Three coincidences are not a pattern.
        #expect(ComparisonEngine.discrepancies(from: readings, kind: .heartRate).isEmpty)
    }

    @Test("Pair keys are canonical, so A\u{2013}B and B\u{2013}A are one relationship")
    func canonicalPairing() {
        var readings: [Reading] = []
        for index in 0..<6 {
            let offset = Double(index) * 60
            // Deliberately alternate insertion order.
            if index.isMultiple(of: 2) {
                readings.append(reading("zulu", 78, offset: offset))
                readings.append(reading("alpha", 70, offset: offset + 5))
            } else {
                readings.append(reading("alpha", 70, offset: offset))
                readings.append(reading("zulu", 78, offset: offset + 5))
            }
        }
        let found = ComparisonEngine.discrepancies(from: readings, kind: .heartRate)
        #expect(found.count == 1)
        #expect(found[0].sourceA == "alpha")
        #expect(found[0].sourceB == "zulu")
    }

    @Test("Pairwise analysis reports no overlap without calling it agreement")
    func pairwiseNoOverlap() {
        let readings = [
            reading("alpha", 70, offset: 0),
            reading("alpha", 71, offset: 60),
            reading("bravo", 72, offset: 120),
            reading("bravo", 73, offset: 180),
        ]
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(300)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )

        #expect(analysis.state == .noOverlap)
        #expect(analysis.candidateWindowCount == 4)
        #expect(analysis.pairedWindowCount == 0)
        #expect(analysis.overlapPercentage == 0)
        #expect(analysis.analyzedSpan == nil)
        #expect(analysis.statistics == nil)
    }

    @Test("Overlap is paired windows divided by the union of candidate windows")
    func pairwisePartialOverlap() {
        var readings: [Reading] = []
        for index in 0..<3 {
            readings.append(reading("alpha", 70, offset: Double(index) * 60))
        }
        for index in 1..<4 {
            readings.append(reading("bravo", 72, offset: Double(index) * 60))
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(300)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )

        #expect(analysis.candidateWindowCount == 4)
        #expect(analysis.pairedWindowCount == 2)
        #expect(abs(analysis.overlapPercentage - 50) < 1e-9)
        #expect(analysis.state == .collecting(pairedWindowCount: 2, requiredWindowCount: 5))
        #expect(analysis.rawSampleCountA == 2)
        #expect(analysis.rawSampleCountB == 2)
    }

    @Test("Five paired windows unlock ready Bland-Altman statistics")
    func pairwiseReadiness() throws {
        var readings: [Reading] = []
        for index in 0..<5 {
            let offset = Double(index) * 60
            readings.append(reading("alpha", 70, offset: offset))
            readings.append(reading("bravo", 78, offset: offset + 5))
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        let statistics = try #require(analysis.statistics)

        #expect(analysis.pairedWindowCount == 5)
        #expect(abs(analysis.overlapPercentage - 100) < 1e-9)
        #expect(statistics.meanBias == -8)
        #expect(statistics.meanAbsoluteDifference == 8)
        #expect(statistics.differenceSD == 0)
        #expect(statistics.limitsOfAgreement == -8 ... -8)
        #expect(statistics.severity == .notable)
        #expect(statistics.classification == .systematicBias)
        if case .ready = analysis.state {
            // Expected.
        } else {
            Issue.record("Five paired windows must produce the ready state")
        }
    }

    @Test("Canonical source ordering also fixes the sign of each observation")
    func pairwiseCanonicalSign() throws {
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(120)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: [reading("zulu", 80, offset: 0), reading("alpha", 70, offset: 5)],
            kind: .heartRate,
            sourceA: "zulu",
            sourceB: "alpha",
            range: range,
            minimumPairedWindows: 1
        )
        let observation = try #require(analysis.observations.first)

        #expect(analysis.sourceA == "alpha")
        #expect(analysis.sourceB == "zulu")
        #expect(observation.sourceA.sourceID == "alpha")
        #expect(observation.sourceB.sourceID == "zulu")
        #expect(observation.signedDifference == -10)
        #expect(observation.absoluteDifference == 10)
        #expect(observation.pairedMean == 75)
    }

    @Test("Estimated readings cannot create pairwise evidence")
    func pairwiseExcludesEstimates() {
        var readings: [Reading] = []
        for index in 0..<5 {
            let offset = Double(index) * 60
            readings.append(reading("alpha", 70, offset: offset))
            let provenance: Provenance = index < 2 ? .measured : .estimated
            readings.append(reading("bravo", 72, offset: offset + 5, provenance: provenance))
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )

        #expect(analysis.candidateWindowCount == 5)
        #expect(analysis.pairedWindowCount == 2)
        #expect(analysis.state == .collecting(pairedWindowCount: 2, requiredWindowCount: 5))
        #expect(analysis.observations.allSatisfy {
            $0.sourceA.provenance != .estimated && $0.sourceB.provenance != .estimated
        })
    }

    @Test("Pair observations retain median aggregates, unequal counts, and within-window spread")
    func pairwiseObservationEvidence() throws {
        let readings = [
            reading("alpha", 60, offset: 0),
            reading("alpha", 70, offset: 5),
            reading("alpha", 80, offset: 10),
            reading("bravo", 73, offset: 1),
            reading("bravo", 73, offset: 6),
            reading("bravo", 73, offset: 11),
            reading("bravo", 200, offset: 16),
        ]
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(60)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range,
            minimumPairedWindows: 1
        )
        let observation = try #require(analysis.observations.first)

        #expect(observation.sourceA.value == 70)
        #expect(observation.sourceA.sampleCount == 3)
        let sourceASpread = try #require(observation.sourceA.standardDeviation)
        #expect(abs(sourceASpread - sqrt(200.0 / 3.0)) < 1e-9)
        #expect(observation.sourceB.value == 73)
        #expect(observation.sourceB.sampleCount == 4)
        #expect(try #require(observation.sourceB.standardDeviation) > 0)
        #expect(analysis.rawSampleCountA == 3)
        #expect(analysis.rawSampleCountB == 4)
        #expect(observation.signedDifference == -3)
    }

    @Test("Difference spread and limits of agreement use sample variance")
    func pairwiseUsesSampleVariance() throws {
        var readings: [Reading] = []
        for index in 0..<5 {
            let offset = Double(index) * 60
            readings.append(reading("alpha", 71 + Double(index), offset: offset))
            readings.append(reading("bravo", 70, offset: offset + 5))
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        let statistics = try #require(analysis.statistics)
        let expectedSD = sqrt(2.5) // sample variance of 1, 2, 3, 4, 5

        #expect(abs(statistics.meanBias - 3) < 1e-9)
        #expect(abs(statistics.differenceSD - expectedSD) < 1e-9)
        #expect(abs(statistics.limitsOfAgreement.lowerBound - (3 - 1.96 * expectedSD)) < 1e-9)
        #expect(abs(statistics.limitsOfAgreement.upperBound - (3 + 1.96 * expectedSD)) < 1e-9)
    }

    @Test("All-pair queries enumerate every canonical pair, including no-overlap pairs")
    func allPairwiseEnumeration() {
        let readings = [
            reading("charlie", 72, offset: 0),
            reading("alpha", 70, offset: 0),
            reading("bravo", 71, offset: 60),
        ]
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(180)
        )
        let analyses = ComparisonEngine.allPairwiseAnalyses(
            from: readings,
            kind: .heartRate,
            range: range
        )

        #expect(analyses.map { [$0.sourceA, $0.sourceB] } == [
            ["alpha", "bravo"],
            ["alpha", "charlie"],
            ["bravo", "charlie"],
        ])
        #expect(analyses.count == 3)
        #expect(analyses.filter { $0.state == .noOverlap }.count == 2)
    }

    @Test("Compare overview never translates insufficient evidence into agreement")
    func compareOverviewRequiresReadyEvidence() {
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let noOverlap = ComparisonEngine.pairwiseAnalysis(
            from: [
                reading("alpha", 70, offset: 0),
                reading("bravo", 70, offset: 120),
            ],
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        let collecting = ComparisonEngine.pairwiseAnalysis(
            from: [
                reading("charlie", 70, offset: 0),
                reading("delta", 70, offset: 5),
            ],
            kind: .heartRate,
            sourceA: "charlie",
            sourceB: "delta",
            range: range
        )

        let overview = PairwiseEvidenceOverview(analyses: [noOverlap, collecting])

        #expect(overview.status == .insufficientEvidence)
        #expect(overview.readyCount == 0)
        #expect(overview.incompleteCount == 2)
        #expect(overview.outsideToleranceCount == 0)
    }

    @Test("Compare overview turns green only after a ready pair is within tolerance")
    func compareOverviewGreenGate() {
        var agreeingReadings: [Reading] = []
        var notableReadings: [Reading] = []
        for index in 0..<5 {
            let offset = Double(index) * 60
            agreeingReadings += [
                reading("alpha", 70, offset: offset),
                reading("bravo", 71, offset: offset + 5),
            ]
            notableReadings += [
                reading("charlie", 70, offset: offset),
                reading("delta", 78, offset: offset + 5),
            ]
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let agreeing = ComparisonEngine.pairwiseAnalysis(
            from: agreeingReadings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        let notable = ComparisonEngine.pairwiseAnalysis(
            from: notableReadings,
            kind: .heartRate,
            sourceA: "charlie",
            sourceB: "delta",
            range: range
        )

        #expect(PairwiseEvidenceOverview(analyses: [agreeing]).status == .allReadyPairsWithinTolerance)
        #expect(PairwiseEvidenceOverview(analyses: [agreeing, notable]).status == .readyPairOutsideTolerance)
    }

    @Test("The alert threshold hides detail rows but can never produce a green result")
    func compareOverviewThresholdCannotManufactureAgreement() {
        var notableReadings: [Reading] = []
        var majorReadings: [Reading] = []
        for index in 0..<5 {
            let offset = Double(index) * 60
            notableReadings += [
                reading("alpha", 70, offset: offset),
                reading("bravo", 78, offset: offset + 5),   // 8 bpm: notable, below alert 12
            ]
            majorReadings += [
                reading("charlie", 70, offset: offset),
                reading("delta", 90, offset: offset + 5),   // 20 bpm: major
            ]
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let notable = ComparisonEngine.pairwiseAnalysis(
            from: notableReadings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        let major = ComparisonEngine.pairwiseAnalysis(
            from: majorReadings,
            kind: .heartRate,
            sourceA: "charlie",
            sourceB: "delta",
            range: range
        )

        // "Major only" must not turn the notable pair into agreement — it may only stop
        // listing it, and the pair still has to be accounted for.
        let majorOnly = PairwiseEvidenceOverview(analyses: [notable], alertThreshold: .major)
        #expect(majorOnly.status == .readyPairOutsideTolerance)
        #expect(majorOnly.outsideToleranceCount == 1)
        #expect(majorOnly.flaggedCount == 0)
        #expect(majorOnly.suppressedCount == 1)

        let everything = PairwiseEvidenceOverview(analyses: [notable], alertThreshold: .agreeing)
        #expect(everything.flaggedCount == 1)
        #expect(everything.suppressedCount == 0)

        let mixed = PairwiseEvidenceOverview(analyses: [notable, major], alertThreshold: .major)
        #expect(mixed.status == .readyPairOutsideTolerance)
        #expect(mixed.flaggedCount == 1)
        #expect(mixed.suppressedCount == 1)
    }

    @Test("A threshold cannot suppress a pair that is within tolerance")
    func compareOverviewAgreeingPairIsNeverSuppressed() {
        var readings: [Reading] = []
        for index in 0..<5 {
            let offset = Double(index) * 60
            readings += [
                reading("alpha", 70, offset: offset),
                reading("bravo", 71, offset: offset + 5),
            ]
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(360)
        )
        let agreeing = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        let overview = PairwiseEvidenceOverview(analyses: [agreeing], alertThreshold: .major)

        #expect(overview.status == .allReadyPairsWithinTolerance)
        #expect(overview.outsideToleranceCount == 0)
        #expect(overview.flaggedCount == 0)
        #expect(overview.suppressedCount == 0)
    }

    @Test("Bucketing by metric does not change the all-metric pair enumeration")
    func allMetricPairwiseMatchesPerMetricQueries() {
        var readings: [Reading] = []
        for index in 0..<6 {
            let offset = Double(index) * 60
            readings += [
                reading("alpha", 70, offset: offset),
                reading("bravo", 76, offset: offset + 5),
                reading("alpha", 97, offset: offset, kind: .spo2),
                reading("bravo", 95, offset: offset + 5, kind: .spo2),
                reading("charlie", 36.9, offset: offset, kind: .bodyTemperature),
            ]
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(600)
        )
        let all = ComparisonEngine.allPairwiseAnalyses(from: readings, range: range)
        let perMetric = MetricKind.allCases.flatMap {
            ComparisonEngine.allPairwiseAnalyses(from: readings, kind: $0, range: range)
        }

        #expect(all == perMetric)
        // Body temperature has a single source, so it contributes no pair at all.
        #expect(all.map(\.kind) == [.heartRate, .spo2])
    }

    @Test("Chart thinning bounds the plotted set without hiding the widest differences")
    func plotSampleKeepsOutliers() throws {
        var readings: [Reading] = []
        for index in 0..<400 {
            let offset = Double(index) * 60
            readings.append(reading("alpha", 70, offset: offset))
            // One window disagrees far more than the rest; it must survive thinning.
            readings.append(reading("bravo", index == 137 ? 110 : 71, offset: offset + 5))
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(400 * 60)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )
        #expect(analysis.observations.count == 400)

        let sampled = analysis.plotSample(limit: 50, extremes: 5)
        let widest = try #require(analysis.observations.max { abs($0.signedDifference) < abs($1.signedDifference) })

        #expect(sampled.count <= 50 + 5 + 1)
        #expect(sampled.count < analysis.observations.count)
        #expect(sampled.contains(widest))
        #expect(sampled.first == analysis.observations.first)
        #expect(sampled.last == analysis.observations.last)
        #expect(sampled == sampled.sorted { $0.start < $1.start })
        #expect(Set(sampled.map(\.id)).count == sampled.count)
    }

    @Test("A set small enough to draw is never thinned")
    func plotSamplePassesSmallSetsThrough() {
        var readings: [Reading] = []
        for index in 0..<6 {
            let offset = Double(index) * 60
            readings.append(reading("alpha", 70, offset: offset))
            readings.append(reading("bravo", 71, offset: offset + 5))
        }
        let range = DateInterval(
            start: epoch.addingTimeInterval(-1),
            end: epoch.addingTimeInterval(600)
        )
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "alpha",
            sourceB: "bravo",
            range: range
        )

        #expect(analysis.plotSample(limit: 500, extremes: 60) == analysis.observations)
        #expect(analysis.plotSample(limit: 0, extremes: 60).isEmpty)
    }

    @Test("Stale readings are not presented as current")
    func latestBySourceDropsStale() {
        let now = epoch.addingTimeInterval(3600)
        let readings = [
            reading("a", 70, offset: 3595),   // 5 s old
            reading("b", 70, offset: 0),      // an hour old
        ]
        let latest = ComparisonEngine.latestBySource(from: readings, kind: .heartRate, now: now, staleAfter: 900)
        #expect(latest.keys.sorted() == ["a"])
    }
}

@Suite("Estimators")
struct EstimatorTests {

    @Test("VO2 max follows the Uth\u{2013}S\u{00F8}rensen ratio")
    func vo2MaxFormula() throws {
        let value = try #require(Estimators.vo2Max(restingHeartRate: 60, maxHeartRate: 190))
        #expect(abs(value - 15.3 * 190 / 60) < 1e-9)
    }

    @Test("VO2 max refuses nonsensical inputs")
    func vo2MaxGuards() {
        #expect(Estimators.vo2Max(restingHeartRate: 0, maxHeartRate: 190) == nil)
        #expect(Estimators.vo2Max(restingHeartRate: 190, maxHeartRate: 190) == nil)
        // A very low resting HR would push the estimate past the plausible ceiling.
        #expect(Estimators.vo2Max(restingHeartRate: 30, maxHeartRate: 200) == nil)
    }

    private func calibration(
        systolic: Double = 120,
        diastolic: Double = 80,
        restingHR: Double = 60,
        rmssd: Double? = 40,
        takenAt: Date = .now
    ) -> UserProfile.BPCalibration {
        .init(systolic: systolic, diastolic: diastolic,
              referenceRestingHR: restingHR, referenceRMSSD: rmssd, takenAt: takenAt)
    }

    @Test("At the calibration point the estimate returns the cuff reading")
    func bloodPressureAtAnchor() throws {
        let estimate = try #require(Estimators.bloodPressure(
            calibration: calibration(), currentHeartRate: 60, currentRMSSD: 40
        ))
        #expect(abs(estimate.systolic - 120) < 1e-9)
        #expect(abs(estimate.diastolic - 80) < 1e-9)
    }

    @Test("Heart rate drift moves the estimate by the documented slope")
    func bloodPressureSlope() throws {
        let estimate = try #require(Estimators.bloodPressure(
            calibration: calibration(), currentHeartRate: 80, currentRMSSD: 40
        ))
        #expect(abs(estimate.systolic - (120 + 20 * 0.35)) < 1e-9)
        #expect(abs(estimate.diastolic - (80 + 20 * 0.20)) < 1e-9)
    }

    @Test("The model refuses to extrapolate far from its anchor")
    func bloodPressureRefusesExtrapolation() {
        #expect(Estimators.bloodPressure(
            calibration: calibration(), currentHeartRate: 110, currentRMSSD: 40
        ) == nil)
    }

    @Test("An expired calibration produces nothing")
    func bloodPressureExpires() {
        let old = Date.now.addingTimeInterval(-40 * 86_400)
        #expect(Estimators.bloodPressure(
            calibration: calibration(takenAt: old), currentHeartRate: 60, currentRMSSD: 40
        ) == nil)
    }

    @Test("Drift is clamped so the estimate never wanders far from the cuff reading")
    func bloodPressureClamped() throws {
        // Maximum allowed HR deviation plus a collapsed HRV, the worst case the model
        // accepts, must still stay inside the documented clamp.
        let estimate = try #require(Estimators.bloodPressure(
            calibration: calibration(), currentHeartRate: 85, currentRMSSD: 1
        ))
        #expect(estimate.systolic - 120 <= Estimators.maxSystolicDrift + 1e-9)
        #expect(estimate.diastolic - 80 <= Estimators.maxDiastolicDrift + 1e-9)
    }

    @Test("The interval widens as the calibration ages")
    func bloodPressureMarginWidens() throws {
        let fresh = try #require(Estimators.bloodPressure(
            calibration: calibration(takenAt: .now), currentHeartRate: 60, currentRMSSD: 40
        ))
        let old = try #require(Estimators.bloodPressure(
            calibration: calibration(takenAt: .now.addingTimeInterval(-25 * 86_400)),
            currentHeartRate: 60, currentRMSSD: 40
        ))
        #expect(old.systolicMargin > fresh.systolicMargin)
    }
}

@Suite("Oura mapping")
struct OuraMappingTests {

    @Test("Heart rate points map to readings with stable ids")
    func heartRateMapping() throws {
        let points = [
            OuraClient.HeartRatePoint(bpm: 62, source: "rest", timestamp: "2026-08-29T10:00:00+00:00"),
            OuraClient.HeartRatePoint(bpm: 64, source: "rest", timestamp: "2026-08-29T10:05:00+00:00"),
        ]
        let first = OuraManager.readings(fromHeartRate: points)
        let second = OuraManager.readings(fromHeartRate: points)
        #expect(first.count == 2)
        // Re-fetching an overlapping window must not duplicate readings.
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first[0].kind == .heartRate)
        #expect(first[0].value == 62)
    }

    @Test("Oura's average HRV maps to RMSSD, never SDNN")
    func sleepMapsHRVToRMSSD() throws {
        let document = OuraClient.SleepDocument(
            id: "abc", day: "2026-08-29",
            bedtime_start: "2026-08-28T23:00:00+00:00",
            bedtime_end: "2026-08-29T07:00:00+00:00",
            average_hrv: 45, average_heart_rate: 58,
            lowest_heart_rate: 52, average_breath: 14.5
        )
        let readings = OuraManager.readings(fromSleep: [document])
        let kinds = Set(readings.map(\.kind))
        // Mapping it to SDNN would place it beside the Apple Watch's SDNN, which is a
        // different measure \u{2014} the resulting "discrepancy" would be pure artefact.
        #expect(kinds.contains(.hrvRMSSD))
        #expect(!kinds.contains(.hrvSDNN))
        #expect(kinds.contains(.restingHeartRate))
        #expect(kinds.contains(.respiratoryRate))
    }

    @Test("Missing optional fields are skipped rather than defaulted")
    func sleepSkipsMissingFields() {
        let document = OuraClient.SleepDocument(
            id: "abc", day: "2026-08-29",
            bedtime_start: "2026-08-28T23:00:00+00:00",
            bedtime_end: "2026-08-29T07:00:00+00:00",
            average_hrv: nil, average_heart_rate: nil,
            lowest_heart_rate: 52, average_breath: nil
        )
        let readings = OuraManager.readings(fromSleep: [document])
        #expect(readings.count == 1)
        #expect(readings[0].kind == .restingHeartRate)
    }

    @Test("Fractional-second timestamps parse")
    func timestampParsing() {
        #expect(OuraClient.parseTimestamp("2026-08-29T10:00:00+00:00") != nil)
        #expect(OuraClient.parseTimestamp("2026-08-29T10:00:00.123+00:00") != nil)
        #expect(OuraClient.parseTimestamp("not a date") == nil)
    }
}

#if DEBUG
/// The demo archive exists so the pair screen's states can be reviewed without wearing two
/// devices. If it silently stopped producing one of them, the visual QA it is meant to
/// support would quietly stop covering that state.
@Suite("Debug analysis fixtures")
@MainActor
struct DebugAnalysisFixtureTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixtureAnalysis(_ kind: MetricKind) -> PairwiseAnalysis {
        let store = HealthStore(persistenceEnabled: false)
        DebugAnalysisFixtures.populate(store: store, now: now)
        let range = DateInterval(
            start: now.addingTimeInterval(-86_400),
            end: now.addingTimeInterval(60)
        )
        return ComparisonEngine.pairwiseAnalysis(
            from: store.readings(kind: kind, in: range),
            kind: kind,
            sourceA: DebugAnalysisFixtures.sourceAID,
            sourceB: DebugAnalysisFixtures.sourceBID,
            range: range
        )
    }

    @Test("The two demo devices are distinguishable in charts")
    func demoSourcesAreDistinct() throws {
        let store = HealthStore(persistenceEnabled: false)
        DebugAnalysisFixtures.populate(store: store, now: now)

        let a = try #require(store.source(id: DebugAnalysisFixtures.sourceAID))
        let b = try #require(store.source(id: DebugAnalysisFixtures.sourceBID))
        #expect(a.colorIndex != b.colorIndex)

        // Populating twice must not double every reading.
        let before = store.readings(kind: .heartRate).count
        DebugAnalysisFixtures.populate(store: store, now: now)
        #expect(store.readings(kind: .heartRate).count == before)
    }

    @Test("Heart rate demonstrates a ready pair inside tolerance")
    func agreeingState() throws {
        let statistics = try #require(fixtureAnalysis(.heartRate).statistics)
        #expect(statistics.severity == .agreeing)
    }

    @Test("Blood oxygen demonstrates bias plus a point outside the limits of agreement")
    func biasedWithOutlierState() throws {
        let analysis = fixtureAnalysis(.spo2)
        let statistics = try #require(analysis.statistics)

        #expect(statistics.severity != .agreeing)
        #expect(statistics.classification == .systematicBias)
        #expect(analysis.observations.contains { !statistics.limitsOfAgreement.contains($0.signedDifference) })
    }

    @Test("Body temperature demonstrates scatter rather than a stable offset")
    func noisyState() throws {
        let statistics = try #require(fixtureAnalysis(.bodyTemperature).statistics)
        #expect(statistics.classification == .measurementNoise)
    }

    @Test("HRV demonstrates the collecting state below the five-window minimum")
    func collectingState() {
        let analysis = fixtureAnalysis(.hrvRMSSD)
        #expect(analysis.state == .collecting(pairedWindowCount: 3, requiredWindowCount: 5))
        #expect(analysis.statistics == nil)
    }

    @Test("Respiratory rate demonstrates two sources that never share a window")
    func noOverlapState() {
        let analysis = fixtureAnalysis(.respiratoryRate)
        #expect(analysis.state == .noOverlap)
        #expect(analysis.candidateWindowCount > 0)
        #expect(analysis.overlapPercentage == 0)
    }

    @Test("The demo archive never lets Compare claim overall agreement")
    func demoOverviewIsNotGreen() {
        let store = HealthStore(persistenceEnabled: false)
        DebugAnalysisFixtures.populate(store: store, now: now)
        let range = DateInterval(
            start: now.addingTimeInterval(-86_400),
            end: now.addingTimeInterval(60)
        )
        let overview = PairwiseEvidenceOverview(
            analyses: ComparisonEngine.allPairwiseAnalyses(from: store.readings(in: range), range: range),
            alertThreshold: .notable
        )

        #expect(overview.status == .readyPairOutsideTolerance)
        #expect(overview.incompleteCount >= 2)   // collecting and no-overlap are both present
        #expect(overview.flaggedCount >= 1)
    }
}
#endif

@Suite("Stable identifiers")
struct StableIDTests {

    @Test("The same string always yields the same UUID")
    func deterministic() {
        #expect(UUID(stableFrom: "oura.hr.x") == UUID(stableFrom: "oura.hr.x"))
        #expect(UUID(stableFrom: "oura.hr.x") != UUID(stableFrom: "oura.hr.y"))
    }

    @Test("Generated identifiers are well-formed version 5 UUIDs")
    func wellFormed() {
        let uuid = UUID(stableFrom: "anything")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        #expect(bytes[6] & 0xF0 == 0x50)   // version 5
        #expect(bytes[8] & 0xC0 == 0x80)   // RFC 4122 variant
    }
}
