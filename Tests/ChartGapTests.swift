import Foundation
import Testing
@testable import HeartSyncChecker

/// Lines, bands, and areas break across data gaps (improvement 30).
///
/// These pin the projections the charts draw from. A drawn curve can only span a gap if its
/// series key does, so asserting the keys is asserting the drawing.
@Suite("Chart gaps")
@MainActor
struct ChartGapTests {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func dates(_ offsets: [TimeInterval]) -> [Date] {
        offsets.map { origin.addingTimeInterval($0) }
    }

    // MARK: - Shared helper

    @Test("A gap wider than the threshold starts a segment; one at the threshold does not")
    func segmentsBreakOnlyAboveThreshold() {
        #expect(ChartSegmentation.segments(for: dates([0, 60, 120]), threshold: 90) == [0, 0, 0])
        #expect(ChartSegmentation.segments(for: dates([0, 60, 600, 660]), threshold: 90) == [0, 0, 1, 1])
        #expect(ChartSegmentation.segments(for: dates([0, 90]), threshold: 90) == [0, 0])
        #expect(ChartSegmentation.segments(for: dates([0, 91]), threshold: 90) == [0, 1])
        #expect(ChartSegmentation.segments(for: dates([0, 10_000]), threshold: 0) == [0, 0])
        #expect(ChartSegmentation.segments(for: [], threshold: 60).isEmpty)
    }

    @Test("Single-sample segments are reported so the view can draw them as points")
    func isolatedPositionsAreFound() {
        #expect(ChartSegmentation.isolatedPositions([0, 0, 1, 2, 2]) == [2])
        #expect(ChartSegmentation.isolatedPositions([0]) == [0])
        #expect(ChartSegmentation.isolatedPositions([0, 0]).isEmpty)
    }

    @Test("Thinning's stride widens the window threshold; a real gap still exceeds it")
    func strideScalesTheThreshold() {
        #expect(ChartSegmentation.windowThreshold(windowSize: 60) == 90)
        #expect(ChartSegmentation.windowThreshold(windowSize: 60, stride: 3.2) == 360)
        #expect(ChartSegmentation.windowThreshold(windowSize: 60, stride: 0.5) == 90)
    }

    @Test("Irregular samples break at a multiple of their median spacing")
    func medianSpacingThreshold() {
        #expect(ChartSegmentation.medianSpacingThreshold(for: dates([0, 300, 600, 910, 1_200])) == 750)
        #expect(ChartSegmentation.medianSpacingThreshold(for: dates([0])) == nil)
        #expect(ChartSegmentation.medianSpacingThreshold(for: dates([5, 5])) == nil)
    }

    // MARK: - Disagreement band

    private func band(_ offset: TimeInterval, spread: Double, _ severity: DiscrepancySeverity) -> BandPoint {
        BandPoint(id: "w\(Int(offset))", date: origin.addingTimeInterval(offset), low: 70, high: 70 + spread, severity: severity)
    }

    @Test("The band breaks where no two devices were compared")
    func bandBreaksAtGaps() {
        let runs = MetricDetailSnapshot.bandRuns(
            [band(0, spread: 2, .agreeing), band(60, spread: 2, .agreeing), band(600, spread: 2, .agreeing), band(660, spread: 2, .agreeing)],
            bucketSize: 60
        )
        let before = Set(runs.filter { $0.date < origin.addingTimeInterval(300) }.map(\.seriesKey))
        let after = Set(runs.filter { $0.date > origin.addingTimeInterval(300) }.map(\.seriesKey))
        #expect(before.count == 1)
        #expect(after.count == 1)
        #expect(before.isDisjoint(with: after))
        #expect(runs.allSatisfy { !$0.isIsolated })
    }

    @Test("A severity change starts its own area, so a later disagreement is never shaded as the first window")
    func bandSplitsAtSeverityChanges() throws {
        let runs = MetricDetailSnapshot.bandRuns(
            [band(0, spread: 2, .agreeing), band(60, spread: 2, .agreeing), band(120, spread: 20, .major), band(180, spread: 20, .major)],
            bucketSize: 60
        )
        let bySeries = Dictionary(grouping: runs, by: \.seriesKey)
        #expect(bySeries.count == 2)
        // Every area series carries one severity: Swift Charts styles a series by its first
        // mark, so a mixed series would paint the major windows green.
        #expect(bySeries.values.allSatisfy { Set($0.map(\.severity)).count == 1 })

        // The two runs meet halfway between the last agreeing and the first major window.
        let agreeing = try #require(bySeries.values.first { $0.first?.severity == .agreeing })
        let major = try #require(bySeries.values.first { $0.first?.severity == .major })
        let join = origin.addingTimeInterval(90)
        #expect(agreeing.last?.date == join)
        #expect(major.first?.date == join)
        #expect(agreeing.last?.high == major.first?.high)
        #expect(agreeing.last?.high == 81)
        #expect(Set(runs.map(\.id)).count == runs.count)
    }

    @Test("A compared window with no compared neighbour stays, flagged as isolated")
    func isolatedBandWindowSurvives() {
        let runs = MetricDetailSnapshot.bandRuns(
            [band(0, spread: 6, .notable), band(1_200, spread: 2, .agreeing), band(1_260, spread: 2, .agreeing)],
            bucketSize: 60
        )
        #expect(runs.count == 3)
        #expect(runs.first { $0.id == "w0" }?.isIsolated == true)
        #expect(runs.filter(\.isIsolated).count == 1)
    }

