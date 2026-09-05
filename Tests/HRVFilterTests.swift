import Foundation
import Testing
@testable import HeartSyncChecker

/// The artefact filter is the single place where HeartSync decides which heartbeats are
/// real. Every HRV number the app shows, and every HRV disagreement it reports between two
/// devices, is downstream of these decisions, so both failure directions are covered here:
/// rejecting beats that were genuine (which stalls HRV and makes the feature look broken)
/// and accepting beats that were not (which inflates RMSSD and makes the feature lie).
///
/// `AnalysisTests` already pins the arithmetic — RMSSD, SDNN, pNN50 against hand-computed
/// values — and the accumulator's basic gating. This suite covers the reference-tracking
/// rewrite instead.
@Suite("HRV artefact filter")
struct HRVArtefactFilterTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: The stall

    /// The regression that matters most. The filter compares each interval against a
    /// running reference rather than a fixed one, so a person who starts exercising does
    /// not have every subsequent beat thrown away.
    @Test("A gradual rise from rest to exercise is tracked, not condemned as artefact")
    func sustainedRampIsTracked() throws {
        // 40 beats at rest (1000 ms, 60 bpm), a ramp down, then 40 beats of exercise
        // (600 ms, 100 bpm). The end rate is 40% away from the start rate, far outside the
        // 20% band any single comparison allows.
        let rest = Array(repeating: 1000.0, count: 40)
        let ramp: [Double] = [960, 920, 880, 840, 800, 760, 720, 680, 640]
        let exercise = Array(repeating: 600.0, count: 40)
        let session = rest + ramp + exercise

        let (clean, rejected) = HRVCalculator.filterArtefacts(session)

        // Not one beat of a physiologically ordinary warm-up is an artefact, and the
        // surviving beats come back in the order they were measured.
        #expect(rejected == 0)
        #expect(clean == session)

        let metrics = try #require(HRVCalculator.metrics(from: session))
        #expect(metrics.artefactFraction == 0)
        #expect(metrics.isReliable)
    }

    @Test("An abrupt rate change does not permanently stall HRV")
    func abruptRateChangeDoesNotStall() throws {
        // The stall in its worst form: no ramp at all, just four minutes of rest followed
        // by a minute of exercise, which is what a window straddling the moment someone
        // stands up and starts running actually contains.
        let session = Array(repeating: 1000.0, count: 240) + Array(repeating: 600.0, count: 100)
        let (clean, rejected) = HRVCalculator.filterArtefacts(session)

        #expect(rejected == 0)
        #expect(clean.count == session.count)
        // The exercise beats are all still there; they were not silently dropped and then
        // hidden behind a healthy-looking count of rest beats.
        #expect(clean.filter { $0 == 600 }.count == 100)

        let metrics = try #require(HRVCalculator.metrics(from: session))
        // Holding the reference at the resting rate would reject all 100 exercise beats:
        // 100/340 is 29%, past `maximumArtefactFraction`, so the window would be discarded
        // and the user would see HRV simply stop.
        #expect(metrics.artefactFraction < HRVMetrics.maximumArtefactFraction)
        #expect(metrics.isReliable)
    }

    @Test("The accumulator keeps emitting across a rate transition")
    func accumulatorSurvivesTransition() throws {
        // The stall as the user experiences it: HRV appears, exercise starts, HRV never
        // comes back. Beats are fed one at a time on a real clock, as the Bluetooth
        // manager feeds them.
        var accumulator = HRVAccumulator()

        // Four minutes at 60 bpm.
        for beat in 0..<240 {
            accumulator.add(intervals: [1000], at: epoch.addingTimeInterval(Double(beat)))
        }
        let atRestEmission = accumulator.emitIfReady(at: epoch.addingTimeInterval(239))
        let atRest = try #require(atRestEmission)
        #expect(abs(atRest.meanHeartRate - 60) < 1e-9)

        // One minute at 100 bpm, so the window now straddles the transition.
        let transition = epoch.addingTimeInterval(240)
        for beat in 0..<100 {
            accumulator.add(intervals: [600], at: transition.addingTimeInterval(Double(beat) * 0.6))
        }
        let straddlingEmission = accumulator.emitIfReady(at: transition.addingTimeInterval(60))
        let straddling = try #require(straddlingEmission)
        #expect(straddling.artefactFraction == 0)
        #expect(straddling.isReliable)

        // Keep exercising until the resting beats have aged out of the sliding window.
        for beat in 100..<700 {
            accumulator.add(intervals: [600], at: transition.addingTimeInterval(Double(beat) * 0.6))
        }
        let exercisingEmission = accumulator.emitIfReady(at: transition.addingTimeInterval(420))
        let exercising = try #require(exercisingEmission)
        #expect(abs(exercising.meanHeartRate - 100) < 1e-9)
        #expect(exercising.beatCount >= HRVMetrics.minimumBeats)
        #expect(exercising.artefactFraction == 0)
    }

    @Test("The live HRV buffer has a finite beat bound")
    func accumulatorCapsBurstInput() {
        var accumulator = HRVAccumulator()
        let burst = Array(repeating: 800.0, count: HRVAccumulator.maximumBufferedBeats * 2)

        accumulator.add(intervals: burst, at: epoch)

        #expect(accumulator.bufferedBeats == HRVAccumulator.maximumBufferedBeats)
    }

    // MARK: Artefacts the filter must still catch

    @Test("A single ectopic beat is rejected, and only that beat")
    func singleEctopicCostsOneBeat() throws {
        // Deliberately at exercise rate, where the reference has had to move to get here:
        // tracking the rhythm must not have cost the ability to spot a beat that breaks it.
        var session = Array(repeating: 600.0, count: 20)
        session.append(340)          // in range, but a premature beat
        session += Array(repeating: 600.0, count: 20)

        let (clean, rejected) = HRVCalculator.filterArtefacts(session)
        // A successive-difference filter would also condemn the normal beat that follows
        // the ectopic, costing two. Comparing against the prevailing rhythm costs one.
        #expect(rejected == 1)
        #expect(clean == Array(repeating: 600.0, count: 40))

        let metrics = try #require(HRVCalculator.metrics(from: session))
        // Left in, this beat alone would take RMSSD from 0 to roughly 260 ms.
        #expect(metrics.rmssd == 0)
        #expect(abs(metrics.meanHeartRate - 100) < 1e-9)
    }

    @Test("A two-beat artefact couplet is not mistaken for a change of rhythm")
    func consistentCoupletIsStillRejected() throws {
        // Two consecutive premature beats that agree with each other. They are mutually
        // consistent, so a rejection-run limit of two would accept them as a rate change —
        // and then accept the return to 800 ms as another one, reporting an artefact-free
        // window whose RMSSD is pure fiction.
        var session = Array(repeating: 800.0, count: 20)
        session += [500, 520]
        session += Array(repeating: 800.0, count: 20)

        let (clean, rejected) = HRVCalculator.filterArtefacts(session)
        #expect(rejected == 2)
        #expect(Set(clean) == [800])

        let metrics = try #require(HRVCalculator.metrics(from: session))
        #expect(metrics.rmssd == 0)
        #expect(metrics.artefactFraction > 0)
    }

    @Test("Scattered noise is never laundered into a change of rhythm")
    func inconsistentNoiseStaysRejected() throws {
        // A burst of mutually contradictory intervals — the signature of a sensor losing
        // contact, not of a heart changing rate. The re-seed path must not fire, the noise
        // must stay counted, and the rhythm must be picked up again afterwards.
        var session = Array(repeating: 800.0, count: 25)
        session += [420, 1500, 460, 1400, 430, 1450]
        session += Array(repeating: 800.0, count: 25)

        let (clean, rejected) = HRVCalculator.filterArtefacts(session)
        #expect(rejected == 6)
        #expect(Set(clean) == [800])
        #expect(clean.count == 50)

        let metrics = try #require(HRVCalculator.metrics(from: session))
        #expect(metrics.rmssd == 0)
        #expect(metrics.artefactFraction > 0)
    }

    /// The documented cost of not stalling, pinned so that it is a decision rather than a
    /// surprise. Three consecutive intervals that agree with each other are indistinguishable
    /// from a rate change by this heuristic, so a three-beat ectopic run is accepted — and,
    /// unlike the couplet above, it inflates RMSSD while the window still reports itself as
    /// artefact-free. Tightening the filter should change this test knowingly.
    @Test("A three-beat run at a new rate is read as a rhythm change, and that inflates RMSSD")
    func threeBeatRunIsAcceptedAsARateChange() throws {
        var session = Array(repeating: 800.0, count: 20)
        session += [500, 520, 510]
        session += Array(repeating: 800.0, count: 20)

        let baseline = try #require(HRVCalculator.metrics(from: Array(repeating: 800.0, count: 40)))
        let metrics = try #require(HRVCalculator.metrics(from: session))

        #expect(metrics.artefactFraction == 0)
        #expect(baseline.rmssd == 0)
        #expect(metrics.rmssd > 50)
    }

    // MARK: Honesty about the window

    @Test("artefactFraction counts every supplied beat, whatever rejected it")
    func artefactFractionCountsBothFilters() throws {
        // One beat fails the absolute range check and one fails the relative check. A
        // fraction computed only over the second pass would report half the truth.
        var session = Array(repeating: 800.0, count: 30)
        session.insert(2500, at: 10)   // out of range
        session.insert(400, at: 20)    // in range, ectopic

        let metrics = try #require(HRVCalculator.metrics(from: session))
        #expect(metrics.beatCount == 30)
        #expect(abs(metrics.artefactFraction - 2.0 / 32.0) < 1e-12)
    }

    @Test("A window past a quarter rejected beats is not presented as reliable")
    func maximumArtefactFractionHolds() throws {
        #expect(HRVMetrics.maximumArtefactFraction == 0.25)

        // Exactly a quarter rejected is the last acceptable window.
        let atLimit = try #require(HRVCalculator.metrics(
            from: Array(repeating: 800.0, count: 30) + Array(repeating: 2500.0, count: 10)
        ))
        #expect(atLimit.artefactFraction == 0.25)
        #expect(atLimit.isReliable)

        // One more rejected beat and the window is no longer trustworthy, even though it
        // still holds thirty perfectly clean beats and would produce a confident number.
        let pastLimit = try #require(HRVCalculator.metrics(
            from: Array(repeating: 800.0, count: 30) + Array(repeating: 2500.0, count: 11)
        ))
        #expect(pastLimit.beatCount == 30)
        #expect(pastLimit.artefactFraction > HRVMetrics.maximumArtefactFraction)
        #expect(!pastLimit.isReliable)
    }

    @Test("Twenty clean beats is the floor below which HRV means nothing")
    func minimumBeatsHolds() throws {
        #expect(HRVMetrics.minimumBeats == 20)

        let justUnder = try #require(HRVCalculator.metrics(from: Array(repeating: 800.0, count: 19)))
        #expect(justUnder.beatCount == 19)
        #expect(justUnder.artefactFraction == 0)   // nothing wrong with these beats
        #expect(!justUnder.isReliable)             // there are simply not enough of them

        let justOver = try #require(HRVCalculator.metrics(from: Array(repeating: 800.0, count: 20)))
        #expect(justOver.isReliable)
    }

    @Test("Implied heart rate is the rate the surviving intervals themselves imply")
    func impliedHeartRateMatchesTheIntervals() throws {
        // The cross-check the UI puts in front of the user: a device whose R–R intervals
        // imply a different rate from the heart rate it reports directly is disagreeing
        // with itself. That only means anything if this number is exactly 60000 / mean.
        let metrics = try #require(HRVCalculator.metrics(from: Array(repeating: 750.0, count: 30)))
        let quality = HRVQuality(metrics: metrics, measuredAt: epoch)
        #expect(abs(quality.impliedHeartRate - 80) < 1e-9)
        #expect(quality.beatCount == 30)
        #expect(quality.measuredAt == epoch)

        // Rejected beats must not drag it. A dropped beat read as one 2500 ms interval
        // would pull a 30-beat window from 80 bpm to about 77 if it were averaged in.
        let withArtefact = try #require(HRVCalculator.metrics(
            from: Array(repeating: 750.0, count: 30) + [2500]
        ))
        #expect(abs(HRVQuality(metrics: withArtefact, measuredAt: epoch).impliedHeartRate - 80) < 1e-9)
        #expect(withArtefact.artefactFraction > 0)
    }

    @Test("Implied heart rate follows an uneven window rather than any single beat")
    func impliedHeartRateOnAnUnevenWindow() throws {
        // 20 beats at 1000 ms and 20 at 850 ms: mean 925 ms, so 64.86 bpm. Reporting the
        // first, last, or modal interval instead would give 60 or 70.6.
        let session = Array(repeating: 1000.0, count: 20) + Array(repeating: 850.0, count: 20)
        let metrics = try #require(HRVCalculator.metrics(from: session))
        let clean = HRVCalculator.filterArtefacts(session).clean
        let mean = clean.reduce(0, +) / Double(clean.count)

        #expect(clean.count == session.count)
        #expect(abs(metrics.meanHeartRate - 60_000 / mean) < 1e-9)
        #expect(abs(metrics.meanHeartRate - 60_000 / 925) < 1e-9)
    }
}

