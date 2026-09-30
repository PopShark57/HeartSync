import Foundation
import Testing
@testable import HeartSyncChecker

/// HeartSync's stress index (`StressModel`): personal baselines, the exercise gate, evidence
/// weighting, smoothing, storage as an estimate, and the ring's stress check.
@Suite("Stress index")
@MainActor
struct StressModelTests {
    private static let utc = TimeZone(secondsFromGMT: 0)!
    /// Yesterday's midday UTC: always in the past, which the store requires of a reading.
    private let now = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-86_400), size: 86_400).addingTimeInterval(12 * 3_600 + 30)
    private let strap = DataSource(id: "strap", displayName: "Strap", transport: .bluetooth)
    private let watch = DataSource(id: "hk.watch", displayName: "Watch", transport: .healthKit)
    private let estimateSource = AppModel.estimateSourceID

    /// Fourteen days of heart rate every ten minutes around 65 bpm, strap RMSSD around 45 ms
    /// and watch SDNN around 80 ms every half hour, a daily resting heart rate of 58, and
    /// breathing, SpO2, and temperature history. Nothing in the last hour.
    private func seededStore(days: Int = 14) -> HealthStore {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(watch)
        var readings: [Reading] = []
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        var index = 0
        var stamp = start
        while stamp < now.addingTimeInterval(-3_600) {
            let i = Double(index)
            readings.append(Reading(sourceID: watch.id, kind: .heartRate, value: 65 + 5 * sin(i * 1.7), start: stamp))
            if index % 3 == 0 {
                readings.append(Reading(sourceID: strap.id, kind: .hrvRMSSD, value: 45 * exp(0.2 * sin(i * 1.3)), start: stamp, provenance: .derived))
                readings.append(Reading(sourceID: watch.id, kind: .hrvSDNN, value: 80 * exp(0.2 * sin(i * 0.9)), start: stamp))
            }
            if index % 36 == 0 {
                readings.append(Reading(sourceID: watch.id, kind: .respiratoryRate, value: 14 + sin(i), start: stamp))
                readings.append(Reading(sourceID: watch.id, kind: .spo2, value: 97 + sin(i * 0.7), start: stamp))
                readings.append(Reading(sourceID: watch.id, kind: .bodyTemperature, value: 36.5 + 0.2 * sin(i * 0.5), start: stamp))
            }
            if index % 144 == 0 {
                readings.append(Reading(sourceID: watch.id, kind: .restingHeartRate, value: 58, start: stamp))
            }
            index += 1
            stamp = stamp.addingTimeInterval(600)
        }
        store.append(contentsOf: readings)
        return store
    }

    private func addCurrent(_ store: HealthStore, heartRate: Double?, rmssd: Double?) {
        if let heartRate {
            store.append(Reading(sourceID: watch.id, kind: .heartRate, value: heartRate, start: now.addingTimeInterval(-40)))
        }
        if let rmssd {
            store.append(Reading(sourceID: strap.id, kind: .hrvRMSSD, value: rmssd, start: now.addingTimeInterval(-600), provenance: .derived))
        }
    }

    private func assess(
        _ store: HealthStore,
        at time: Date? = nil,
        previous: (score: Double, at: Date)? = nil
    ) -> Result<StressModel.Assessment, StressModel.Unavailable> {
        let baseline = StressModel.Baseline.build(history: store.history, now: now, estimateSourceID: estimateSource, timeZone: Self.utc)
        return StressModel.assess(
            history: store.history,
            baseline: baseline,
            now: time ?? now,
            maxHeartRate: nil,
            estimateSourceID: estimateSource,
            previous: previous,
            timeZone: Self.utc
        )
    }

    // MARK: Statistics

    @Test("Robust baselines use the median and the scaled MAD, and need enough values")
    func robustStatistics() throws {
        let robust = try #require(StressModel.Robust([1, 2, 3, 4, 100, 5, 6, 7], minimumCount: 8))
        #expect(robust.median == 4.5)
        // Deviations 3.5 2.5 1.5 0.5 95.5 0.5 1.5 2.5: median 2.0.
        #expect(abs(robust.scale - 1.4826 * 2) < 1e-9)
        #expect(StressModel.Robust([1, 2, 3], minimumCount: 8) == nil)
        // The scale floor stops a flat history turning a tiny change into a huge score.
        let flat = StressModel.Robust(median: 50, scale: 0, count: 20)
        #expect(flat.z(51, minimumScale: 2) == 0.5)
    }

    @Test("Hour-of-day moments come from one aggregate over measured, short readings")
    func hourOfDayMoments() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(watch)
        let midnight = ComparisonEngine.floorToWindow(now, size: 86_400)
        store.append(contentsOf: [
            Reading(sourceID: watch.id, kind: .heartRate, value: 60, start: midnight.addingTimeInterval(9 * 3_600 + 10)),
            Reading(sourceID: watch.id, kind: .heartRate, value: 70, start: midnight.addingTimeInterval(9 * 3_600 + 900)),
            Reading(sourceID: watch.id, kind: .heartRate, value: 90, start: midnight.addingTimeInterval(14 * 3_600)),
            // An estimate and a night's average are not what an hour's heart rate looks like.
            Reading(sourceID: watch.id, kind: .heartRate, value: 150, start: midnight.addingTimeInterval(9 * 3_600 + 60), provenance: .estimated),
            Reading(sourceID: watch.id, kind: .heartRate, value: 50, start: midnight.addingTimeInterval(9 * 3_600), end: midnight.addingTimeInterval(9 * 3_600 + 1_800)),
        ])
        let moments = try store.history.hourOfDayMomentsOutcome(
            kind: .heartRate,
            range: DateInterval(start: midnight, end: midnight.addingTimeInterval(86_400)),
            utcOffset: 0,
            maximumDuration: 60
        ).get()
        #expect(moments[9] == HourMoments(count: 2, sum: 130, sumOfSquares: 60 * 60 + 70 * 70))
        #expect(moments[14]?.count == 1)
        #expect(moments[9]?.mean == 65)
        // The offset moves the buckets to local hours.
        let shifted = try store.history.hourOfDayMomentsOutcome(
            kind: .heartRate,
            range: DateInterval(start: midnight, end: midnight.addingTimeInterval(86_400)),
            utcOffset: 3_600,
            maximumDuration: 60
        ).get()
        #expect(shifted[10]?.count == 2)
    }

    // MARK: Scoring

    @Test("A person at their own baseline scores in the normal band")
    func typicalIsNormal() throws {
        let store = seededStore()
        addCurrent(store, heartRate: 65, rmssd: 45)
        let assessment = try assess(store).get()
        #expect(abs(assessment.score - StressModel.typicalScore) < 8)
        #expect(assessment.band == .normal)
        #expect(assessment.components.contains { $0.signal == .vagalWithdrawal })
        #expect(assessment.components.contains { $0.signal == .heartRateElevation })
    }

    @Test("Low HRV with a raised heart rate for the time of day scores high, and says why")
    func stressedIsHigh() throws {
        let store = seededStore()
        addCurrent(store, heartRate: 82, rmssd: 24)
        let assessment = try assess(store).get()
        #expect(assessment.score >= 75)
        #expect(assessment.band == .high)
        let drivers = try #require(assessment.driverSummary)
        #expect(drivers.contains("HRV below your usual"))
        #expect(drivers.contains("heart rate above your usual"))
    }

    @Test("High HRV with a low heart rate scores low")
    func relaxedIsLow() throws {
        let store = seededStore()
        addCurrent(store, heartRate: 57, rmssd: 72)
        let assessment = try assess(store).get()
        #expect(assessment.score < 25)
        #expect(assessment.band == .low)
    }

    @Test("A heart rate above half of heart-rate reserve is read as exercise, not stress")
    func exerciseIsNotStress() {
        let store = seededStore()
        addCurrent(store, heartRate: 150, rmssd: 20)
        #expect(assess(store) == .failure(.likelyExercise(heartRate: 150)))
    }

    @Test("Without a current heart rate or HRV there is no score")
    func nothingCurrent() {
        let store = seededStore()
        // The seeded watch SDNN an hour back still counts (SDNN is usable for four hours);
        // six hours on, nothing does.
        #expect((try? assess(store).get()) != nil)
        #expect(assess(store, at: now.addingTimeInterval(6 * 3_600)) == .failure(.noCurrentSignal))
    }

    @Test("Without history to compare with there is no score")
    func noBaseline() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(watch)
        addCurrent(store, heartRate: 70, rmssd: 40)
        #expect(assess(store) == .failure(.insufficientEvidence))
    }

    @Test("Each device's HRV is judged on its own scale")
    func perSourceHRVScales() throws {
        let store = seededStore()
        // The strap at its usual 45 ms RMSSD and the watch at its usual 80 ms SDNN: both
        // typical, although a pooled baseline would call one of them very high.
        addCurrent(store, heartRate: 65, rmssd: 45)
        store.append(Reading(sourceID: watch.id, kind: .hrvSDNN, value: 80, start: now.addingTimeInterval(-900)))
        let assessment = try assess(store).get()
        let hrv = try #require(assessment.components.first { $0.signal == .vagalWithdrawal })
        #expect(abs(hrv.z) < 0.6)
    }

    @Test("A previous score from the last twenty minutes smooths the new one")
    func smoothing() throws {
        let store = seededStore()
        addCurrent(store, heartRate: 65, rmssd: 45)
        let alone = try assess(store).get().score
        let smoothed = try assess(store, previous: (score: 90, at: now.addingTimeInterval(-300))).get().score
        #expect(abs(smoothed - (0.65 * alone + 0.35 * 90)) < 0.001)
        // An old score is not blended in.
        let stale = try assess(store, previous: (score: 90, at: now.addingTimeInterval(-3_600))).get().score
        #expect(abs(stale - alone) < 0.001)
    }

    @Test("Breathing, temperature, and SpO2 add evidence only in the stress-like direction")
    func secondarySignals() throws {
        let store = seededStore()
        addCurrent(store, heartRate: 65, rmssd: 45)
        store.append(contentsOf: [
            Reading(sourceID: watch.id, kind: .respiratoryRate, value: 20, start: now.addingTimeInterval(-1_200)),
            // Cooler and better oxygenated than usual: neither lowers the score.
            Reading(sourceID: watch.id, kind: .bodyTemperature, value: 35.8, start: now.addingTimeInterval(-1_200)),
            Reading(sourceID: watch.id, kind: .spo2, value: 99, start: now.addingTimeInterval(-1_200)),
        ])
        let assessment = try assess(store).get()
        let respiration = try #require(assessment.components.first { $0.signal == .respiration })
        #expect(respiration.z > 2)
        #expect(assessment.components.first { $0.signal == .thermalStrain }?.z == 0)
        #expect(assessment.components.first { $0.signal == .oxygenation }?.z == 0)
        #expect(assessment.confidence > 0.7)
    }

    @Test("Stale evidence counts less, then not at all")
    func freshness() {
        #expect(StressModel.freshness(age: 0, maxAge: 3_600) == 1)
        #expect(abs(StressModel.freshness(age: 1_800, maxAge: 3_600) - 0.5) < 1e-9)
        #expect(StressModel.freshness(age: 3_601, maxAge: 3_600) == 0)
    }

    @Test("Bands split the score into quarters")
    func bands() {
        #expect(StressModel.Band(score: 0) == .low)
        #expect(StressModel.Band(score: 24.9) == .low)
        #expect(StressModel.Band(score: 25) == .normal)
        #expect(StressModel.Band(score: 50) == .elevated)
        #expect(StressModel.Band(score: 75) == .high)
        #expect(StressModel.Band(score: 100) == .high)
    }

    // MARK: Storage

    @Test("The index is stored once per five-minute slot as HeartSync's estimate")
    func storedAsEstimate() throws {
        let store = seededStore()
        addCurrent(store, heartRate: 70, rmssd: 38)
        let inputs = DerivedEstimates.Inputs(
            vo2MaxEnabled: false,
            estimatedMaxHeartRate: nil,
            bloodPressureCalibration: nil,
            estimateSourceID: estimateSource
        )
        let first = DerivedEstimates.compute(history: store.history, inputs: inputs, now: now, timeZone: Self.utc)
        let reading = try #require(first.stress.first)
        #expect(reading.kind == .stress)
        #expect(reading.sourceID == estimateSource)
        #expect(reading.provenance == .estimated)
        #expect(reading.metadata?.modelledBy == ReadingMetadata.heartSyncModel)
        #expect(first.stressBaseline != nil)
        // The same slot recomputed a minute later is the same reading, revised.
        var reused = inputs
        reused.stressBaseline = first.stressBaseline
        let again = DerivedEstimates.compute(history: store.history, inputs: reused, now: now.addingTimeInterval(60), timeZone: Self.utc)
        #expect(again.stress.first?.id == reading.id)
    }

    @Test("A baseline is rebuilt when it ages or the time zone changes")
    func baselineLifetime() {
        let baseline = StressModel.Baseline(builtAt: now, utcOffset: 0)
        #expect(!baseline.isStale(at: now.addingTimeInterval(3_600), utcOffset: 0))
        #expect(baseline.isStale(at: now.addingTimeInterval(StressModel.Baseline.lifetime + 1), utcOffset: 0))
        #expect(baseline.isStale(at: now.addingTimeInterval(60), utcOffset: 3_600))
        #expect(baseline.isStale(at: now.addingTimeInterval(-60), utcOffset: 0))
    }

    @Test("The stress metric is only ever an estimate and never mirrored to Health")
    func metricContract() {
        #expect(MetricKind.stress.plausibleRange == 0...100)
        #expect(MetricKind.stress.formatWithUnit(42) == "42/100")
        #expect(R11MRingSession.provenance(for: .stress) == .estimated)
        #expect(!HealthKitManager.mappings.contains { $0.kind == .stress })
    }

    // MARK: Ring stress check

    @Test("A ring stress check measures heart rate, then scores")
    func ringStressCheck() async throws {
        var handler: (@MainActor (String, R11MRingSession.RingValue) -> Void)?
        var measured: [String] = []
        var transports = AppModel.TransportActions.inert
        transports.measureRingHeartRate = { measured.append($0); return true }
        transports.observeRingMeasurements = { handler = $0 }
        let model = AppModel(
            store: HealthStore(persistenceEnabled: false),
            settings: AppSettings(persistenceEnabled: false),
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: transports
        )
        model.launch()
        let deliver = try #require(handler)

        model.checkStress(ringSourceID: "ring")
        #expect(measured == ["ring"])
        #expect(model.stressChecks["ring"] == .measuring)

        // Another measurement's value does not complete a stress check.
        deliver("ring", .bloodOxygen(percent: 97))
        #expect(model.stressChecks["ring"] == .measuring)

        deliver("ring", .heartRate(bpm: 70))
        for _ in 0..<200 where model.stressChecks["ring"] == .measuring {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The inert transport stored no heart rate, so there is nothing current to score.
        #expect(model.stressChecks["ring"] == .unavailable(.noCurrentSignal))
        model.clearStressCheck(ringSourceID: "ring")
        #expect(model.stressChecks["ring"] == nil)
    }

    @Test("A ring that cannot start a measurement starts no stress check")
    func ringStressCheckRefused() {
        var transports = AppModel.TransportActions.inert
        transports.measureRingHeartRate = { _ in false }
        let model = AppModel(
            store: HealthStore(persistenceEnabled: false),
            settings: AppSettings(persistenceEnabled: false),
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: transports
        )
        model.checkStress(ringSourceID: "ring")
        #expect(model.stressChecks["ring"] == nil)
    }
}