    @Test("The metric-detail band has no series spanning a stretch where one device was silent")
    func snapshotBandHasNoSeriesAcrossAGap() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        store.upsert(DataSource(id: "b", displayName: "B", transport: .healthKit))
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-3_000), size: 60)
        for minute in 0..<40 {
            let stamp = anchor.addingTimeInterval(Double(minute) * 60)
            _ = store.append(Reading(sourceID: "a", kind: .heartRate, value: 70, start: stamp))
            // B is silent for minutes 10–29: nothing is compared there.
            if minute < 10 || minute >= 30 {
                _ = store.append(Reading(sourceID: "b", kind: .heartRate, value: minute < 10 ? 71 : 90, start: stamp.addingTimeInterval(3)))
            }
        }
        let snapshot = MetricDetailSnapshot(store: store, kind: .heartRate, range: .hour, includeEstimates: false, hrvQuality: [:])
        let gapStart = anchor.addingTimeInterval(10 * 60)
        let gapEnd = anchor.addingTimeInterval(29 * 60)

        let seriesBefore = Set(snapshot.bandPoints.filter { $0.date < gapStart }.map(\.seriesKey))
        let seriesAfter = Set(snapshot.bandPoints.filter { $0.date > gapEnd }.map(\.seriesKey))
        #expect(!seriesBefore.isEmpty)
        #expect(!seriesAfter.isEmpty)
        #expect(seriesBefore.isDisjoint(with: seriesAfter))
        #expect(snapshot.bandPoints.allSatisfy { $0.date < gapStart || $0.date > gapEnd })
        // The silent device's line breaks too, while the reporting one stays whole.
        let bKeys = Set(snapshot.points.filter { $0.sourceID == "b" }.map(\.seriesKey))
        let aKeys = Set(snapshot.points.filter { $0.sourceID == "a" }.map(\.seriesKey))
        #expect(bKeys.count == 2)
        #expect(aKeys.count == 1)
    }

    // MARK: - Pairwise timeline

    private func pairReadings(minutes: [Int]) -> [Reading] {
        minutes.flatMap { minute -> [Reading] in
            let stamp = origin.addingTimeInterval(Double(minute) * 60 + 1)
            return [
                Reading(sourceID: "a", kind: .heartRate, value: 70, start: stamp),
                Reading(sourceID: "b", kind: .heartRate, value: 72, start: stamp.addingTimeInterval(2)),
            ]
        }
    }

    private func pairSnapshot(_ readings: [Reading]) -> PairwiseSnapshot {
        let interval = DateInterval(start: origin, duration: 3 * 86_400)
        return PairwiseSnapshot(kind: .heartRate, sourceA: "a", sourceB: "b", period: .fixed(interval), interval: interval, readings: readings)
    }

    @Test("The pairwise timeline breaks between paired windows hours apart")
    func pairwiseTimelineBreaksAtGaps() {
        let snapshot = pairSnapshot(pairReadings(minutes: Array(0..<10) + Array(300..<310)))
        #expect(snapshot.plotted.count == 20)
        #expect(Set(snapshot.timelineSegments.prefix(10)).count == 1)
        #expect(Set(snapshot.timelineSegments.suffix(10)).count == 1)
        #expect(snapshot.timelineSegments[9] != snapshot.timelineSegments[10])
    }

    @Test("A thinned but continuous pair stays one line; a real gap still breaks it")
    func thinningAloneDoesNotBreakTheLine() {
        let continuous = pairSnapshot(pairReadings(minutes: Array(0..<1_600)))
        #expect(continuous.plotted.count < continuous.analysis.observations.count)
        #expect(Set(continuous.timelineSegments).count == 1)

        let gapped = pairSnapshot(pairReadings(minutes: Array(0..<800) + Array(2_400..<3_200)))
        #expect(gapped.plotted.count < gapped.analysis.observations.count)
        #expect(Set(gapped.timelineSegments).count == 2)
    }

    // MARK: - Oura heart rate

    private func ouraSample(_ minutesBefore: Int, bpm: Int) -> OuraClient.HeartRatePoint {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let date = Date(timeIntervalSince1970: 1_756_000_000 - Double(minutesBefore) * 60)
        return OuraClient.HeartRatePoint(bpm: bpm, source: "awake", timestamp: formatter.string(from: date))
    }

    @Test("Oura heart rate breaks across the ring's charging gap and keeps a lone sample as a dot")
    func ouraHeartRateBreaksAtHoles() throws {
        var samples = (0..<12).map { ouraSample(600 - $0 * 5, bpm: 60 + $0) }          // before charging
        samples.append(ouraSample(400, bpm: 58))                                      // a lone sample
        samples += (0..<12).map { ouraSample(200 - $0 * 5, bpm: 70 + $0) }            // after
        let series = OuraHeartRateSeries(heartRates: samples)

        #expect(series.points.count == 25)
        #expect(Set(series.points.map(\.segment)).count == 3)
        let lone = try #require(series.points.first { $0.bpm == 58 })
        #expect(lone.isIsolated)
        #expect(series.points.filter(\.isIsolated).count == 1)
        // Segments never interleave in time.
        #expect(series.points.map(\.segment) == series.points.map(\.segment).sorted())
    }

    @Test("A regular Oura series is a single line")
    func regularOuraSeriesIsOneLine() {
        let samples = (0..<60).map { ouraSample(300 - $0 * 5, bpm: 60 + $0 % 7) }
        let series = OuraHeartRateSeries(heartRates: samples)
        #expect(Set(series.points.map(\.segment)) == [0])
        #expect(series.points.allSatisfy { !$0.isIsolated })
    }
}
