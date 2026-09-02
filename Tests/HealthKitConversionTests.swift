import Foundation
import HealthKit
import Testing
@testable import HeartSyncChecker

/// Covers the pure, `nonisolated static` surface of `HealthKitManager`: the type mapping
/// table, self-source rejection, scale conversion, source identity, and archive cleanup.
/// Framework `HKSource` objects cannot be constructed in a unit test, so production reduces
/// them to `SampleDescriptor` values and this suite executes the same conversion core.
@Suite("HealthKit self-source filter")
@MainActor
struct HealthKitSelfSourceTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func descriptor(
        sourceBundleIdentifier: String,
        rawValue: Double = 72
    ) -> HealthKitManager.SampleDescriptor {
        HealthKitManager.SampleDescriptor(
            id: UUID(),
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceName: "Test Source",
            deviceModel: "Test Device",
            rawValue: rawValue,
            start: epoch,
            end: epoch.addingTimeInterval(5)
        )
    }

    /// The closest available guard on finding 1.1.
    ///
    /// The defence has two halves that must name the same app: `recentPredicate` excludes
    /// `HKSource.default()` so our own samples are never returned, and `convert` drops any
    /// sample whose bundle identifier equals `appBundleIdentifier`. If those two ever name
    /// different apps — a hard-coded literal drifting from the real bundle id, a `.debug`
    /// suffix on the product bundle id, a fallback taken because there is no main bundle —
    /// the second half stops matching anything and the phantom source is back.
    @Test("The self-sample filter names the same app HealthKit will attribute our writes to")
    func selfFilterMatchesHealthKitsOwnNotionOfThisApp() throws {
        let mainBundleIdentifier = try #require(Bundle.main.bundleIdentifier)
        #expect(HealthKitManager.appBundleIdentifier == mainBundleIdentifier)
        // HKSource.default() is the source HealthKit files this process's own saves under,
        // and it is exactly what recentPredicate excludes.
        #expect(HealthKitManager.appBundleIdentifier == HKSource.default().bundleIdentifier)
    }

    /// `convert` builds HealthKit source ids as `"hk.\(bundleIdentifier)"`, so the shipping
    /// bundle identifier is part of the persisted identity of every Apple Health device in
    /// the archive. Changing `PRODUCT_BUNDLE_IDENTIFIER` re-namespaces nothing on its own —
    /// other apps keep their own ids — but it does change which samples the self-filter
    /// recognises, and the fallback literal in `appBundleIdentifier` would then be wrong.
    @Test("The bundle identifier the source-id formula is built on is pinned")
    func bundleIdentifierIsPinned() {
        #expect(HealthKitManager.appBundleIdentifier == "com.heartsync.HeartSyncChecker")
        #expect(HealthKitManager.appSourceID == "hk.com.heartsync.HeartSyncChecker")
    }

    @Test("HeartSync's own mirrored samples produce neither readings nor a source")
    func ownSamplesAreDroppedByThePureConversionCore() throws {
        let mapping = try #require(HealthKitManager.mappings.first { $0.kind == .heartRate })
        let converted = HealthKitManager.convert(
            descriptors: [descriptor(sourceBundleIdentifier: HealthKitManager.appBundleIdentifier)],
            mapping: mapping
        )

        #expect(converted.readings.isEmpty)
        #expect(converted.sources.isEmpty)
    }

    @Test("A foreign HealthKit sample keeps its identity, metadata, and normalized scale")
    func foreignSampleConvertsCompletely() throws {
        let mapping = try #require(HealthKitManager.mappings.first { $0.kind == .spo2 })
        let sample = descriptor(sourceBundleIdentifier: "com.example.watch", rawValue: 0.97)
        let converted = HealthKitManager.convert(descriptors: [sample], mapping: mapping)
        let reading = try #require(converted.readings.first)
        let source = try #require(converted.sources.first)

        #expect(reading.id == sample.id)
        #expect(reading.sourceID == "hk.com.example.watch")
        #expect(reading.value == 97)
        #expect(reading.start == sample.start)
        #expect(reading.end == sample.end)
        #expect(reading.provenance == .measured)
        #expect(source.id == reading.sourceID)
        #expect(source.displayName == sample.sourceName)
        #expect(source.model == sample.deviceModel)
        #expect(source.observedMetrics == [.spo2])
    }

    @Test("Startup cleanup removes an already archived phantom source and all its readings")
    func archivedSelfSourceIsRemoved() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(
            id: HealthKitManager.appSourceID,
            displayName: "HeartSync",
            transport: .healthKit
        ))
        store.append(Reading(
            sourceID: HealthKitManager.appSourceID,
            kind: .heartRate,
            value: 72,
            start: epoch
        ))

        #expect(HealthKitManager.removePersistedSelfSource(from: store))
        #expect(store.source(id: HealthKitManager.appSourceID) == nil)
        #expect(store.readings.isEmpty)
        #expect(!HealthKitManager.removePersistedSelfSource(from: store))
    }

    /// Not a formality: the cast is what stops `convert` from ever reaching
    /// `quantity.doubleValue(for:)` on something that has no quantity. A category sample is
    /// rejected before its source is even inspected.
    @Test("Only quantity samples can become readings")
    func nonQuantitySamplesProduceNothing() throws {
        let mapping = try #require(HealthKitManager.mappings.first { $0.kind == .heartRate })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sleepType = try #require(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        let categorySample = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: start,
            end: start.addingTimeInterval(3600)
        )

        let empty = HealthKitManager.convert([], mapping: mapping)
        #expect(empty.readings.isEmpty)
        #expect(empty.sources.isEmpty)

        let converted = HealthKitManager.convert([categorySample], mapping: mapping)
        #expect(converted.readings.isEmpty)
        // A source must never be invented for a sample that produced no reading.
        #expect(converted.sources.isEmpty)
    }
}

