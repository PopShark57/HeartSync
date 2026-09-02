import Foundation
import Testing
@testable import HeartSyncChecker

// MARK: - Fixtures

/// A fixed instant so nothing in this file depends on when it runs.
private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

private let day: TimeInterval = 86_400

private func at(_ offset: TimeInterval) -> Date { anchor.addingTimeInterval(offset) }

private func sample(
    _ sourceID: String,
    _ value: Double,
    at date: Date,
    kind: MetricKind = .heartRate,
    id: UUID = UUID(),
    provenance: Provenance = .measured
) -> Reading {
    Reading(id: id, sourceID: sourceID, kind: kind, value: value, start: date, provenance: provenance)
}

@MainActor
private func makeStore(sources sourceIDs: [String] = ["alpha", "bravo"]) -> HealthStore {
    let store = HealthStore(persistenceEnabled: false)
    for id in sourceIDs {
        store.upsert(DataSource(
            id: id,
            displayName: id,
            transport: .bluetooth,
            addedAt: at(-90 * day)
        ))
    }
    return store
}

/// Asserts the store's two side indexes still describe the array they index.
///
/// This is the whole point of the index-consistency suite: `readings(kind:)` is served from
/// `kindIndex` and identity is served from `idIndex`, so a stale entry in either does not
/// crash — it silently returns the wrong reading, or lets a duplicate in. Each probe below
/// reaches an index through public behaviour rather than through the private storage:
///
/// - order: every mutation must leave `readings` ascending by `end`;
/// - `kindIndex`: a metric query must equal a manual filter over `readings`, which fails if
///   a position is stale (wrong reading returned) or dropped (short result);
/// - `idIndex`: re-`upsert`ing the store's own contents must report nothing changed, which
///   fails if an id maps to a position holding a different reading, or is missing entirely.
@MainActor
private func expectSelfConsistent(_ store: HealthStore, after step: String) {
    let ends = store.readings.map(\.end)
    #expect(
        zip(ends, ends.dropFirst()).allSatisfy { $0 <= $1 },
        "\(step): readings are no longer in ascending end order"
    )

    for kind in MetricKind.allCases {
        let viaIndex = store.readings(kind: kind, enabledOnly: false)
        let viaScan = store.readings.filter { $0.kind == kind }
        #expect(
            viaIndex == viaScan,
            "\(step): the metric index disagrees with a manual scan for \(kind.rawValue)"
        )
    }

    let reportedAsChanged = store.upsert(contentsOf: store.readings)
    #expect(
        reportedAsChanged.isEmpty,
        "\(step): the identity index no longer resolves \(reportedAsChanged.count) of its own readings"
    )

    for source in store.sources {
        for kind in MetricKind.allCases {
            let viaIndex = store.latest(kind: kind, sourceID: source.id)
            let viaScan = store.readings.last { $0.kind == kind && $0.sourceID == source.id }
            #expect(
                viaIndex == viaScan,
                "\(step): latest(\(kind.rawValue), \(source.id)) disagrees with a manual scan"
            )
        }
    }
}

// MARK: - Ingestion and identity

@Suite("Health store ingestion")
@MainActor
struct HealthStoreIngestionTests {

    @Test("A re-delivered batch stores nothing and reports nothing")
    func duplicateBatchIsIgnored() {
        let store = makeStore()
        let batch = (0..<3).map { sample("alpha", 70 + Double($0), at: at(Double($0) * 10)) }

        #expect(store.append(contentsOf: batch).count == 3)
        // HealthKit re-delivers samples after an anchor reset and Oura repeats page
        // boundaries; both arrive here as the exact same batch a second time.
        #expect(store.append(contentsOf: batch).isEmpty)
        #expect(store.readings.count == 3)
    }

    @Test("Ingestion returns exactly the readings it stored, never the duplicates")
    func returnsOnlyTheAcceptedReadings() {
        // AppModel mirrors this array into Apple Health. Returning a duplicate would write
        // a second copy of an existing sample into the user's health record.
        let store = makeStore()
        let existing = (0..<3).map { sample("alpha", 70 + Double($0), at: at(Double($0) * 10)) }
        store.append(contentsOf: existing)

        let fresh = sample("alpha", 77, at: at(40))
        let accepted = store.append(contentsOf: existing + [fresh])

        #expect(accepted == [fresh])
        #expect(store.readings.count == 4)
    }