/// Body Sensor Location is placement evidence only. Sensor technology is an independent,
/// optional fact and must never be inferred from these values. The location is persisted in
/// source metadata, which makes its raw values a storage contract rather than an
/// implementation detail.
@Suite("Body sensor location")
struct BodySensorLocationTests {

    /// Mirrors the legacy archive coders used during SQLite migration.
    private var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("Placement and sensor technology remain independent")
    func placementDoesNotImplyTechnology() {
        let chestSource = DataSource(
            id: "chest",
            displayName: "Chest sensor",
            transport: .bluetooth,
            bodyLocation: .chest
        )
        let knownOptical = DataSource(
            id: "finger",
            displayName: "Finger sensor",
            transport: .bluetooth,
            bodyLocation: .finger,
            sensingTechnology: .opticalPPG
        )

        #expect(chestSource.bodyLocation == .chest)
        #expect(chestSource.sensingTechnology == nil)
        #expect(knownOptical.bodyLocation == .finger)
        #expect(knownOptical.sensingTechnology == .opticalPPG)
    }

    @Test("Location raw values are the SIG numbers stored sources depend on")
    func rawValuesAreAStorageContract() throws {
        // Renumbering any of these silently repoints every device already in sources.json
        // at a different part of the body.
        #expect(BodySensorLocation.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6])
        #expect(BodySensorLocation(rawValue: 1) == .chest)
        #expect(BodySensorLocation(rawValue: 3) == .finger)

        // And they are what reaches JSON, not the case names.
        let encoded = try JSONEncoder().encode([BodySensorLocation.chest, .finger])
        #expect(String(decoding: encoded, as: UTF8.self) == "[1,3]")
        #expect(try JSONDecoder().decode([BodySensorLocation].self, from: Data("[2,0]".utf8)) == [.wrist, .other])
    }

