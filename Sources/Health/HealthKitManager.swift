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

    // Internal so HealthKitManager+Session (separate file) can log restore/write-auth paths.
    let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "HealthKit")

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

    // Internal setters let the session extension restore/update these across files.
    var availability: Availability = .notDetermined
    private(set) var lastAttemptAt: Date?
    private(set) var lastCompleteSyncAt: Date?
    private(set) var syncSummary: HealthKitSyncSummary?
    var lastError: String?
    private(set) var isSyncing = false

    var lastSyncedAt: Date? { lastCompleteSyncAt }

    enum TypeSyncResult: Equatable, Sendable {
        case complete(String)
        case permissionUnknown(String, String)
        case failed(String, String)
        case budgetDeferred(String)

        var isComplete: Bool {
            if case .complete = self { return true }
            return false
        }

        var canResumeObservation: Bool {
            switch self {
            case .complete, .budgetDeferred: true
            case .permissionUnknown, .failed: false
            }
        }

        var userDetail: String? {
            switch self {
            case .complete:
                nil
            case .permissionUnknown(let name, _):
                "\(name): read permission is not disclosed by Apple"
            case .failed(let name, let detail):
                "\(name): \(detail)"
            case .budgetDeferred(let name):
                "\(name): more changes remain; sync again to continue"
            }
        }
    }

    struct HealthKitSyncSummary: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case complete
            case partial
            case failed
            case permissionUnknown
            case budgetDeferred
        }

        var outcome: Outcome
        var results: [TypeSyncResult]
        var attemptedAt: Date

        static func aggregate(_ results: [TypeSyncResult], at date: Date) -> Self {
            let completed = results.count { $0.isComplete }
            let permission = results.count {
                if case .permissionUnknown = $0 { return true }
                return false
            }
            let failed = results.count {
                if case .failed = $0 { return true }
                return false
            }
            let deferred = results.count {
                if case .budgetDeferred = $0 { return true }
                return false
            }

            let outcome: Outcome
            if !results.isEmpty, completed == results.count {
                outcome = .complete
            } else if completed > 0 || [permission, failed, deferred].count(where: { $0 > 0 }) > 1 {
                outcome = .partial
            } else if deferred > 0 {
                outcome = .budgetDeferred
            } else if permission > 0 {
                outcome = .permissionUnknown
            } else {
                outcome = .failed
            }
            return Self(outcome: outcome, results: results, attemptedAt: date)
        }
    }

    // Internal so HealthKitManager+Session can query authorization status.
    let healthStore = HKHealthStore()
    private var activeQueries: [HKQuery] = []
    private weak var store: HealthStore?
    private var onReadings: (@MainActor ([Reading], [DataSource], Set<UUID>) -> Bool)?

    /// HealthKit query results are deliberately drained in finite pages. The total budget is a
    /// per-mapping guardrail: a dense type is resumed from its committed anchor on the next
    /// sync instead of materialising an arbitrarily large backlog in one call.
    nonisolated static let queryBatchLimit = 500
    nonisolated static let maximumObjectsPerSync = 10_000
    /// HealthKit raises `NSInvalidArgumentException` if an anchored query with a finite limit
    /// is given an update handler. Keep finite limits on the one-shot drains above, while the
    /// long-running query uses the framework's required no-limit mode. The one-slot stream still
    /// bounds queued callbacks, and the threshold below moves unusually large callbacks back
    /// through the finite drain path.
    nonisolated static let observerQueryLimit = HKObjectQueryNoLimit
    /// A slow main actor must not accumulate an unbounded observer-task queue. If this one-slot
    /// buffer fills, the query is stopped and the saved anchor is drained again in order.
    nonisolated static let observerBufferLimit = 1

    private struct AnchoredBatch: Sendable {
        let readings: [Reading]
        let sources: [DataSource]
        let deletedIDs: [UUID]
        /// Counts framework objects, not only converted readings: self-written samples still
        /// advance the HealthKit anchor and must count toward the work budget.
        let objectCount: Int
        let anchorData: Data?
    }

    private enum ObserverEvent: Sendable {
        case batch(AnchoredBatch, generation: Int)
        case resync
    }

    /// Thread-safe callback state. HealthKit may invoke an observer handler while the main actor
    /// is committing a previous page; once recovery is requested, callbacks stop converting data
    /// and old events are invalidated by the generation check.
    private final class ObserverState: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        private var resyncRequired = false
        private var acceptingBatches = true
        private var recoveryAttempts = 0

        enum RecoveryDecision {
            case none
            case retry(TimeInterval)
            case giveUp
        }

        func beginBatch() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard acceptingBatches, !resyncRequired else { return nil }
            return generation
        }

        func requestResync() {
            lock.lock()
            defer { lock.unlock() }
            guard !resyncRequired else { return }
            generation += 1
            resyncRequired = true
            acceptingBatches = false
        }

        func prepareRecovery() -> RecoveryDecision {
            lock.lock()
            defer { lock.unlock() }
            guard resyncRequired else { return .none }
            guard recoveryAttempts < 3 else {
                // Leave the query stopped after repeated durable-commit failures. A later
                // foreground sync can retry without an observer callback spinning this loop.
                resyncRequired = false
                return .giveUp
            }
            recoveryAttempts += 1
            generation += 1
            resyncRequired = false
            acceptingBatches = false
            let delay = recoveryAttempts == 1
                ? 0
                : min(60, TimeInterval(1 << (recoveryAttempts - 2)))
            return .retry(delay)
        }

        func finishRecovery() {
            lock.lock()
            recoveryAttempts = 0
            acceptingBatches = true
            lock.unlock()
        }

        func isCurrent(_ candidate: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return candidate == generation
        }

        func invalidate() {
            lock.lock()
            generation += 1
            resyncRequired = false
            acceptingBatches = false
            recoveryAttempts = 0
            lock.unlock()
        }
    }

    private var observerContinuations: [HKQuantityTypeIdentifier: AsyncStream<ObserverEvent>.Continuation] = [:]
    private var observerTasks: [HKQuantityTypeIdentifier: Task<Void, Never>] = [:]
    private var observerQueries: [HKQuantityTypeIdentifier: HKAnchoredObjectQuery] = [:]
    private var observerStates: [HKQuantityTypeIdentifier: ObserverState] = [:]

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

    nonisolated static func sourceRelationshipID(
        bundleIdentifier: String,
        sourceName: String
    ) -> String? {
        let evidence = (bundleIdentifier + " " + sourceName).lowercased()
        return evidence.contains("oura") ? "oura.account.default" : nil
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
        return types
    }

    /// Wires the manager to the store and the app's transactional ingestion seam. The
    /// callback receives sources, readings, and deleted sample ids from one anchor page and
    /// reports whether that entire generation committed before the anchor may advance.
    func configure(
        store: HealthStore,
        onReadings: @escaping @MainActor ([Reading], [DataSource], Set<UUID>) -> Bool
    ) {
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
            persistAuthorizationCompleted()
            await syncAll()
            await startObserving()
        } catch {
            availability = .denied
            lastError = error.localizedDescription
            logger.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the birth date used for the age-only VO\u{2082} max estimate so the user does not
    /// have to type what Health already knows. HeartSync deliberately does not request or
    /// retain biological sex because no current feature uses it.
    func readDateOfBirth() -> Date? {
        if let components = try? healthStore.dateOfBirthComponents() {
            return Calendar.current.date(from: components)
        }
        return nil
    }

    // MARK: - Sync

    /// Pulls everything since the stored anchor for each type, then leaves a long-running
    /// anchored query in place so later samples arrive automatically.
    func syncAll() async {
        guard availability == .authorized, !isSyncing else { return }

        // A foreground/manual sync and an observer callback must not race their anchors. The
        // observer is restarted after the finite drain; any uncommitted callback is recovered
        // from the last durable anchor rather than being trusted from memory.
        let restartObservers = !observerContinuations.isEmpty
        if restartObservers { stopObserving() }

        isSyncing = true
        defer { isSyncing = false }

        var results: [TypeSyncResult] = []
        for mapping in Self.mappings {
            results.append(await sync(mapping))
        }
        let attemptedAt = Date.now
        lastAttemptAt = attemptedAt
        let summary = HealthKitSyncSummary.aggregate(results, at: attemptedAt)
        syncSummary = summary
        if summary.outcome == .complete { lastCompleteSyncAt = attemptedAt }

        if restartObservers { await startObserving() }
    }

    private func sync(_ mapping: TypeMapping) async -> TypeSyncResult {
        let name = mapping.kind.title
        guard let type = mapping.quantityType else { return .complete(name) }
        let predicate = Self.recentPredicate()
        var anchor = loadAnchor(for: mapping.identifier)
        var processedObjects = 0

        while let limit = Self.nextQueryLimit(afterProcessed: processedObjects) {
            let batch: AnchoredBatch
            do {
                batch = try await fetchBatch(
                    type: type,
                    predicate: predicate,
                    anchor: anchor,
                    mapping: mapping,
                    limit: limit
                )
            } catch {
                // An "authorization not determined" error for one type is normal when the user
                // granted only some permissions; it should not abort the whole sync.
                logger.debug("Sync for \(mapping.identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                let detail = error.localizedDescription
                if Self.isPermissionUnknown(error) {
                    return .permissionUnknown(name, detail)
                }
                return .failed(name, detail)
            }

            guard let nextAnchor = await commit(batch, for: mapping) else {
                return .failed(name, "Could not durably save the Health data page.")
            }
            processedObjects += batch.objectCount
            anchor = nextAnchor

            // A zero-object response can still carry an anchor (for example after self-source
            // filtering). Commit it once, then stop rather than polling the same anchor.
            guard Self.shouldContinuePaging(objectCount: batch.objectCount, limit: limit) else {
                return .complete(name)
            }
        }

        logger.debug("HealthKit sync budget reached for \(mapping.identifier.rawValue, privacy: .public); will resume from the committed anchor")
        return .budgetDeferred(name)
    }

    nonisolated private static func isPermissionUnknown(_ error: any Error) -> Bool {
        guard let healthError = error as? HKError else { return false }
        return healthError.code == .errorAuthorizationDenied
            || healthError.code == .errorHealthDataRestricted
    }

    /// Fetches one finite page. Only value types cross out of HealthKit's callback queue; the
    /// opaque anchor is archived to `Data` until the main actor is ready to commit it.
    private func fetchBatch(
        type: HKQuantityType,
        predicate: NSPredicate,
        anchor: HKQueryAnchor?,
        mapping: TypeMapping,
        limit: Int
    ) async throws -> AnchoredBatch {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AnchoredBatch, Error>) in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let samples = samples ?? []
                let deleted = deleted ?? []
                let converted = Self.convert(samples, mapping: mapping)
                continuation.resume(returning: AnchoredBatch(
                    readings: converted.readings,
                    sources: converted.sources,
                    deletedIDs: Self.deletedReadingIDs(deleted),
                    objectCount: samples.count + deleted.count,
                    anchorData: newAnchor.flatMap(Self.archiveAnchor)
                ))
            }
            healthStore.execute(query)
        }
    }

    /// Applies a page before committing its anchor. If the store cannot be durably used, the
    /// anchor is deliberately left unchanged so the page is replayed rather than lost.
    private func commit(_ batch: AnchoredBatch, for mapping: TypeMapping) async -> HKQueryAnchor? {
        guard let anchorData = batch.anchorData,
              let anchor = Self.unarchiveAnchor(anchorData),
              let store
        else {
            logger.error("HealthKit page has no usable anchor; refusing to advance sync")
            return nil
        }

        // Sources, samples, and deletions belong to one HealthKit anchor generation. The
        // app's ingest seam commits them together so a failed page can be replayed without
        // leaving mixed source/reading state behind.
        guard onReadings?(
            batch.readings,
            batch.sources,
            Set(batch.deletedIDs)
        ) == true else {
            logger.error("HealthKit page transaction failed; refusing to advance sync")
            return nil
        }

        // `saveNow()` checkpoints and applies retention before the anchor write. The next
        // query must never skip a page that was not confirmed on durable storage.
        guard await store.saveNow() else {
            logger.error("HealthKit archive write failed; refusing to advance sync")
            return nil
        }
        guard store.loadState == .loaded else {
            logger.error("HealthKit archive is not durably available; refusing to advance sync")
            return nil
        }
        save(anchor: anchor, for: mapping.identifier)
        return anchor
    }

    /// The next finite query size, bounded both by the page limit and by the per-sync budget.
    nonisolated static func nextQueryLimit(afterProcessed count: Int) -> Int? {
        let remaining = maximumObjectsPerSync - max(0, count)
        guard remaining > 0 else { return nil }
        return min(queryBatchLimit, remaining)
    }

    nonisolated static func shouldContinuePaging(objectCount: Int, limit: Int) -> Bool {
        objectCount > 0 && objectCount >= limit
    }

    /// Stops one overflowing observer query. Its dropped page is not discarded semantically: the
    /// saved anchor remains behind it, and the consumer performs a finite one-shot resync.
    private func stopObserverQuery(for mapping: TypeMapping) {
        let identifier = mapping.identifier
        guard let query = observerQueries.removeValue(forKey: identifier) else { return }
        healthStore.stop(query)
        activeQueries.removeAll { $0 === query }
    }

    /// Installs one bounded observer query for a mapping. A one-slot oldest-preserving stream is
    /// the backpressure boundary: if the main actor cannot keep up, the newest callback is
    /// released and replayed from the last committed anchor after the query is stopped.
    private func installObserver(for mapping: TypeMapping) {
        guard let type = mapping.quantityType,
              let continuation = observerContinuations[mapping.identifier],
              let state = observerStates[mapping.identifier],
              observerQueries[mapping.identifier] == nil
        else { return }

        let handler: @Sendable (
            HKAnchoredObjectQuery,
            [HKSample]?,
            [HKDeletedObject]?,
            HKQueryAnchor?,
            Error?
        ) -> Void = { [continuation, state] _, samples, deleted, newAnchor, error in
            guard let generation = state.beginBatch() else { return }
            if error != nil {
                // Wake the consumer even when HealthKit reports an error while its stream is
                // empty. The state flag coalesces any repeated callbacks without creating one
                // main-actor task per error.
                state.requestResync()
                _ = continuation.yield(.resync)
                return
            }

            let samples = samples ?? []
            let deleted = deleted ?? []
            let converted = Self.convert(samples, mapping: mapping)
            let batch = AnchoredBatch(
                readings: converted.readings,
                sources: converted.sources,
                deletedIDs: Self.deletedReadingIDs(deleted),
                objectCount: samples.count + deleted.count,
                anchorData: newAnchor.flatMap(Self.archiveAnchor)
            )
            let result = continuation.yield(.batch(batch, generation: generation))
            let wasDropped: Bool
            if case .dropped = result {
                wasDropped = true
            } else {
                wasDropped = false
            }
            if wasDropped || batch.objectCount >= Self.queryBatchLimit {
                // A full observer page may have more changes waiting. Stop and drain from the
                // committed anchor so a finite update callback cannot leave a backlog behind.
                state.requestResync()
                _ = continuation.yield(.resync)
            }
        }

        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: Self.recentPredicate(),
            anchor: loadAnchor(for: mapping.identifier),
            limit: Self.observerQueryLimit,
            resultsHandler: handler
        )
        query.updateHandler = handler
        observerQueries[mapping.identifier] = query
        activeQueries.append(query)
        healthStore.execute(query)
    }

    /// Installs anchored queries with update handlers so new Health samples stream in
    /// without the user pulling to refresh.
    ///
    /// Internal (not private) so HealthKitManager+Session can restore observers on cold start.
    func startObserving() async {
        guard availability == .authorized else { return }
        stopObserving()

        for mapping in Self.mappings {
            guard let type = mapping.quantityType else { continue }
            let identifier = mapping.identifier
            let state = ObserverState()
            var continuation: AsyncStream<ObserverEvent>.Continuation!
            let stream = AsyncStream<ObserverEvent>(
                bufferingPolicy: .bufferingOldest(Self.observerBufferLimit)
            ) {
                continuation = $0
            }
            observerStates[identifier] = state
            observerContinuations[identifier] = continuation
            observerTasks[identifier] = Task { @MainActor [weak self] in
                for await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    if case let .batch(batch, generation) = event,
                       state.isCurrent(generation) {
                        let committed = await self.commit(batch, for: mapping)
                        guard !Task.isCancelled else { return }
                        if committed == nil { state.requestResync() }
                    }

                    // A dropped or failed event is intentionally not reconstructed from memory.
                    // The saved anchor remains behind it, so a finite one-shot sync recovers it
                    // in order before the live observer is installed again. Repeated durable
                    // failures use a small bounded backoff and then leave the observer stopped;
                    // the next foreground sync is the retry point.
                    var recoveryFinished = false
                    while !recoveryFinished {
                        switch state.prepareRecovery() {
                        case .none:
                            recoveryFinished = true
                        case .giveUp:
                            return
                        case .retry(let delay):
                            self.stopObserverQuery(for: mapping)
                            if delay > 0 {
                                do {
                                    try await Task.sleep(for: .seconds(delay))
                                } catch {
                                    return
                                }
                            }
                            guard !Task.isCancelled else { return }
                            if (await self.sync(mapping)).canResumeObservation {
                                guard !Task.isCancelled else { return }
                                state.finishRecovery()
                                self.installObserver(for: mapping)
                                recoveryFinished = true
                            } else {
                                state.requestResync()
                            }
                        }
                    }
                    self.lastAttemptAt = .now
                }
            }
            installObserver(for: mapping)

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
        for continuation in observerContinuations.values { continuation.finish() }
        for task in observerTasks.values { task.cancel() }
        for state in observerStates.values { state.invalidate() }
        observerContinuations.removeAll()
        observerTasks.removeAll()
        observerQueries.removeAll()
        observerStates.removeAll()
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
            // Preserve the shipped id formula as an alias: it identifies a HealthKit writer,
            // not necessarily one physical device. Device descriptors are retained below so
            // a second/replacement device cannot silently overwrite the first.
            let sourceID = "hk.\(sample.sourceBundleIdentifier)"

            if var source = sources[sourceID] {
                var models = source.observedDeviceModels ?? []
                if let model = sample.deviceModel, !model.isEmpty { models.insert(model) }
                source.observedDeviceModels = models.isEmpty ? nil : models
                source.model = models.count > 1
                    ? "Multiple reported devices: \(models.sorted().joined(separator: ", "))"
                    : models.first ?? source.model
                source.lastSeenAt = max(source.lastSeenAt ?? sample.end, sample.end)
                source.observedMetrics.insert(mapping.kind)
                sources[sourceID] = source
            } else {
                let models: Set<String> = sample.deviceModel.map { $0.isEmpty ? [] : [$0] } ?? []
                sources[sourceID] = DataSource(
                    id: sourceID,
                    displayName: sample.sourceName,
                    transport: .healthKit,
                    model: sample.deviceModel,
                    lastSeenAt: sample.end,
                    observedMetrics: [mapping.kind],
                    observedDeviceModels: models.isEmpty ? nil : models,
                    upstreamDeviceRelationshipID: sourceRelationshipID(
                        bundleIdentifier: sample.sourceBundleIdentifier,
                        sourceName: sample.sourceName
                    ),
                    identifiesHealthKitWriter: true
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
        let now = Date.now
        guard reading.start <= reading.end,
              reading.start <= now,
              reading.end <= now,
              reading.start.timeIntervalSinceReferenceDate.isFinite,
              reading.end.timeIntervalSinceReferenceDate.isFinite
        else {
            logger.debug("Refusing to write a reading with an invalid or future timestamp")
            return
        }
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
        return Self.unarchiveAnchor(data)
    }

    private func save(anchor: HKQueryAnchor, for identifier: HKQuantityTypeIdentifier) {
        guard let data = Self.archiveAnchor(anchor) else { return }
        UserDefaults.standard.set(data, forKey: anchorKey(identifier))
    }

    nonisolated private static func archiveAnchor(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    nonisolated private static func unarchiveAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// Clears anchors so the next sync re-reads the full retention window. Safe because
    /// readings de-duplicate on the HealthKit sample UUID.
    func resetAnchors() {
        for mapping in Self.mappings {
            UserDefaults.standard.removeObject(forKey: anchorKey(mapping.identifier))
        }
    }
}