    @Test("A batch that repeats an id inside itself stores it once")
    func duplicateInsideOneBatch() {
        let store = makeStore()
        let id = UUID()
        let accepted = store.append(contentsOf: [
            sample("alpha", 70, at: at(0), id: id),
            sample("alpha", 99, at: at(30), id: id),
        ])

        #expect(accepted.count == 1)
        #expect(store.readings.count == 1)
        #expect(store.readings[0].value == 70)
    }

    @Test("Implausible values are dropped and the rest of the batch survives")
    func rejectsImplausibleValues() {
        let store = makeStore()
        let accepted = store.append(contentsOf: [
            sample("alpha", 70, at: at(0)),
            sample("alpha", 400, at: at(10)),   // above the 250 bpm ceiling
            sample("alpha", 4, at: at(20)),     // below the 20 bpm floor
            sample("alpha", 72, at: at(30)),
        ])

        #expect(accepted.map(\.value) == [70, 72])
        #expect(store.readings.count == 2)
    }

    @Test("Invalid and future intervals are rejected before storage")
    func rejectsInvalidDates() {
        let store = makeStore(sources: ["alpha"])
        let future = Date(timeIntervalSinceNow: 86_400)
        let reversed = Reading(
            sourceID: "alpha",
            kind: .heartRate,
            value: 71,
            start: at(20),
            end: at(10)
        )
        let accepted = store.append(contentsOf: [
            sample("alpha", 70, at: at(0)),
            Reading(sourceID: "alpha", kind: .heartRate, value: 72, start: future),
            reversed,
        ])

        #expect(accepted.map(\.value) == [70])
        #expect(store.readings.count == 1)
    }

    @Test("Plausibility is judged per metric, not against one global range")
    func plausibilityIsPerMetric() {
        let store = makeStore()
        // 45 is an ordinary resting heart rate and an impossible blood oxygen saturation.
        let accepted = store.append(contentsOf: [
            sample("alpha", 45, at: at(0), kind: .heartRate),
            sample("alpha", 45, at: at(0), kind: .spo2),
        ])

        #expect(accepted.count == 1)
        #expect(accepted[0].kind == .heartRate)
    }

    @Test("Batches landing before, across and after existing data all end up in time order")
    func outOfOrderBatchesAreSorted() {
        let store = makeStore()
        store.append(contentsOf: [
            sample("alpha", 70, at: at(100)),
            sample("alpha", 71, at: at(200)),
        ])
        // Entirely before.
        store.append(contentsOf: [sample("alpha", 68, at: at(10)), sample("alpha", 69, at: at(20))])
        // Straddling.
        store.append(contentsOf: [sample("alpha", 72, at: at(150)), sample("alpha", 73, at: at(250))])
        // Entirely after.
        store.append(contentsOf: [sample("alpha", 74, at: at(400))])

        #expect(store.readings.map { $0.end.timeIntervalSince(anchor) } == [10, 20, 100, 150, 200, 250, 400])
        expectSelfConsistent(store, after: "interleaved out-of-order batches")
    }

    @Test("Readings sharing an end date keep a deterministic order across repeated ingestion")
    func tiesAreDeterministic() {
        let ids = (0..<3).map { _ in UUID() }

        func build() -> [UUID] {
            let store = makeStore()
            store.append(contentsOf: [
                sample("alpha", 70, at: at(0), id: ids[0]),
                sample("alpha", 71, at: at(0), id: ids[1]),
            ])
            store.append(contentsOf: [sample("alpha", 72, at: at(0), id: ids[2])])
            return store.readings.map(\.id)
        }

        #expect(build() == ids)
        #expect(build() == build())
    }