    @Test("An unrecognised location value is rejected rather than coerced")
    func unknownRawValueIsNotCoerced() {
        // 7 and above are unassigned. Reading one as `.other` would be harmless; reading
        // one as `.chest` would not, and neither is a guess worth making.
        #expect(BodySensorLocation(rawValue: 7) == nil)
        #expect(BodySensorLocation(rawValue: 255) == nil)
    }

    @Test("A source round-trips through sources.json with and without a body location")
    func dataSourceRoundTrip() throws {
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let strap = DataSource(
            id: "0A1B2C3D-0000-0000-0000-000000000001",
            displayName: "Chest Strap",
            transport: .bluetooth,
            model: "H10",
            colorIndex: 2,
            addedAt: addedAt,
            observedMetrics: [.heartRate, .hrvRMSSD],
            batteryPercent: 88,
            bodyLocation: .chest
        )
        let ring = DataSource(
            id: DataSource.ouraSourceID,
            displayName: "Oura",
            transport: .oura,
            addedAt: addedAt
        )

        let data = try archiveEncoder.encode([strap, ring])
        let decoded = try archiveDecoder.decode([DataSource].self, from: data)

        #expect(decoded == [strap, ring])
        #expect(decoded[0].bodyLocation == .chest)
        // A cloud source has no body location and must not acquire one in transit.
        #expect(decoded[1].bodyLocation == nil)
    }