@Suite("HealthKit type mappings")
@MainActor
struct HealthKitTypeMappingTests {

    @Test("HealthKit synchronization uses finite drains and a valid long-running observer")
    func queryWorkIsBounded() throws {
        #expect(HealthKitManager.queryBatchLimit > 0)
        #expect(HealthKitManager.maximumObjectsPerSync >= HealthKitManager.queryBatchLimit)
        #expect(HealthKitManager.observerQueryLimit == HKObjectQueryNoLimit)
        #expect(HealthKitManager.observerBufferLimit == 1)
        #expect(HealthKitManager.nextQueryLimit(afterProcessed: 0) == HealthKitManager.queryBatchLimit)
        #expect(HealthKitManager.nextQueryLimit(afterProcessed: HealthKitManager.maximumObjectsPerSync) == nil)
        #expect(HealthKitManager.shouldContinuePaging(
            objectCount: HealthKitManager.queryBatchLimit,
            limit: HealthKitManager.queryBatchLimit
        ))
        #expect(!HealthKitManager.shouldContinuePaging(objectCount: 0, limit: HealthKitManager.queryBatchLimit))

        let type = try #require(HKQuantityType.quantityType(forIdentifier: .heartRate))
        let handler: @Sendable (
            HKAnchoredObjectQuery,
            [HKSample]?,
            [HKDeletedObject]?,
            HKQueryAnchor?,
            Error?
        ) -> Void = { _, _, _, _, _ in }
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: nil,
            anchor: nil,
            limit: HealthKitManager.observerQueryLimit,
            resultsHandler: handler
        )

        // A finite limit makes this setter raise NSInvalidArgumentException and abort the host.
        query.updateHandler = handler
        #expect(query.updateHandler != nil)
    }

    /// A probe expressed in a unit chosen independently of the mapping, so the assertion is
    /// about physical meaning rather than about repeating the mapping's own literal.
    private struct UnitProbe {
        var unit: HKUnit
        var value: Double
        /// What that quantity must read as through the mapping's unit, before `scale`.
        var expected: Double
    }

    private var probes: [MetricKind: UnitProbe] {
        [
            .heartRate: .init(unit: HKUnit(from: "count/min"), value: 72, expected: 72),
            .restingHeartRate: .init(unit: HKUnit(from: "count/min"), value: 55, expected: 55),
            // Half a tenth of a second is 50 ms: the mapping must be in milliseconds, the
            // unit every HRV number in this app and in MetricKind.unit is quoted in.
            .hrvSDNN: .init(unit: .second(), value: 0.05, expected: 50),
            // HealthKit stores saturation as a fraction; the whole-percent conversion is
            // asserted separately, in spo2FractionBecomesWholePercent.
            .spo2: .init(unit: .percent(), value: 0.97, expected: 0.97),
            .respiratoryRate: .init(unit: HKUnit(from: "count/min"), value: 14, expected: 14),
            .vo2Max: .init(unit: HKUnit(from: "ml/kg*min"), value: 42, expected: 42),
            // 98.6 F is 37 C. Celsius is what MetricKind formats and what the Bluetooth
            // thermometer parser normalises to; a Fahrenheit mapping here would put two
            // scales of the same metric side by side in one comparison.
            .bodyTemperature: .init(unit: .degreeFahrenheit(), value: 98.6, expected: 37),
            .bloodPressureSystolic: .init(unit: .millimeterOfMercury(), value: 120, expected: 120),
            .bloodPressureDiastolic: .init(unit: .millimeterOfMercury(), value: 80, expected: 80),
        ]
    }

    @Test("Every mapping resolves to a real HealthKit type carrying the right identifier")
    func mappingsResolveToTheirIdentifiers() throws {
        for mapping in HealthKitManager.mappings {
            // A nil quantityType is silent: sync() returns early and that metric simply
            // never arrives, with no error anywhere.
            let type = try #require(
                mapping.quantityType,
                "No HealthKit quantity type for \(mapping.kind.rawValue)"
            )
            #expect(type.identifier == mapping.identifier.rawValue)
        }
    }

    @Test("Each metric reads in the unit the rest of the app quotes it in")
    func mappingUnitsCarryTheDocumentedMeaning() throws {
        let probes = self.probes
        #expect(Set(probes.keys) == Set(HealthKitManager.mappings.map(\.kind)))

        for mapping in HealthKitManager.mappings {
            let probe = try #require(probes[mapping.kind], "No probe for \(mapping.kind.rawValue)")
            let quantity = HKQuantity(unit: probe.unit, doubleValue: probe.value)
            // Checked rather than converted directly: an incompatible unit traps inside
            // HealthKit, which would take the whole run down instead of failing this test.
            try #require(
                quantity.is(compatibleWith: mapping.unit),
                "\(mapping.kind.rawValue) is no longer measured in a compatible unit"
            )
            #expect(abs(quantity.doubleValue(for: mapping.unit) - probe.expected) < 1e-6)
        }
    }

    /// HealthKit hands back 0.97; every device UI, the Bluetooth pulse-oximeter parser and
    /// MetricKind's 50...100 plausible range speak whole percent. Losing the multiplier does
    /// not produce a visibly wrong number — it produces a value the store silently rejects,
    /// or, worse, one that sits next to a Bluetooth 97 and reads as a 96-point discrepancy.
    @Test("A HealthKit oxygen fraction becomes whole percent")
    func spo2FractionBecomesWholePercent() throws {
        let mapping = try #require(HealthKitManager.mappings.first { $0.kind == .spo2 })
        let sampleQuantity = HKQuantity(unit: .percent(), doubleValue: 0.97)
        try #require(sampleQuantity.is(compatibleWith: mapping.unit))

        let stored = sampleQuantity.doubleValue(for: mapping.unit) * mapping.scale
        #expect(abs(stored - 97) < 1e-9)
        #expect(MetricKind.spo2.plausibleRange.contains(stored))
        // The unscaled fraction is not merely wrong, it is outside the plausible range, so
        // dropping the scale deletes Apple Health blood oxygen without any error surfacing.
        #expect(!MetricKind.spo2.plausibleRange.contains(0.97))

        // write(_:) divides by the same scale, so a mirrored 97 % must leave as 0.97.
        #expect(abs(97 / mapping.scale - 0.97) < 1e-9)
    }

    @Test("Blood oxygen is the only metric that is rescaled after reading")
    func onlySpo2IsRescaled() {
        #expect(HealthKitManager.mappings.filter { $0.scale != 1 }.map(\.kind) == [.spo2])
    }

    /// Oura's `average_hrv` is RMSSD and Apple's HRV is SDNN. They are different statistics
    /// of the same signal, so pairing them would manufacture a permanent "discrepancy" out
    /// of arithmetic. `OuraMappingTests` guards the other end of this rule.
    @Test("HealthKit SDNN is never presented as RMSSD, and there is no RMSSD mapping")
    func noRMSSDMapping() {
        #expect(!HealthKitManager.mappings.contains { $0.kind == .hrvRMSSD })
        #expect(
            HealthKitManager.mappings
                .filter { $0.identifier == .heartRateVariabilitySDNN }
                .map(\.kind) == [.hrvSDNN]
        )
    }

    /// `write(_:)` picks its mapping with `first(where: { $0.kind == reading.kind })`, and
    /// `sync` runs one anchored query per mapping. A duplicate kind would make write-back
    /// pick an arbitrary unit; a duplicate identifier would query the same type twice and
    /// ingest every sample under two metrics.
    @Test("Each metric and each HealthKit identifier appears exactly once")
    func mappingsAreUnique() {
        let kinds = HealthKitManager.mappings.map(\.kind)
        let identifiers = HealthKitManager.mappings.map(\.identifier)
        #expect(Set(kinds).count == kinds.count)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("Read access is asked for every mapped metric plus the two profile characteristics")
    func readTypesCoverEveryMapping() {
        let readIdentifiers = Set(HealthKitManager.readTypes.map(\.identifier))
        for mapping in HealthKitManager.mappings {
            #expect(readIdentifiers.contains(mapping.identifier.rawValue))
        }
        // Age and biological sex feed the VO2 max estimator; nothing else is requested.
        #expect(readIdentifiers.contains(HKCharacteristicTypeIdentifier.dateOfBirth.rawValue))
        #expect(readIdentifiers.contains(HKCharacteristicTypeIdentifier.biologicalSex.rawValue))
        #expect(readIdentifiers.count == HealthKitManager.mappings.count + 2)
    }
}