    @Test("An incoming reading never jumps ahead of a stored reading with the same end date")
    func tiesFavourStoredReadings() {
        let store = makeStore()
        let first = sample("alpha", 70, at: at(0))
        let later = sample("alpha", 71, at: at(60))
        store.append(contentsOf: [first, later])

        // Forces the merge path rather than the append-past-the-tail fast path, and must
        // resolve the tie at t=0 the same way the fast path did.
        let tied = sample("alpha", 72, at: at(0))
        store.append(contentsOf: [tied])

        #expect(store.readings.map(\.id) == [first.id, tied.id, later.id])
        expectSelfConsistent(store, after: "a tied merge")
    }

    @Test("Appending an id the store already holds never overwrites the stored value")
    func appendIsNotAnUpsert() {
        let store = makeStore()
        let id = UUID()
        store.append(contentsOf: [sample("alpha", 70, at: at(0), id: id)])

        let accepted = store.append(contentsOf: [sample("alpha", 190, at: at(0), id: id)])

        #expect(accepted.isEmpty)
        #expect(store.readings.map(\.value) == [70])
    }

    @Test("A revision replaces its record instead of duplicating it")
    func upsertReplacesInPlace() {
        let store = makeStore()
        let id = UUID()
        store.append(contentsOf: [
            sample("alpha", 70, at: at(0), id: id),
            sample("alpha", 71, at: at(60)),
        ])

        // Oura recalculates sleep and daily documents after first publication, which can
        // move a value in time as well as change it.
        let revised = sample("alpha", 66, at: at(120), id: id)
        let changed = store.upsert(contentsOf: [revised])

        #expect(changed == [revised])
        #expect(store.readings.count == 2)
        #expect(store.readings.last == revised)
        expectSelfConsistent(store, after: "a revision that moved in time")
    }

    @Test("An identical resend changes nothing and reports nothing")
    func upsertOfIdenticalRecordIsSilent() {
        let store = makeStore()
        let batch = [sample("alpha", 70, at: at(0)), sample("alpha", 71, at: at(60))]
        #expect(store.upsert(contentsOf: batch).count == 2)

        // A caller treats a non-empty result as "there is new data", so an unchanged
        // document must not look like one.
        #expect(store.upsert(contentsOf: batch).isEmpty)
        #expect(store.readings.count == 2)
    }

    @Test("A revised batch reports only the records that actually changed")
    func upsertReportsOnlyRealChanges() {
        let store = makeStore()
        let unchangedID = UUID()
        let revisedID = UUID()
        let unchanged = sample("alpha", 70, at: at(0), id: unchangedID)
        store.upsert(contentsOf: [unchanged, sample("alpha", 71, at: at(60), id: revisedID)])

        let revised = sample("alpha", 64, at: at(60), id: revisedID)
        let fresh = sample("alpha", 65, at: at(120))
        let changed = store.upsert(contentsOf: [unchanged, revised, fresh])

        #expect(changed == [revised, fresh])
        #expect(store.readings.count == 3)
    }

    @Test("Ingestion records which metrics a source has actually produced, and when")
    func ingestionRecordsCapability() throws {
        let store = makeStore()
        store.append(contentsOf: [
            sample("alpha", 70, at: at(0)),
            sample("alpha", 97, at: at(60), kind: .spo2),
            sample("bravo", 71, at: at(30)),
        ])

        let alpha = try #require(store.source(id: "alpha"))
        #expect(alpha.observedMetrics == [.heartRate, .spo2])
        #expect(alpha.lastSeenAt == at(60))
        #expect(try #require(store.source(id: "bravo")).observedMetrics == [.heartRate])
    }
}

// MARK: - Index consistency

@Suite("Health store index consistency")
@MainActor
struct HealthStoreIndexTests {