    @Test("A sources.json written before body location existed still decodes")
    func legacyArchiveWithoutBodyLocationDecodes() throws {
        // Hand-written to match what shipped before `bodyLocation` was added. If the field
        // were ever made non-optional this would throw, and every user upgrading would
        // lose their configured devices along with the readings keyed to them.
        let legacy = """
        [
          {
            "id": "0A1B2C3D-0000-0000-0000-000000000001",
            "displayName": "Chest Strap",
            "transport": "bluetooth",
            "model": "H10",
            "colorIndex": 2,
            "isEnabled": true,
            "addedAt": "2025-01-02T03:04:05Z",
            "lastSeenAt": "2025-01-02T04:05:06Z",
            "observedMetrics": ["heartRate", "hrvRMSSD"],
            "batteryPercent": 88
          }
        ]
        """
        let decoded = try archiveDecoder.decode([DataSource].self, from: Data(legacy.utf8))
        let source = try #require(decoded.first)

        #expect(decoded.count == 1)
        #expect(source.displayName == "Chest Strap")
        #expect(source.observedMetrics == [.heartRate, .hrvRMSSD])
        #expect(source.batteryPercent == 88)
        #expect(source.addedAt == Date(timeIntervalSince1970: 1_735_787_045))
        // The whole point: an absent field reads as "unknown", not as a decode failure and
        // not as a default location the device never reported.
        #expect(source.bodyLocation == nil)
    }