@Suite("HealthKit write-back scope")
@MainActor
struct HealthKitShareTypeTests {

    private var shareIdentifiers: Set<String> {
        Set(HealthKitManager.shareTypes.map(\.identifier))
    }

    @Test("Mirroring is limited to the four directly measured metrics")
    func shareTypesAreTheFourMeasuredMetrics() {
        #expect(shareIdentifiers == Set([
            HKQuantityTypeIdentifier.heartRate,
            .oxygenSaturation,
            .heartRateVariabilitySDNN,
            .bodyTemperature,
        ].map(\.rawValue)))
    }

    /// The user's health record must never receive a number this app invented. `vo2Max` and
    /// both halves of blood pressure are produced by `Estimators` with
    /// `provenance == .estimated`; resting heart rate and respiratory rate only ever arrive
    /// from another vendor (Oura, or Health itself), so mirroring them would re-file someone
    /// else's data as ours.
    @Test("Nothing this app estimates, and nothing it merely relays, can be written back")
    func estimatedAndRelayedMetricsAreNeverShareable() {
        let forbidden: [HKQuantityTypeIdentifier] = [
            .vo2Max,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
            .restingHeartRate,
            .respiratoryRate,
        ]
        for identifier in forbidden {
            #expect(!shareIdentifiers.contains(identifier.rawValue))
        }
    }

    /// `write(_:)` requires a mapping *and* membership of `shareTypes`, so a share type with
    /// no mapping is permission the app asks for and can never use.
    @Test("Every writable type is also a type the app reads and maps")
    func shareTypesAreMappedAndRead() {
        let mappedIdentifiers = Set(HealthKitManager.mappings.map(\.identifier.rawValue))
        let readIdentifiers = Set(HealthKitManager.readTypes.map(\.identifier))
        for identifier in shareIdentifiers {
            #expect(mappedIdentifiers.contains(identifier))
            #expect(readIdentifiers.contains(identifier))
        }
    }
}