    @Test("Every kind of mutation leaves both indexes describing the array they index")
    func indexesSurviveEveryMutation() throws {
        let store = makeStore()
        store.retention = 24 * day

        let revisedID = UUID()
        let doomedA = UUID()
        let doomedB = UUID()

        // 1. An ordinary batch, appended past the tail.
        store.append(contentsOf: [
            sample("alpha", 70, at: at(-20 * day), id: revisedID),
            sample("alpha", 74, at: at(-20 * day + 10)),
            sample("alpha", 78, at: at(-20 * day + 20), id: doomedA),
            sample("bravo", 71, at: at(-20 * day + 5)),
            sample("bravo", 72, at: at(-20 * day + 15), id: doomedB),
            sample("alpha", 97, at: at(-20 * day + 1), kind: .spo2),
            // Two rows nothing later removes or revises, so the aged window still holds
            // more than one reading by the time compaction runs.
            sample("alpha", 76, at: at(-20 * day + 30)),
            sample("alpha", 80, at: at(-20 * day + 40)),
        ])
        expectSelfConsistent(store, after: "an initial append")

        // 2. A batch that lands entirely before everything stored, forcing a real merge.
        store.append(contentsOf: [
            sample("alpha", 60, at: at(-25 * day)),
            sample("alpha", 62, at: at(-25 * day + 10)),
            sample("alpha", 64, at: at(-25 * day + 20)),
        ])
        expectSelfConsistent(store, after: "a batch merged in ahead of existing data")

        // 3. A revision that moves an existing reading in time.
        store.upsert(contentsOf: [sample("alpha", 66, at: at(-19 * day), id: revisedID)])
        expectSelfConsistent(store, after: "an upsert that moved a reading")

        // 4. Targeted removal.
        #expect(store.remove(readingIDs: [doomedA, doomedB]) == 2)
        expectSelfConsistent(store, after: "remove(readingIDs:)")

        // 5. Removing a whole source.
        #expect(store.remove(sourceID: "bravo"))
        #expect(store.readings.allSatisfy { $0.sourceID != "bravo" })
        expectSelfConsistent(store, after: "remove(sourceID:)")

        // 6. Retention, cutting exactly at a boundary.
        store.prune(now: anchor)
        #expect(store.readings.allSatisfy { $0.end >= at(-24 * day) })
        expectSelfConsistent(store, after: "prune")

        // 7. Compaction of the aged remainder.
        store.compact(now: anchor)
        expectSelfConsistent(store, after: "compact")

        // The sequence must actually have exercised compaction, or step 7 proves nothing.
        let aged = store.readings.filter { $0.end <= at(-17 * day) }
        #expect(aged.contains { $0.end.timeIntervalSince($0.start) == MetricKind.heartRate.comparisonWindow })
    }

    @Test("Compaction leaves every surviving reading reachable through the metric index")
    func compactionKeepsMetricQueriesHonest() {
        let store = makeStore()
        for offset in stride(from: 0.0, to: 40.0, by: 10.0) {
            store.append(contentsOf: [
                sample("alpha", 70 + offset / 10, at: at(-20 * day + offset)),
                sample("bravo", 80 + offset / 10, at: at(-20 * day + offset)),
                sample("alpha", 96 + offset / 10, at: at(-20 * day + offset), kind: .spo2),
            ])
        }
        store.compact(now: anchor)

        expectSelfConsistent(store, after: "compaction across two metrics and two sources")
        #expect(store.readings(kind: .heartRate, enabledOnly: false).count == 2)
        #expect(store.readings(kind: .spo2, enabledOnly: false).count == 1)
    }
}

// MARK: - Removal and retention

@Suite("Health store removal and retention")
@MainActor
struct HealthStoreRemovalTests {

    @Test("Removing readings by id removes exactly those and leaves the rest alone")
    func removeByID() {
        let store = makeStore()
        let doomed = UUID()
        let kept = UUID()
        store.append(contentsOf: [
            sample("alpha", 70, at: at(0), id: doomed),
            sample("alpha", 71, at: at(60), id: kept),
        ])

        // An id the store never held must not be counted as a removal.
        #expect(store.remove(readingIDs: [doomed, UUID()]) == 1)
        #expect(store.readings.map(\.id) == [kept])
        expectSelfConsistent(store, after: "remove(readingIDs:)")
    }

    @Test("A source that once reported a metric still did, even after its readings are deleted")
    func removalKeepsObservedCapability() throws {
        // Re-deriving capability from surviving rows would make the device list flicker as
        // history ages out, so an upstream deletion must not retract it.
        let store = makeStore()
        let doomed = UUID()
        store.append(contentsOf: [sample("alpha", 70, at: at(0), id: doomed)])
        store.remove(readingIDs: [doomed])

        #expect(try #require(store.source(id: "alpha")).observedMetrics == [.heartRate])
    }

