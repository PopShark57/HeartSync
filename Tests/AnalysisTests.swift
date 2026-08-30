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