/// The store-side half of the HealthKit identity contract.
///
/// `convert` stores readings under `id: sample.uuid`, which is the single fact that makes
/// re-delivery after an anchor reset harmless and makes deletion mapping (finding 4.4)
/// possible at all — `HKDeletedObject.uuid` is that same value, which is why
/// `deletedReadingIDs` is the identity function. `convert` itself is not reachable from a
/// test (see the note at the top of this file), so what is pinned here is the behaviour that
/// depends on its choice of id.
@Suite("HealthKit sample identity in the store")
@MainActor
struct HealthKitSampleIdentityTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let watchSourceID = "hk.com.apple.health.watch"

    /// `sync` upserts the source before handing the readings over, and `readings(kind:)`
    /// serves enabled sources only, so a store without the source would report nothing
    /// whatever the ids were.
    private func makeStore() -> HealthStore {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(
            id: watchSourceID,
            displayName: "Apple Watch",
            transport: .healthKit
        ))
        return store
    }

    private func healthKitReading(sampleUUID: UUID, value: Double, offset: TimeInterval) -> Reading {
        Reading(
            id: sampleUUID,
            sourceID: watchSourceID,
            kind: .heartRate,
            value: value,
            start: epoch.addingTimeInterval(offset),
            end: epoch.addingTimeInterval(offset),
            provenance: .measured
        )
    }

    @Test("Re-delivering the same HealthKit samples cannot duplicate a reading")
    func redeliveryIsIdempotent() {
        let store = makeStore()
        let uuids = [UUID(), UUID(), UUID()]
        let batch = uuids.enumerated().map {
            healthKitReading(sampleUUID: $0.element, value: 70 + Double($0.offset), offset: Double($0.offset) * 60)
        }

        #expect(store.append(contentsOf: batch).count == 3)
        // An anchor reset re-runs the query and hands back the same samples.
        #expect(store.append(contentsOf: batch).isEmpty)
        #expect(store.readings(kind: .heartRate).count == 3)
    }

    @Test("A sample deleted in Health removes exactly the reading it created")
    func deletionMapsThroughTheSampleUUID() {
        let store = makeStore()
        let deletedUUID = UUID()
        let survivingUUID = UUID()
        store.append(contentsOf: [
            healthKitReading(sampleUUID: deletedUUID, value: 70, offset: 0),
            healthKitReading(sampleUUID: survivingUUID, value: 71, offset: 60),
        ])

        #expect(store.remove(readingIDs: [deletedUUID]) == 1)
        #expect(store.readings(kind: .heartRate).map(\.id) == [survivingUUID])
        // HealthKit also reports deletions of samples this app never stored — other types,
        // or its own mirrored write-backs. Those must be a no-op, not an error.
        #expect(store.remove(readingIDs: [UUID()]) == 0)
        #expect(store.readings(kind: .heartRate).count == 1)
    }
}