    @Test("Removing a source removes its readings and nobody else's")
    func removeBySource() {
        let store = makeStore()
        store.append(contentsOf: [
            sample("alpha", 70, at: at(0)),
            sample("bravo", 71, at: at(10)),
            sample("alpha", 72, at: at(20)),
            sample("bravo", 73, at: at(30)),
        ])

        store.remove(sourceID: "bravo")

        #expect(store.source(id: "bravo") == nil)
        #expect(store.source(id: "alpha") != nil)
        #expect(store.readings.map(\.value) == [70, 72])
        #expect(!store.remove(sourceID: "bravo"))
        expectSelfConsistent(store, after: "remove(sourceID:)")
    }

    @Test("Retention drops what is past the horizon and keeps what sits exactly on it")
    func pruneBoundary() {
        let store = makeStore()
        store.retention = 3600
        store.append(contentsOf: [
            sample("alpha", 70, at: at(-3601)),   // one second too old
            sample("alpha", 71, at: at(-3600)),   // exactly on the horizon
            sample("alpha", 72, at: at(-10)),
        ])

        store.prune(now: anchor)

        #expect(store.readings.map(\.value) == [71, 72])
        expectSelfConsistent(store, after: "prune at the boundary")
    }

    @Test("Pruning removes future rows and clamps future source status")
    func pruneFutureRows() throws {
        let store = makeStore(sources: ["alpha"])
        store.append(contentsOf: [
            sample("alpha", 70, at: at(0)),
            sample("alpha", 71, at: at(60)),
        ])

        store.prune(now: anchor)

        #expect(store.readings.map(\.value) == [70])
        #expect(try #require(store.source(id: "alpha")).lastSeenAt == anchor)
    }

    @Test("A prune that empties the store also forgets the ids it held")
    func pruneEverything() {
        let store = makeStore()
        store.retention = 3600
        let reading = sample("alpha", 70, at: at(-7200))
        store.append(contentsOf: [reading])

        store.prune(now: anchor)
        #expect(store.readings.isEmpty)

        // A stale identity index would silently reject this as a duplicate.
        #expect(store.append(contentsOf: [reading]).count == 1)
        expectSelfConsistent(store, after: "re-appending a pruned reading")
    }

    @Test("Deleting all readings keeps the devices but retracts every claim about them")
    func deleteAllReadings() throws {
        let store = makeStore()
        store.append(contentsOf: [
            sample("alpha", 70, at: at(0)),
            sample("bravo", 97, at: at(60), kind: .spo2),
        ])
        #expect(try #require(store.source(id: "alpha")).lastSeenAt == at(0))

        store.deleteAllReadings()

        #expect(store.readings.isEmpty)
        #expect(store.sources.count == 2)
        for source in store.sources {
            #expect(source.observedMetrics.isEmpty)
            // A source whose history was just wiped has no evidence left for a recent
            // sighting; leaving the timestamp made the device list claim data that is gone.
            #expect(source.lastSeenAt == nil)
        }
        #expect(store.availableMetrics.isEmpty)
        expectSelfConsistent(store, after: "deleteAllReadings")
    }
}

// MARK: - Compaction

@Suite("Health store compaction")
@MainActor
struct HealthStoreCompactionTests {

    /// One dense 60 s heart-rate window, `age` before the anchor, from one source.
    private func denseWindow(
        _ sourceID: String,
        values: [Double],
        age: TimeInterval,
        kind: MetricKind = .heartRate,
        provenances: [Provenance]? = nil
    ) -> [Reading] {
        values.enumerated().map { index, value in
            sample(
                sourceID,
                value,
                at: at(-age + Double(index)),
                kind: kind,
                provenance: provenances?[index] ?? .measured
            )
        }
    }

    @Test("Readings newer than the compaction age are never touched")
    func recentReadingsAreUntouched() {
        let store = makeStore()
        let recent = denseWindow("alpha", values: [70, 71, 72], age: day)
        store.append(contentsOf: denseWindow("alpha", values: [60, 61, 62], age: 20 * day))
        store.append(contentsOf: recent)

        store.compact(now: anchor)

        #expect(store.readings.filter { $0.end > at(-2 * day) } == recent)
    }

