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

        var title: String {
            switch self {
            case .unavailable:   "Health data is not available on this device"
            case .notDetermined: "Not connected"
            case .authorized:    "Connected"
            case .denied:        "Permission denied"
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

    func configure(store: HealthStore, onReadings: @escaping @MainActor ([Reading]) -> Void) {
        self.store = store
        self.onReadings = onReadings
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

        let result: (readings: [Reading], sources: [DataSource], anchor: HKQueryAnchor?)
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: Self.recentPredicate(),
                    anchor: anchor,
                    limit: HKObjectQueryNoLimit
                ) { _, samples, _, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Convert inside the handler: HKSample is not Sendable, but the
                    // Readings and DataSources it produces are, so only value types
                    // cross back to the main actor.
                    let converted = Self.convert(samples ?? [], mapping: mapping)
                    continuation.resume(returning: (converted.readings, converted.sources, newAnchor))
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
                [weak self] _, samples, _, newAnchor, error in
                guard error == nil, let samples, !samples.isEmpty else { return }
                let converted = Self.convert(samples, mapping: mapping)
                let identifier = mapping.identifier
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for source in converted.sources { self.store?.upsert(source) }
                    if !converted.readings.isEmpty { self.onReadings?(converted.readings) }
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
    private static func recentPredicate(days: Int = 30) -> NSPredicate {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
    }

    // MARK: - Conversion

    /// Turns HealthKit samples into HeartSync readings, one source per writing device.
    ///
    /// `nonisolated` and `static` so it can run on HealthKit's own queue without hopping.
    nonisolated static func convert(
        _ samples: [HKSample],
        mapping: TypeMapping
    ) -> (readings: [Reading], sources: [DataSource]) {
        var readings: [Reading] = []
        var sources: [String: DataSource] = [:]

        for sample in samples {
            guard let quantitySample = sample as? HKQuantitySample else { continue }

            let hkSource = sample.sourceRevision.source
            // Data collected by an Apple Watch carries a bundle identifier unique to that
            // watch, so this yields one HeartSync source per physical device rather than
            // lumping every watch together.
            let sourceID = "hk.\(hkSource.bundleIdentifier)"
            let deviceModel = sample.device?.model ?? sample.device?.name

            if sources[sourceID] == nil {
                sources[sourceID] = DataSource(
                    id: sourceID,
                    displayName: hkSource.name,
                    transport: .healthKit,
                    model: deviceModel,
                    lastSeenAt: sample.endDate,
                    observedMetrics: [mapping.kind]
                )
            }

            let raw = quantitySample.quantity.doubleValue(for: mapping.unit)
            let value = raw * mapping.scale

            readings.append(Reading(
                // The HealthKit sample UUID makes this idempotent: re-running a query
                // after an anchor reset re-delivers the same samples, and they collapse
                // onto the same reading instead of duplicating.
                id: sample.uuid,
                sourceID: sourceID,
                kind: mapping.kind,
                value: value,
                start: sample.startDate,
                end: sample.endDate,
                provenance: .measured
            ))
        }

        return (readings, Array(sources.values))
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
