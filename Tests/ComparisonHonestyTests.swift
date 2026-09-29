import Foundation
import Testing
@testable import HeartSyncChecker

/// Interval averages kept out of instantaneous windows (improvement 46) and the smaller
/// comparison-honesty details of improvement 69.
@Suite("Interval averages and comparison honesty")
struct ComparisonHonestyTests {

    /// Epoch-aligned to the day, so every window below is deterministic.
    private let midnight = Date(timeIntervalSince1970: 1_699_920_000)

    private func strapNight(from start: Date, hours: Double, value: Double = 60) -> [Reading] {
        stride(from: 0, to: hours * 3_600, by: 60).map { offset in
            Reading(sourceID: "strap", kind: .heartRate, value: value, start: start.addingTimeInterval(offset + 5))
        }
    }

    private func ouraNightAverage(from start: Date, hours: Double, value: Double = 52) -> Reading {
        Reading(
            id: UUID(stableFrom: "oura.sleep.night.avghr"),
            sourceID: DataSource.ouraSourceID,
            kind: .heartRate,
            value: value,
            start: start,
            end: start.addingTimeInterval(hours * 3_600)
        )
    }

    // MARK: - 46

    @Test("A reading longer than its comparison window is an interval average; a window median is not")
    func intervalAverageDefinition() {
        let night = ouraNightAverage(from: midnight, hours: 8)
        #expect(night.isIntervalAverage)
        let compacted = Reading(sourceID: "strap", kind: .heartRate, value: 60, start: midnight, end: midnight.addingTimeInterval(60))
        #expect(!compacted.isIntervalAverage)
        let dailyResting = Reading(sourceID: "hk", kind: .restingHeartRate, value: 55, start: midnight, end: midnight.addingTimeInterval(86_000))
        #expect(!dailyResting.isIntervalAverage)
    }

    @Test("An Oura sleep average and a strap over the same night form no windowed pair")
    func sleepAverageIsNotPaired() throws {
        let start = midnight.addingTimeInterval(-3_600)
        let readings = strapNight(from: start, hours: 8) + [ouraNightAverage(from: start, hours: 8)]
        let range = DateInterval(start: start, duration: 9 * 3_600)

        let windows = ComparisonEngine.windows(from: readings, kind: .heartRate)
        #expect(!windows.contains { $0.value(for: DataSource.ouraSourceID) != nil })

        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "strap",
            sourceB: DataSource.ouraSourceID,
            range: range
        )
        #expect(analysis.pairedWindowCount == 0)
        #expect(analysis.state == .noOverlap)
        #expect(analysis.evidence.grade == .limited)
        #expect(ComparisonEngine.allPairwiseAnalyses(from: readings, range: range).isEmpty)