    @Test("An aged window collapses to one reading per source at the median the analysis would compute")
    func agedWindowCollapsesToTheMedian() throws {
        let store = makeStore()
        let alpha = denseWindow("alpha", values: [60, 90, 62, 61, 200], age: 20 * day)
        let bravo = denseWindow("bravo", values: [80, 82, 81], age: 20 * day)
        store.append(contentsOf: alpha + bravo)

        store.compact(now: anchor)

        #expect(store.readings.count == 2)
        let compactedAlpha = try #require(store.readings.first { $0.sourceID == "alpha" })
        let compactedBravo = try #require(store.readings.first { $0.sourceID == "bravo" })

        // The stored value must be exactly what ComparisonEngine would have produced from
        // the raw rows; that equality is the entire argument for compaction being lossless
        // as far as any analysis is concerned.
        #expect(compactedAlpha.value == ComparisonEngine.aggregate(alpha, sourceID: "alpha").value)
        #expect(compactedAlpha.value == 62)
        #expect(compactedBravo.value == ComparisonEngine.aggregate(bravo, sourceID: "bravo").value)
        #expect(compactedBravo.value == 81)

        // It spans its window rather than pretending to be an instant sample.
        let windowStart = ComparisonEngine.floorToWindow(alpha[0].midpoint, size: 60)
        #expect(compactedAlpha.start == windowStart)
        #expect(compactedAlpha.end == windowStart.addingTimeInterval(60))
    }

    @Test("A second compaction pass changes nothing")
    func compactionIsIdempotent() {
        let store = makeStore()
        store.append(contentsOf: denseWindow("alpha", values: [60, 90, 62], age: 20 * day))
        store.append(contentsOf: denseWindow("bravo", values: [80, 82, 81], age: 20 * day))

        store.compact(now: anchor)
        let afterFirstPass = store.readings
        store.compact(now: anchor)

        #expect(store.readings == afterFirstPass)
        expectSelfConsistent(store, after: "a repeated compaction pass")
    }

    @Test("A window already holding a single reading is left completely alone")
    func lonelyWindowSurvivesIntact() {
        let store = makeStore()
        let lonely = sample("alpha", 55, at: at(-20 * day - 600))
        store.append(contentsOf: [lonely])
        // A dense window elsewhere, so compaction genuinely runs rather than bailing out.
        store.append(contentsOf: denseWindow("alpha", values: [60, 62, 64], age: 20 * day))

        store.compact(now: anchor)

        // Same id, same instant, same value: sparse data (daily summaries, Oura documents)
        // must survive compaction untouched.
        #expect(store.readings.contains(lonely))
        #expect(store.readings.count == 2)
    }

    @Test("The compaction age cannot be lowered below the fourteen-day floor")
    func compactionAgeFloor() {
        let store = makeStore()
        store.compactionAge = 60
        #expect(store.compactionAge == HealthStore.minimumCompactionAge)

        store.compactionAge = 20 * day
        #expect(store.compactionAge == 20 * day)

        store.compactionAge = -1
        #expect(store.compactionAge == HealthStore.minimumCompactionAge)
    }

    @Test("Two-day-old data is never compacted, whatever the compaction age is set to")
    func floorIsEnforcedInBehaviourNotJustInTheSetter() {
        // Oura re-syncs a rolling 14-day window, so collapsing anything newer would be
        // undone by the very next sync.
        let store = makeStore()
        store.compactionAge = 1
        let recent = denseWindow("alpha", values: [70, 71, 72], age: 2 * day)
        store.append(contentsOf: recent)

        store.compact(now: anchor)

        #expect(store.readings == recent)
    }