    @Test("Learning where a sensor sits does not disturb the rest of the source")
    @MainActor
    func storeRecordsBodyLocationWithoutSideEffects() throws {
        // Body Sensor Location is read once on connect, after the source already exists,
        // so it arrives as an update to a stored device rather than as part of its
        // creation. Nothing else about the device may change on the way through.
        let store = HealthStore(persistenceEnabled: false)
        let added = store.upsert(DataSource(
            id: "device-a",
            displayName: "Chest Strap",
            transport: .bluetooth,
            model: "H10",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            observedMetrics: [.heartRate]
        ))

        store.setBodyLocation(.chest, forSource: "device-a")
        let updated = try #require(store.source(id: "device-a"))

        #expect(updated.bodyLocation == .chest)
        #expect(updated.displayName == added.displayName)
        #expect(updated.colorIndex == added.colorIndex)
        #expect(updated.observedMetrics == added.observedMetrics)

        // An unknown device must not be conjured into existence by a stray notification.
        store.setBodyLocation(.wrist, forSource: "never-seen")
        #expect(store.source(id: "never-seen") == nil)
    }

    @Test("Re-registering a device on reconnect does not erase its known body location")
    @MainActor
    func reconnectPreservesBodyLocation() throws {
        // On every reconnect the Bluetooth manager upserts the peripheral again, from an
        // advertisement that carries no body location. Losing the field there would discard
        // reported placement evidence on each reconnect.
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "device-a", displayName: "Chest Strap", transport: .bluetooth))
        store.setBodyLocation(.chest, forSource: "device-a")

        store.upsert(DataSource(id: "device-a", displayName: "Chest Strap", transport: .bluetooth))
        #expect(store.source(id: "device-a")?.bodyLocation == .chest)

        // A device that later reports a different location is believed, though.
        store.upsert(DataSource(
            id: "device-a",
            displayName: "Chest Strap",
            transport: .bluetooth,
            bodyLocation: .wrist
        ))
        #expect(store.source(id: "device-a")?.bodyLocation == .wrist)
    }
}
