@preconcurrency import HealthKit
import Foundation
import Observation
import OSLog

/// Reads Apple Health, which is the only supported route to Apple Watch data.
///
/// There is no Bluetooth path to an Apple Watch: it is not a peripheral a third-party app
/// can connect to, and its sensor data is only exposed through HealthKit. That also means
/// anything else writing to Health \u{2014} the Oura app, a Whoop, a blood-pressure cuff \u{2014}
/// shows up here as its own source, which HeartSync keeps separate rather than merging.
@MainActor
@Observable
final class HealthKitManager {

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "HealthKit")

    enum Availability: Equatable {
        case unavailable
        case notDetermined
        case authorized
        case denied

        /// Apple Health connection status.
        ///
        /// `.authorized` deliberately says only that the sheet was completed: HealthKit
        /// never reports which read permissions were actually granted, and the wording
        /// must not be translated into a claim that every metric is readable.
        var title: String {
            switch self {
            case .unavailable:
                String(localized: "healthKit.availability.unavailable", defaultValue: "Health data is not available on this device", comment: "Apple Health status: HealthKit is unsupported on this hardware")
            case .notDetermined:
                String(localized: "healthKit.availability.notDetermined", defaultValue: "Not connected", comment: "Apple Health status: the user has not been asked for access yet")
            case .authorized:
                String(localized: "healthKit.availability.authorized", defaultValue: "Connected", comment: "Apple Health status: the authorization sheet was completed. This does not promise that any specific read permission was granted, so avoid wording that implies full access.")
            case .denied:
                String(localized: "healthKit.availability.denied", defaultValue: "Permission denied", comment: "Apple Health status: the user declined access")
            }
        }
    }

    private(set) var availability: Availability = .notDetermined
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    private let healthStore = HKHealthStore()
    private var activeQueries: [HKQuery] = []
    private weak var store: HealthStore?
    private var onReadings: (@MainActor ([Reading]) -> Void)?
    private var onDeletedSampleIDs: (@MainActor ([UUID]) -> Void)?

    /// This app's own bundle identifier, exposed so `convert` can recognise \u{2014} and reject
    /// \u{2014} samples HeartSync itself wrote, and so a unit test can reason about that rule
    /// without a device.
    ///
    /// `nonisolated` because `convert` runs on HealthKit's queue. The fallback string is
    /// only reachable in a context with no main bundle identifier at all; it matches the
    /// shipping bundle ID so the filter still behaves correctly there.
    nonisolated static let appBundleIdentifier: String =
        Bundle.main.bundleIdentifier ?? "com.heartsync.HeartSyncChecker"

    /// Persisted source id older builds assigned to HeartSync's own mirrored samples.
    /// Startup removes this source and all of its readings so the conversion/query fix also
    /// repairs archives already polluted before that fix shipped.
    nonisolated static let appSourceID = "hk.\(appBundleIdentifier)"

    /// Removes the phantom source older mirroring builds may already have archived.
    @MainActor
    @discardableResult
    static func removePersistedSelfSource(from store: HealthStore) -> Bool {
        store.remove(sourceID: appSourceID)
    }

    /// The metrics HeartSync reads, paired with their HealthKit identifiers and units.
    ///
    /// SpO\u{2082} is the one to watch: HealthKit stores it as a fraction (0.97), while every
    /// device UI and the Bluetooth pulse-oximeter spec use whole percent (97). It is
    /// converted here so the comparison engine is never handed two different scales for
    /// the same metric \u{2014} which would otherwise show up as an enormous fake discrepancy.
    struct TypeMapping: Sendable {
        var kind: MetricKind
        var identifier: HKQuantityTypeIdentifier
        var unit: HKUnit
        /// Multiplier applied after reading in `unit`.
        var scale: Double = 1

        var quantityType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: identifier) }
    }

    /// Sendable value form of the HealthKit fields conversion depends on.
    ///
    /// `HKSource` and `HKSourceRevision` cannot be constructed in a unit test and must not
    /// cross HealthKit's callback queue. Reducing a quantity sample to this descriptor gives
    /// the manager one pure, executable seam for self-source rejection, scaling, identity,
    /// and source metadata.
    struct SampleDescriptor: Sendable {
        var id: UUID
        var sourceBundleIdentifier: String
        var sourceName: String
        var deviceModel: String?
        var rawValue: Double
        var start: Date
        var end: Date
    }

    static let mappings: [TypeMapping] = [
        .init(kind: .heartRate, identifier: .heartRate,
              unit: HKUnit.count().unitDivided(by: .minute())),
        .init(kind: .restingHeartRate, identifier: .restingHeartRate,
              unit: HKUnit.count().unitDivided(by: .minute())),
        .init(kind: .hrvSDNN, identifier: .heartRateVariabilitySDNN,
              unit: HKUnit.secondUnit(with: .milli)),
        .init(kind: .spo2, identifier: .oxygenSaturation,
              unit: .percent(), scale: 100),
        .init(kind: .respiratoryRate, identifier: .respiratoryRate,
              unit: HKUnit.count().unitDivided(by: .minute())),
        .init(kind: .vo2Max, identifier: .vo2Max,
              unit: HKUnit(from: "ml/kg*min")),
        .init(kind: .bodyTemperature, identifier: .bodyTemperature,
              unit: .degreeCelsius()),
        .init(kind: .bloodPressureSystolic, identifier: .bloodPressureSystolic,
              unit: .millimeterOfMercury()),
        .init(kind: .bloodPressureDiastolic, identifier: .bloodPressureDiastolic,
              unit: .millimeterOfMercury()),
    ]

    /// Types HeartSync can write back, when the user turns on mirroring. Deliberately a
    /// short list: only metrics measured directly by a Bluetooth sensor, never anything
    /// this app estimated.
    static var shareTypes: Set<HKSampleType> {
        Set([
            HKQuantityTypeIdentifier.heartRate,
            .oxygenSaturation,
            .heartRateVariabilitySDNN,
            .bodyTemperature,
        ].compactMap { HKQuantityType.quantityType(forIdentifier: $0) })
    }

    static var readTypes: Set<HKObjectType> {
        var types = Set(mappings.compactMap { $0.quantityType as HKObjectType? })
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(dob) }
        if let sex = HKObjectType.characteristicType(forIdentifier: .biologicalSex) { types.insert(sex) }
        return types
    }

    /// Wires the manager to the store and to the two ingestion seams.
    ///
    /// `onDeletedSampleIDs` receives the ids of samples the user deleted in Health. Because
    /// HealthKit readings are stored under `id: sample.uuid`, and `HKDeletedObject.uuid` is
    /// that same value, the ids can be handed to the store's removal API unchanged.
    func configure(
        store: HealthStore,
        onReadings: @escaping @MainActor ([Reading]) -> Void,
        onDeletedSampleIDs: @escaping @MainActor ([UUID]) -> Void
    ) {
        self.store = store
        self.onReadings = onReadings
        self.onDeletedSampleIDs = onDeletedSampleIDs
        guard HKHealthStore.isHealthDataAvailable() else {
            availability = .unavailable
            return
        }
    }

    // MARK: - Authorization

    func requestAuthorization(allowWriting: Bool) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            availability = .unavailable
            return
        }
        do {
            try await healthStore.requestAuthorization(
                toShare: allowWriting ? Self.shareTypes : [],
                read: Self.readTypes
            )
            // HealthKit deliberately never reveals read permission, to avoid leaking the
            // absence of data. So "authorized" here means the sheet completed; whether any
            // data actually arrives is only knowable by querying.
            availability = .authorized
            lastError = nil
            persistAuthorizationCompleted()
            await startObserving()
            await syncAll()
        } catch {
            availability = .denied
            lastError = error.localizedDescription
            logger.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads age and biological sex, which the VO\u{2082} max estimator needs, so the user does
    /// not have to type what Health already knows.
    func readCharacteristics() -> (birthDate: Date?, sex: UserProfile.BiologicalSex?) {
        var birthDate: Date?
        var sex: UserProfile.BiologicalSex?
        if let components = try? healthStore.dateOfBirthComponents() {
            birthDate = Calendar.current.date(from: components)
        }
        if let hkSex = try? healthStore.biologicalSex().biologicalSex {
            switch hkSex {
            case .female: sex = .female
            case .male:   sex = .male
            default:      sex = .unspecified
            }
        }
        return (birthDate, sex)
    }

    // MARK: - Sync

    /// Pulls everything since the stored anchor for each type, then leaves a long-running
    /// anchored query in place so later samples arrive automatically.
    func syncAll() async {
        guard availability == .authorized else { return }
        isSyncing = true
        defer { isSyncing = false }

        for mapping in Self.mappings {
            await sync(mapping)
        }
        lastSyncedAt = .now
    }

    private func sync(_ mapping: TypeMapping) async {
        guard let type = mapping.quantityType else { return }
        let anchor = loadAnchor(for: mapping.identifier)

        let result: (readings: [Reading], sources: [DataSource], deletedIDs: [UUID], anchor: HKQueryAnchor?)
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: Self.recentPredicate(),
                    anchor: anchor,
                    limit: HKObjectQueryNoLimit
                ) { _, samples, deleted, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Convert inside the handler: neither HKSample nor HKDeletedObject is
                    // Sendable, but the Readings, DataSources and UUIDs they produce are,
                    // so only value types cross back to the main actor.
                    let converted = Self.convert(samples ?? [], mapping: mapping)
                    let deletedIDs = Self.deletedReadingIDs(deleted ?? [])
                    continuation.resume(
                        returning: (converted.readings, converted.sources, deletedIDs, newAnchor)
                    )
                }
                healthStore.execute(query)
            }
        } catch {
            // An "authorization not determined" error for one type is normal when the user
            // granted only some permissions; it should not abort the whole sync.
            logger.debug("Sync for \(mapping.identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        for source in result.sources { store?.upsert(source) }
        if !result.readings.isEmpty { onReadings?(result.readings) }
        // Deletions are applied after insertions so that a sample added and then removed
        // between two anchors cannot survive by being re-inserted after its own removal.
        if !result.deletedIDs.isEmpty { onDeletedSampleIDs?(result.deletedIDs) }
        if let newAnchor = result.anchor { save(anchor: newAnchor, for: mapping.identifier) }
    }

    /// Installs anchored queries with update handlers so new Health samples stream in
    /// without the user pulling to refresh.
    private func startObserving() async {
        guard availability == .authorized else { return }
        stopObserving()

        for mapping in Self.mappings {
            guard let type = mapping.quantityType else { continue }
            let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
                [weak self] _, samples, deleted, newAnchor, error in
                guard error == nil else { return }
                // Both framework arrays are turned into Sendable value types here, on
                // HealthKit's own queue, so no non-Sendable object escapes into the Task.
                let converted = Self.convert(samples ?? [], mapping: mapping)
                let deletedIDs = Self.deletedReadingIDs(deleted ?? [])
                // A callback carrying only HeartSync's own mirrored samples converts to
                // nothing, so this also stops the write-back loop waking the main actor.
                guard !converted.readings.isEmpty || !converted.sources.isEmpty || !deletedIDs.isEmpty
                else { return }
                let identifier = mapping.identifier
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for source in converted.sources { self.store?.upsert(source) }
                    if !converted.readings.isEmpty { self.onReadings?(converted.readings) }
                    // Deletions after insertions, for the same reason as in `sync`.
                    if !deletedIDs.isEmpty { self.onDeletedSampleIDs?(deletedIDs) }
                    if let newAnchor { self.save(anchor: newAnchor, for: identifier) }
                    self.lastSyncedAt = .now
                }
            }

            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: Self.recentPredicate(),
                anchor: loadAnchor(for: mapping.identifier),
                limit: HKObjectQueryNoLimit,
                resultsHandler: handler
            )
            query.updateHandler = handler
            healthStore.execute(query)
            activeQueries.append(query)

            // Ask iOS to wake the app when new samples land, so an Apple Watch reading
            // taken hours ago is present the next time the user opens the app.
            do {
                try await healthStore.enableBackgroundDelivery(for: type, frequency: .hourly)
            } catch {
                logger.debug("Background delivery unavailable for \(mapping.identifier.rawValue, privacy: .public)")
            }
        }
    }

    func stopObserving() {
        for query in activeQueries { healthStore.stop(query) }
        activeQueries.removeAll()
    }

    /// HealthKit holds years of history. Pulling all of it on first launch would be slow
    /// and pointless \u{2014} the app compares devices over recent windows.
    ///
    /// The 30-day window is compounded with an exclusion of HeartSync's own samples, so
    /// mirrored write-backs are never even returned to us. `convert` rejects them a second
    /// time; see its comment for why both halves are wanted.
    private static func recentPredicate(days: Int = 30) -> NSPredicate {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let recent = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let notOurOwn = NSCompoundPredicate(
            notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()])
        )
        return NSCompoundPredicate(andPredicateWithSubpredicates: [recent, notOurOwn])
    }

    // MARK: - Conversion

    /// Turns HealthKit samples into HeartSync readings, one source per writing device.
    ///
    /// `nonisolated` and `static` so it can run on HealthKit's own queue without hopping.
    ///
    /// Samples written by HeartSync itself are dropped. This is not defensive tidiness; it
    /// closes a feedback loop that produces the most misleading output this app is capable
    /// of. When `mirrorBluetoothToHealthKit` is on, `AppModel.ingest` writes measured
    /// Bluetooth readings into Health. HealthKit hands an app back its own samples, so
    /// those values return through the anchored queries and \u{2014} because the source ID is
    /// derived from whichever app wrote the sample \u{2014} land under
    /// `hk.<this app's bundle id>`. The result is a phantom "HeartSync" device in the
    /// device list holding a byte-for-byte copy of the chest strap's stream, which
    /// `ComparisonEngine` then pairs against the strap and reports as perfect agreement
    /// over thousands of windows. Every mirrored reading is also stored twice.
    ///
    /// The filter lives here as well as in `recentPredicate` on purpose. The predicate
    /// stops the samples arriving; this guard additionally means a store already polluted
    /// by an earlier build stops growing, and it keeps the rule in a `nonisolated static`
    /// pure function that can be unit-tested without a device.
    nonisolated static func convert(
        _ samples: [HKSample],
        mapping: TypeMapping
    ) -> (readings: [Reading], sources: [DataSource]) {
        let descriptors = samples.compactMap { sample -> SampleDescriptor? in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            let hkSource = sample.sourceRevision.source
            return SampleDescriptor(
                id: sample.uuid,
                sourceBundleIdentifier: hkSource.bundleIdentifier,
                sourceName: hkSource.name,
                deviceModel: sample.device?.model ?? sample.device?.name,
                rawValue: quantitySample.quantity.doubleValue(for: mapping.unit),
                start: sample.startDate,
                end: sample.endDate
            )
        }
        return convert(descriptors: descriptors, mapping: mapping)
    }

    /// Pure conversion core used by both HealthKit callbacks and unit tests.
    nonisolated static func convert(
        descriptors: [SampleDescriptor],
        mapping: TypeMapping
    ) -> (readings: [Reading], sources: [DataSource]) {
        var readings: [Reading] = []
        var sources: [String: DataSource] = [:]

        for sample in descriptors {
            guard sample.sourceBundleIdentifier != appBundleIdentifier else { continue }
            // Preserve the shipped identity formula: one HeartSync source per HealthKit
            // writing source bundle. Device model is metadata only; adding it to this id
            // would split existing archived sources without a migration.
            let sourceID = "hk.\(sample.sourceBundleIdentifier)"

            if sources[sourceID] == nil {
                sources[sourceID] = DataSource(
                    id: sourceID,
                    displayName: sample.sourceName,
                    transport: .healthKit,
                    model: sample.deviceModel,
                    lastSeenAt: sample.end,
                    observedMetrics: [mapping.kind]
                )
            }

            let value = sample.rawValue * mapping.scale

            readings.append(Reading(
                // The HealthKit sample UUID makes this idempotent: re-running a query
                // after an anchor reset re-delivers the same samples, and they collapse
                // onto the same reading instead of duplicating.
                id: sample.id,
                sourceID: sourceID,
                kind: mapping.kind,
                value: value,
                start: sample.start,
                end: sample.end,
                provenance: .measured
            ))
        }

        return (readings, Array(sources.values))
    }

    /// Turns HealthKit's deletion objects into reading ids the store can remove.
    ///
    /// The mapping is the identity: `convert` stores HealthKit readings under
    /// `id: sample.uuid`, and `HKDeletedObject.uuid` carries that same sample UUID, so no
    /// lookup or translation is needed. Ids that were never stored \u{2014} deletions of samples
    /// from a type HeartSync does not read, or of its own mirrored write-backs \u{2014} simply do
    /// not match anything and are a no-op on the store side; `HKDeletedObject` does not
    /// expose a source, so they cannot be filtered here.
    ///
    /// `nonisolated` and `static` for the same reason as `convert`: `HKDeletedObject` is
    /// not `Sendable`, so it must be reduced to value types inside HealthKit's own callback
    /// before anything crosses to the main actor.
    nonisolated static func deletedReadingIDs(_ deleted: [HKDeletedObject]) -> [UUID] {
        deleted.map(\.uuid)
    }

    // MARK: - Writing back

    /// Mirrors a Bluetooth-measured reading into Health.
    ///
    /// Only measured values are eligible; estimates never enter the user's health record.
    func write(_ reading: Reading) async {
        guard reading.provenance == .measured else { return }
        guard let mapping = Self.mappings.first(where: { $0.kind == reading.kind }),
              let type = mapping.quantityType,
              Self.shareTypes.contains(type)
        else { return }

        let value = reading.value / mapping.scale
        let quantity = HKQuantity(unit: mapping.unit, doubleValue: value)
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: reading.start,
            end: reading.end,
            metadata: [HKMetadataKeyWasUserEntered: false]
        )
        do {
            try await healthStore.save(sample)
        } catch {
            logger.debug("Write-back failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Anchors

    private func anchorKey(_ identifier: HKQuantityTypeIdentifier) -> String {
        "hk.anchor.\(identifier.rawValue)"
    }

    private func loadAnchor(for identifier: HKQuantityTypeIdentifier) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorKey(identifier)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func save(anchor: HKQueryAnchor, for identifier: HKQuantityTypeIdentifier) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: anchor, requiringSecureCoding: true
        ) else { return }
        UserDefaults.standard.set(data, forKey: anchorKey(identifier))
    }

    /// Clears anchors so the next sync re-reads the full retention window. Safe because
    /// readings de-duplicate on the HealthKit sample UUID.
    func resetAnchors() {
        for mapping in Self.mappings {
            UserDefaults.standard.removeObject(forKey: anchorKey(mapping.identifier))
        }
    }
}