    @Test("A window containing a measured reading stays measured")
    func provenanceSurvivesCompaction() throws {
        let store = makeStore()
        store.append(contentsOf: denseWindow(
            "alpha",
            values: [60, 62, 64],
            age: 20 * day,
            provenances: [.derived, .measured, .derived]
        ))
        store.append(contentsOf: denseWindow(
            "bravo",
            values: [80, 82, 84],
            age: 20 * day,
            provenances: [.derived, .derived, .derived]
        ))

        store.compact(now: anchor)

        #expect(try #require(store.readings.first { $0.sourceID == "alpha" }).provenance == .measured)
        #expect(try #require(store.readings.first { $0.sourceID == "bravo" }).provenance == .derived)
    }

    @Test("Compaction does not change a pairwise verdict")
    func compactionPreservesThePairwiseVerdict() throws {
        // The justification for a lossy, irreversible downsample is that what it keeps is
        // exactly what every analysis consumes. If a verdict can move, that argument fails.
        let store = makeStore()
        let base = -20 * day
        for window in 0..<6 {
            let start = base + Double(window) * 60
            store.append(contentsOf: [
                sample("alpha", 70, at: at(start + 1)),
                sample("alpha", 74, at: at(start + 11)),
                sample("alpha", 66, at: at(start + 21)),
                sample("bravo", 78, at: at(start + 6)),
                sample("bravo", 82, at: at(start + 16)),
                sample("bravo", 180, at: at(start + 26)),   // a motion artefact the median absorbs
            ])
        }
        let range = DateInterval(start: at(base - 60), end: at(base + 7 * 60))

        func analysis() -> PairwiseAnalysis {
            ComparisonEngine.pairwiseAnalysis(
                from: store.readings(kind: .heartRate, in: range),
                kind: .heartRate,
                sourceA: "alpha",
                sourceB: "bravo",
                range: range
            )
        }

        let before = analysis()
        let statisticsBefore = try #require(before.statistics)
        store.compact(now: anchor)
        let after = analysis()
        let statisticsAfter = try #require(after.statistics)

        #expect(store.readings.count == 12)   // it really did collapse 36 rows
        #expect(after.pairedWindowCount == before.pairedWindowCount)
        #expect(after.observations.map(\.signedDifference) == before.observations.map(\.signedDifference))
        #expect(statisticsAfter.meanBias == statisticsBefore.meanBias)
        #expect(statisticsAfter.meanAbsoluteDifference == statisticsBefore.meanAbsoluteDifference)
        #expect(statisticsAfter.differenceSD == statisticsBefore.differenceSD)
        #expect(statisticsAfter.severity == statisticsBefore.severity)
        #expect(statisticsAfter.classification == statisticsBefore.classification)
        #expect(after.state == before.state)
    }