        let export = PairwiseExporter.makeExport(analysis: analysis, sources: [], appVersion: "test", generatedAt: midnight)
        // A header and no observation rows.
        #expect(export.csv.split(separator: "\r\n", omittingEmptySubsequences: true).count == 1)
    }

    @Test("A daily SpO2 average is not paired with a pulse oximeter's reading at noon")
    func dailySpO2IsNotPaired() {
        let oura = Reading(sourceID: DataSource.ouraSourceID, kind: .spo2, value: 96, start: midnight, end: midnight.addingTimeInterval(86_400))
        let oximeter = (0..<10).map { index in
            Reading(sourceID: "plx", kind: .spo2, value: 98, start: midnight.addingTimeInterval(43_200 + Double(index) * 60))
        }
        let windows = ComparisonEngine.windows(from: oximeter + [oura], kind: .spo2)
        #expect(windows.allSatisfy { $0.values.count == 1 })
    }

    @Test("When interval averages are asked for, their pairs are marked and never reach a conclusion")
    func includedIntervalAveragesNeverConclude() throws {
        let start = midnight
        // Five eight-hour averages, one per night, and a strap stream every night.
        var readings: [Reading] = []
        for night in 0..<6 {
            let nightStart = start.addingTimeInterval(Double(night) * 86_400)
            readings += strapNight(from: nightStart, hours: 8)
            readings.append(Reading(
                sourceID: DataSource.ouraSourceID,
                kind: .heartRate,
                value: 52,
                start: nightStart,
                end: nightStart.addingTimeInterval(8 * 3_600)
            ))
        }
        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "strap",
            sourceB: DataSource.ouraSourceID,
            range: DateInterval(start: start, duration: 7 * 86_400),
            includeIntervalAverages: true
        )
        #expect(analysis.pairedWindowCount == 6)
        #expect(analysis.observations.allSatisfy { $0.timing == .intervalAverage })
        #expect(!PairTimingQuality.intervalAverage.supportsConclusion)
        #expect(analysis.statistics == nil)
        #expect(analysis.state == .collecting(pairedWindowCount: 0, requiredWindowCount: 5))
        #expect(analysis.evidence.grade == .limited)
    }

    @MainActor
    @Test("Compaction leaves an interval average whole and does not fold it into a window median")
    func compactionSkipsIntervalAverages() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        store.upsert(DataSource(id: DataSource.ouraSourceID, displayName: "Oura", transport: .oura))
        let old = midnight.addingTimeInterval(-30 * 86_400)
        let night = ouraNightAverage(from: old, hours: 8)
        // An Oura five-minute sample in the very window the night's midpoint falls in.
        let sample = Reading(sourceID: DataSource.ouraSourceID, kind: .heartRate, value: 58, start: night.midpoint.addingTimeInterval(1))
        let strap = strapNight(from: old, hours: 1) + strapNight(from: old, hours: 1, value: 62).map {
            var shifted = $0
            shifted.id = UUID()
            shifted.start = shifted.start.addingTimeInterval(20)
            shifted.end = shifted.start
            return shifted
        }
        store.append(contentsOf: strap + [night, sample])

        #expect(store.compact(now: midnight))

        let stored = store.readings(kind: .heartRate, enabledOnly: false)
        let kept = try #require(stored.first { $0.id == night.id })
        #expect(kept.start == night.start && kept.end == night.end && kept.value == night.value)
        #expect(stored.contains { $0.id == sample.id })
        // The strap's doubled windows did compact, so the pass itself ran.
        #expect(stored.contains { $0.metadata?.aggregation != nil })
    }

    // MARK: - 69: session titles

    @Test("A fixed period that crosses midnight prints the end's date")
    func fixedPeriodTitleAcrossDays() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 7))!
        let sameDay = ComparisonPeriod.fixed(DateInterval(start: start, duration: 3_600))
        let twoDays = ComparisonPeriod.fixed(DateInterval(start: start, duration: 25 * 3_600))
        let startDate = start.formatted(date: .abbreviated, time: .omitted)
        let endDate = start.addingTimeInterval(25 * 3_600).formatted(date: .abbreviated, time: .omitted)

        #expect(sameDay.title.components(separatedBy: startDate).count == 2)
        #expect(twoDays.title.contains(startDate))
        #expect(twoDays.title.contains(endDate))
    }

    // MARK: - 69: RMSSD on adjacent normal-to-normal pairs

    @Test("RMSSD uses only adjacent normal beats, never a difference across a removed ectopic")
    func rmssdSkipsRemovedEctopic() throws {
        // Normal beats alternate 800/820, then 900/880; one ectopic 500 ms beat sits between.
        let intervals: [Double] = [800, 820, 800, 820, 500, 900, 880, 900, 880]
        let metrics = try #require(HRVCalculator.metrics(from: intervals))
        #expect(metrics.beatCount == 8)
        // Adjacent normal pairs all differ by 20 ms. A difference across the ectopic would
        // add 820 -> 900 = 80 ms and inflate RMSSD, as the earlier calculation did.
        #expect(abs(metrics.rmssd - 20) < 1e-9)
        #expect(metrics.pnn50 == 0)
    }

    @Test("RMSSD does not take a difference across a gap in the R-R stream")
    func rmssdSkipsStreamGap() throws {
        var accumulator = HRVAccumulator()
        accumulator.minimumRMSSDDuration = 0
        let start = midnight
        // Thirty beats alternating 1000/1020, then twenty seconds with nothing, then thirty
        // beats alternating 700/720 (a different rate after the gap).
        var time = start
        for index in 0..<30 {
            let interval: Double = index.isMultiple(of: 2) ? 1_000 : 1_020
            time = time.addingTimeInterval(interval / 1_000)
            accumulator.add(intervals: [interval], at: time)
        }
        time = time.addingTimeInterval(20)
        for index in 0..<30 {
            let interval: Double = index.isMultiple(of: 2) ? 700 : 720
            time = time.addingTimeInterval(interval / 1_000)
            accumulator.add(intervals: [interval], at: time)
        }
        #expect(accumulator.streamBreaks.count == 1)
        let ready = accumulator.emissionIfReady(at: time)
        let emission = try #require(ready)
        #expect(abs(emission.metrics.rmssd - 20) < 1e-9)
    }

    // MARK: - 69: confidence intervals

    @Test("The t quantile matches published values and approaches 1.96")
    func tQuantile() {
        #expect(abs(ComparisonEngine.tQuantile975(degreesOfFreedom: 1) - 12.706) < 0.001)
        #expect(abs(ComparisonEngine.tQuantile975(degreesOfFreedom: 9) - 2.262) < 0.001)
        #expect(abs(ComparisonEngine.tQuantile975(degreesOfFreedom: 30) - 2.042) < 0.001)
        #expect(abs(ComparisonEngine.tQuantile975(degreesOfFreedom: 60) - 2.000) < 0.002)
        #expect(abs(ComparisonEngine.tQuantile975(degreesOfFreedom: 120) - 1.980) < 0.002)
        #expect(abs(ComparisonEngine.tQuantile975(degreesOfFreedom: 1e9) - 1.960) < 0.001)
        // Between table entries it lies between them.
        let between = ComparisonEngine.tQuantile975(degreesOfFreedom: 9.5)
        #expect(between < 2.262 && between > 2.228)
    }

    private func pairedSeries(differences: [Double], contiguous: Bool) -> PairwiseAnalysis {
        var readings: [Reading] = []
        for (index, difference) in differences.enumerated() {
            let step: TimeInterval = contiguous ? 60 : 600
            let at = midnight.addingTimeInterval(Double(index) * step + 10)
            readings.append(Reading(sourceID: "a", kind: .heartRate, value: 70 + difference, start: at))
            readings.append(Reading(sourceID: "b", kind: .heartRate, value: 70, start: at))
        }
        return ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: DateInterval(start: midnight, duration: 2 * 86_400)
        )
    }

    @Test("Autocorrelated adjacent windows shrink the effective sample size and widen the bias interval")
    func autocorrelationWidensInterval() throws {
        // A slow drift: each window's difference close to the one before.
        let drifting = (0..<40).map { 2 + sin(Double($0) / 6) * 3 }
        let adjacent = try #require(pairedSeries(differences: drifting, contiguous: true).statistics)
        let spaced = try #require(pairedSeries(differences: drifting, contiguous: false).statistics)

        let effective = try #require(adjacent.effectiveSampleSize)
        #expect(effective < 40)
        #expect(effective >= 2)
        // Windows that never touch are treated as independent.
        #expect(spaced.effectiveSampleSize == 40)

        let adjacentInterval = try #require(adjacent.meanBiasConfidenceInterval)
        let spacedInterval = try #require(spaced.meanBiasConfidenceInterval)
        let adjacentWidth = adjacentInterval.upperBound - adjacentInterval.lowerBound
        let spacedWidth = spacedInterval.upperBound - spacedInterval.lowerBound
        #expect(adjacentWidth > spacedWidth)
        // The limits of agreement describe the differences and do not move.
        #expect(adjacent.limitsOfAgreement == spaced.limitsOfAgreement)
    }

    @Test("Alternating differences never claim more than n independent windows")
    func negativeAutocorrelationIsNotRewarded() throws {
        let alternating = (0..<20).map { $0.isMultiple(of: 2) ? 1.0 : 5.0 }
        let statistics = try #require(pairedSeries(differences: alternating, contiguous: true).statistics)
        #expect(statistics.effectiveSampleSize == 20)
        let interval = try #require(statistics.meanBiasConfidenceInterval)
        let margin = (interval.upperBound - interval.lowerBound) / 2
        let expected = ComparisonEngine.tQuantile975(degreesOfFreedom: 19) * statistics.differenceSD / sqrt(20)
        #expect(abs(margin - expected) < 1e-9)
    }

    @Test("The export states the effective sample size and the t-based method")
    func exportExplainsMethod() {
        let analysis = pairedSeries(differences: (0..<40).map { 2 + sin(Double($0) / 6) * 3 }, contiguous: true)
        let summary = PairwiseExporter.makeExport(analysis: analysis, sources: [], appVersion: "test", generatedAt: midnight).summary
        #expect(summary.contains("Effective independent windows"))
        #expect(summary.contains("Student's t"))
    }

    // MARK: - 69: clock skew

    @MainActor
    @Test("A sample from a clock slightly ahead is kept; one far ahead is still rejected")
    func clockSkewAllowance() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "hk.watch", displayName: "Watch", transport: .healthKit))
        let now = Date.now
        let slightlyAhead = Reading(sourceID: "hk.watch", kind: .heartRate, value: 70, start: now.addingTimeInterval(20))
        let farAhead = Reading(sourceID: "hk.watch", kind: .heartRate, value: 71, start: now.addingTimeInterval(HealthStore.maximumFutureSkew + 120))

        #expect(store.append(slightlyAhead))
        #expect(!store.append(farAhead))
    }
}