    @Test("Compaction walks forward instead of stalling behind history it has already collapsed")
    func compactionDrainsTheBacklog() {
        // `compact(now:)` bounds each pass to `compactionSpanPerPass` of history measured
        // from the OLDEST retained reading, and the documented contract is that "subsequent
        // saves walk forward until the backlog is gone".
        //
        // Both bands below are older than the 14-day compaction age and both are dense, so
        // every pass here is free to do work. The first band, inside the first pass's span,
        // collapses. The second band is 5 days newer, so no number of further passes ever
        // reaches it: collapsing a window replaces its rows with a reading that starts at
        // the same window start, so `readings.first` — and therefore the cutoff — does not
        // move, and the next pass finds nothing left to do and returns early. The backlog
        // only ever drains as fast as retention deletes the front of the archive.
        let store = makeStore(sources: ["alpha"])
        let older = (0..<4).map { sample("alpha", 60 + Double($0), at: at(-25 * day + Double($0))) }
        let newer = (0..<4).map { sample("alpha", 70 + Double($0), at: at(-20 * day + Double($0))) }
        store.append(contentsOf: older + newer)

        for _ in 0..<5 { store.compact(now: anchor) }

        let collapsedOlder = store.readings.filter { $0.end <= at(-24 * day) }
        let collapsedNewer = store.readings.filter { $0.end > at(-24 * day) }
        #expect(collapsedOlder.count == 1, "the first pass's own span must collapse")
        #expect(
            collapsedNewer.count == 1,
            "aged history outside the first pass's span is never compacted, so the archive keeps raw rows for almost the whole retention window"
        )
    }

    @Test("Compaction advances across sparse history and revisits a span that later becomes dense")
    func compactionAdvancesAndRewinds() {
        let store = makeStore(sources: ["alpha"])
        let sparse = sample("alpha", 61, at: at(-25 * day + 1))
        let dense = (0..<4).map {
            sample("alpha", 70 + Double($0), at: at(-20 * day + Double($0)))
        }
        store.append(contentsOf: [sparse] + dense)

        // The first three-day pass contains only the sparse cell. Advancing through that
        // no-op is what lets the second pass reach the later dense band.
        store.compact(now: anchor)
        store.compact(now: anchor)
        #expect(store.readings.filter { $0.end > at(-24 * day) }.count == 1)

        // New history behind the cursor makes the old sparse cell dense. Ingestion must
        // rewind the cursor so the next pass does not leave those raw rows there forever.
        let late = sample("alpha", 63, at: at(-25 * day + 10))
        #expect(store.append(late))
        store.compact(now: anchor)
        #expect(store.readings.filter { $0.end <= at(-24 * day) }.count == 1)
        expectSelfConsistent(store, after: "rewinding compaction for late historical data")
    }

    @Test("Late raw rows cannot bias a window that has already been compacted")
    func compactedWindowRejectsLateRows() throws {
        let store = makeStore(sources: ["alpha"])
        store.append(contentsOf: denseWindow("alpha", values: [60, 62, 100], age: 20 * day))
        store.compact(now: anchor)
        let established = try #require(store.readings.first)
        #expect(established.value == 62)

        let late = sample("alpha", 200, at: established.start.addingTimeInterval(20))
        #expect(!store.append(late))
        #expect(store.upsert(contentsOf: [late]).isEmpty)
        store.compact(now: anchor)

        #expect(store.readings == [established])
        expectSelfConsistent(store, after: "a late row offered to an already compacted window")
    }
}

// MARK: - Load state and the persistence guard

@Suite("Health store persistence guard")
@MainActor
struct HealthStoreLoadStateTests {

    @Test("A store with persistence off is loaded from birth and prunes and compacts normally")
    func persistenceOffIsTriviallyLoaded() {
        let store = makeStore()
        #expect(store.loadState == .loaded)

        store.append(contentsOf: (0..<3).map { sample("alpha", 60 + Double($0), at: at(-20 * day + Double($0))) })
        store.compact(now: anchor)
        #expect(store.readings.count == 1)

        store.retention = day
        store.prune(now: anchor)
        #expect(store.readings.isEmpty)
    }

    @Test("A nonpersistent store cannot report a durable save")
    func nonpersistentSaveDoesNotAdvanceDurableWork() async {
        let store = makeStore()

        #expect(!(await store.saveNow()))
    }

    @Test("Nothing is compacted before the archive has been read")
    func compactionWaitsForAConclusiveLoad() {
        // Compacting a store that does not yet hold the archive's contents would rewrite
        // ids for windows whose other rows are still on disk.
        let unloaded = HealthStore(persistenceEnabled: true)
        #expect(unloaded.loadState == .notLoaded)
        let batch = (0..<3).map { sample("alpha", 60 + Double($0), at: at(-20 * day + Double($0))) }
        unloaded.append(contentsOf: batch)

        unloaded.compact(now: anchor)

        #expect(unloaded.readings == batch)
        #expect(unloaded.loadState == .notLoaded)
    }

    @Test("Saving is refused until a load has completed")
    func saveIsRefusedBeforeLoad() async {
        // `saveNow` prunes and compacts before writing, so if it had proceeded it would
        // have emptied this store: every reading here is far older than the 30-day
        // retention horizon measured from the present moment. That it did not is the
        // observable proof the guard held — and the reason a locked-device launch can no
        // longer replace the user's archive with an empty one.
        let store = HealthStore(persistenceEnabled: true)
        let batch = (0..<3).map { sample("alpha", 60 + Double($0), at: at(Double($0))) }
        store.append(contentsOf: batch)
        #expect(store.loadState == .notLoaded)

        await store.saveNow()

        #expect(store.readings == batch)
        #expect(store.loadState == .notLoaded)
    }
}
