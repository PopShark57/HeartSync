import Foundation
import Observation
import OSLog

private struct CompactionBucket: Hashable {
    let start: Date
    let sourceID: String
}

/// Why a history query could not answer.
///
/// The point of naming these is that "no rows" and "the query failed" are different facts
/// with opposite meanings for the user, and the app used to render both as an empty screen.
enum HealthStoreQueryError: LocalizedError, Equatable {
    /// The database handle could not be opened at all.
    case storeUnavailable(String)
    /// Startup has not finished, or it finished by failing. Readings may exist on disk.
    case notLoaded
    /// SQLite answered with an error, or a stored row could not be decoded.
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable(let detail): "The measurement database could not be opened. \(detail)"
        case .notLoaded:                    "The measurement database has not finished loading."
        case .queryFailed(let detail):      "The measurement database could not be read. \(detail)"
        }
    }
}

/// The result of a history query: rows, or a reason there are none.
///
/// Deliberately not `[Reading]?` — a nil would collapse back into the same ambiguity this
/// type exists to remove. Callers that genuinely cannot present an error (a background
/// projection, a legacy call site) use `valueOrEmpty`, and that spelling is intentionally
/// visible at the call site so the choice to discard the failure is a decision someone made.
enum HealthStoreQueryOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(HealthStoreQueryError)

    var value: Value? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var error: HealthStoreQueryError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }

    var isFailure: Bool { error != nil }

    func get() throws -> Value {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    /// Transforms a successful value, preserving a failure unchanged.
    func map<Mapped: Sendable>(_ transform: (Value) -> Mapped) -> HealthStoreQueryOutcome<Mapped> {
        switch self {
        case .success(let value): .success(transform(value))
        case .failure(let error): .failure(error)
        }
    }
}

extension HealthStoreQueryOutcome where Value: RangeReplaceableCollection {
    /// Rows on success, an empty collection on failure. Only for call sites that have no
    /// way to show an error; anything user-facing should branch on the outcome instead.
    var valueOrEmpty: Value {
        value ?? Value()
    }
}

/// The app's single source/readings boundary, backed by one transactional indexed SQLite
/// database. The public query shape is preserved so transport and analysis code do not own
/// persistence details.
@MainActor
@Observable
final class HealthStore {
    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Store")

    private(set) var sources: [DataSource] = []
    private var dataGeneration = 0
    /// Observed invalidation token for bounded external display projections.
    var changeToken: Int { dataGeneration }
    /// Advances only when readings or a source are removed, or history is reloaded, so a
    /// cache of a slow projection (the watch's 7- and 30-day charts) can survive ordinary
    /// appends yet never show deleted data. Estimate reconciliation does not advance it.
    private(set) var removalGeneration = 0
    private var unavailableBuffer: [Reading] = []
    private var bufferedIDs: Set<UUID> = []

    /// How long readings are kept. Setting it does not by itself permit deletion: pruning
    /// waits for `confirmRetention`, so the default that a store starts with, or one read
    /// from settings that could not be trusted, can never delete history.
    var retention: TimeInterval = 30 * 86_400
    /// Whether `retention` came from a source that may delete data. A store that persists
    /// starts unconfirmed; one that does not has no history worth protecting.
    private(set) var retentionIsConfirmed: Bool
    /// The retention, in days, that an untrusted source asked for while a longer one was on
    /// record. Pruning stays paused until the user confirms a period in Settings.
    private(set) var retentionHeldBackDays: Int?
    static let retentionMetadataKey = "retention_days"
    /// `lastSeenAt` moves in steps of at least this long. It is shown as "seen N seconds ago"
    /// on the Devices list, and only a change a person can see is worth a re-render.
    static let lastSeenResolution: TimeInterval = 15
    static let minimumCompactionAge: TimeInterval = 14 * 86_400
    static let longestComparisonWindow: TimeInterval = MetricKind.allCases.map(\.comparisonWindow).max() ?? 0
    static let compactionSpanPerPass: TimeInterval = max(3 * 86_400, longestComparisonWindow)
    /// Passes one maintenance run may take, so a backlog clears in a few runs without one
    /// run holding the main actor for a month of history.
    static let maximumCompactionPassesPerMaintenance = 5
    private var compactionAgeStorage: TimeInterval = minimumCompactionAge
    var compactionAge: TimeInterval {
        get { compactionAgeStorage }
        set { compactionAgeStorage = max(Self.minimumCompactionAge, newValue) }
    }

    enum LoadState: Sendable, Equatable { case notLoaded, loaded, failed }
    private(set) var loadState: LoadState
    private(set) var unavailableCollections: [String] = []
    private(set) var recoveredCorruptCollections: [String] = []
    private(set) var lastPersistenceError: String?

    let persistenceEnabled: Bool
    private let archive: ReadingArchive
    private let configuredDatabaseURL: URL?
    private var database: HealthDatabase?
    /// Read-only connections for every history read, on and off the main actor. Writes
    /// stay on `database`.
    private var readers: HealthDatabase.ReaderPool?
    private var needsLegacyMigration: Bool
    private var loadTask: Task<Void, Never>?
    private var compactionCursor: Date?

    static let maximumReadingsWhileArchiveUnavailable = 10_000

    init(
        persistenceEnabled: Bool = true,
        databaseURL: URL? = nil,
        archive: ReadingArchive = .shared
    ) {
        self.persistenceEnabled = persistenceEnabled
        self.retentionIsConfirmed = !persistenceEnabled
        self.archive = archive
        self.configuredDatabaseURL = databaseURL
        do {
            let url: URL?
            if persistenceEnabled {
                url = try databaseURL ?? HealthDatabase.defaultURL()
            } else {
                url = nil
            }
            let database = try HealthDatabase(url: url)
            self.database = database
            self.readers = HealthDatabase.ReaderPool(writer: database)
            self.needsLegacyMigration = persistenceEnabled && database.requiresLegacyMigration
            self.loadState = persistenceEnabled ? .notLoaded : .loaded
        } catch {
            self.database = nil
            self.needsLegacyMigration = false
            self.loadState = persistenceEnabled ? .failed : .loaded
            self.lastPersistenceError = error.localizedDescription
        }
    }

    /// The source list, generations, and read connections as a value, for building a
    /// snapshot off the main actor (`HealthHistory.offMain`). Reading this property
    /// observes the same state the store's own queries observe.
    var history: HealthHistory {
        HealthHistory(
            sources: sources,
            changeToken: dataGeneration,
            removalGeneration: removalGeneration,
            loadState: loadState,
            readers: readers,
            pending: persistenceEnabled && loadState != .loaded ? unavailableBuffer : [],
            unavailableDetail: lastPersistenceError
        )
    }

    /// Compatibility access for tests and explicit whole-history export only. App screens
    /// use indexed range queries; ordinary rendering never materializes the full database.
    var readings: [Reading] {
        _ = dataGeneration
        if persistenceEnabled, loadState != .loaded { return unavailableBuffer }
        return query { try $0.allReadings() }.valueOrEmpty
    }

    var readingCount: Int {
        readingCountOutcome.value ?? 0
    }

    /// Distinguishes "the database holds nothing" from "the count could not be read",
    /// which the Compare empty state depends on to avoid claiming an empty install.
    var readingCountOutcome: HealthStoreQueryOutcome<Int> {
        _ = dataGeneration
        if persistenceEnabled, loadState != .loaded { return .success(unavailableBuffer.count) }
        return query { try $0.readingCount() }
    }

    // MARK: - Sources

    func source(id: String) -> DataSource? { sources.first { $0.id == id } }
    func displayName(forSource id: String) -> String { source(id: id)?.displayName ?? "Unknown device" }
    var enabledSources: [DataSource] { sources.filter(\.isEnabled) }

    /// The outcome of a change to the source list.
    ///
    /// A change is written first and published second, so a failed write leaves the list
    /// exactly as it was and says so. The caller can then tell the user, instead of showing a
    /// removal, rename, or pause that reverts at the next launch.
    enum SourceMutationResult: Equatable, Sendable {
        case applied
        /// Nothing to change: the source is unknown or already in the requested state.
        case unchanged
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private static let notLoadedDetail = "The health history has not finished loading."

    @discardableResult
    func upsert(_ source: DataSource) -> DataSource {
        let before = sources
        let stored = merge(source)
        guard sources != before else { return stored }
        if let detail = persistSourcesIfReady([stored]) {
            sources = before
            logger.error("Source update rolled back: \(detail, privacy: .public)")
            return stored
        }
        dataGeneration &+= 1
        return stored
    }

    /// Merges source metadata in memory. Batch ingestion uses this without writing first so
    /// source descriptors, readings, and upstream deletions share one SQLite transaction.
    private func merge(_ source: DataSource) -> DataSource {
        let stored: DataSource
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            var existing = sources[index]
            let now = Date.now
            if existing.displayNameIsUserChosen != true { existing.displayName = source.displayName }
            existing.model = source.model ?? existing.model
            existing.lastSeenAt = [existing.lastSeenAt, source.lastSeenAt]
                .compactMap { boundedLastSeen($0, now: now) }
                .max()
            existing.bodyLocation = source.bodyLocation ?? existing.bodyLocation
            existing.sensingTechnology = source.sensingTechnology ?? existing.sensingTechnology
            if let models = source.observedDeviceModels {
                var known = existing.observedDeviceModels ?? []
                known.formUnion(models)
                existing.observedDeviceModels = known
                existing.model = known.count > 1
                    ? "Multiple reported devices: \(known.sorted().joined(separator: ", "))"
                    : known.first ?? existing.model
            }
            existing.upstreamDeviceRelationshipID = source.upstreamDeviceRelationshipID
                ?? existing.upstreamDeviceRelationshipID
            existing.identifiesHealthKitWriter = source.identifiesHealthKitWriter
                ?? existing.identifiesHealthKitWriter
            if let battery = source.batteryPercent { existing.batteryPercent = battery }
            existing.observedMetrics.formUnion(source.observedMetrics)
            sources[index] = existing
            stored = existing
        } else {
            var newSource = source
            newSource.lastSeenAt = boundedLastSeen(source.lastSeenAt)
            newSource.colorIndex = nextColorIndex()
            sources.append(newSource)
            stored = newSource
        }
        return stored
    }

    /// Deletes a source and all of its readings, database first.
    ///
    /// The list and the buffer change only after the delete has committed. Before startup has
    /// finished the removal is refused: it would change memory alone, and the source and its
    /// readings would return when the database loads.
    func removeSourceResult(id sourceID: String) -> SourceMutationResult {
        if persistenceEnabled, loadState != .loaded { return .failed(Self.notLoadedDetail) }
        let inMemory = sources.contains { $0.id == sourceID }
        let buffered = unavailableBuffer.contains { $0.sourceID == sourceID }
        let storedRows = ((try? database?.sourceHistory(sourceID: sourceID))?.count ?? 0) > 0
        guard inMemory || buffered || storedRows else { return .unchanged }
        do { try database?.removeSource(id: sourceID) }
        catch {
            record(error)
            return .failed(error.localizedDescription)
        }
        sources.removeAll { $0.id == sourceID }
        unavailableBuffer.removeAll { $0.sourceID == sourceID }
        bufferedIDs = Set(unavailableBuffer.map(\.id))
        dataGeneration &+= 1
        removalGeneration &+= 1
        return .applied
    }

    /// Compatibility spelling: true only when something was removed.
    @discardableResult
    func remove(sourceID: String) -> Bool {
        removeSourceResult(id: sourceID) == .applied
    }

    /// Deletes every stored reading of one source and keeps the source itself.
    @discardableResult
    func removeReadings(forSource sourceID: String) -> Int {
        guard isReadyToPersist else { return 0 }
        do {
            let removed = try database?.removeReadings(sourceID: sourceID) ?? 0
            if removed > 0 {
                dataGeneration &+= 1
                removalGeneration &+= 1
            }
            return removed
        } catch {
            record(error)
            return 0
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, forSource id: String) -> SourceMutationResult {
        mutateSource(id) { $0.isEnabled = enabled }
    }

    @discardableResult
    func rename(sourceID: String, to name: String) -> SourceMutationResult {
        mutateSource(sourceID) {
            $0.displayName = name
            $0.displayNameIsUserChosen = true
        }
    }

    func updateBattery(_ percent: Int, forSource id: String) {
        mutateSource(id) {
            $0.batteryPercent = percent
            $0.lastSeenAt = .now
        }
    }

    func setBodyLocation(_ location: BodySensorLocation, forSource id: String) {
        mutateSource(id) { $0.bodyLocation = location }
    }

    func markSeen(sourceID: String, at date: Date = .now) {
        guard let date = boundedLastSeen(date) else { return }
        mutateSource(sourceID) { $0.lastSeenAt = date }
    }

    @discardableResult
    private func mutateSource(_ id: String, mutation: (inout DataSource) -> Void) -> SourceMutationResult {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return .unchanged }
        var updated = sources[index]
        mutation(&updated)
        guard updated != sources[index] else { return .unchanged }
        if persistenceEnabled, loadState != .loaded { return .failed(Self.notLoadedDetail) }
        if let detail = persistSourcesIfReady([updated]) { return .failed(detail) }
        sources[index] = updated
        dataGeneration &+= 1
        return .applied
    }

    private func nextColorIndex() -> Int {
        let used = Set(sources.map(\.colorIndex))
        for index in 0..<DataSource.palette.count where !used.contains(index) { return index }
        return sources.count % DataSource.palette.count
    }

    // MARK: - Readings

    @discardableResult
    func append(_ reading: Reading) -> Bool {
        !append(contentsOf: [reading]).isEmpty
    }

    @discardableResult
    func append(contentsOf candidates: [Reading]) -> [Reading] {
        store(candidates, mode: .append).acceptedReadings
    }

    @discardableResult
    func upsert(contentsOf candidates: [Reading]) -> [Reading] {
        store(candidates, mode: .upsert).acceptedReadings
    }

    struct BatchCommitResult: Sendable {
        var acceptedReadings: [Reading]
        /// True for a committed database transaction, including an idempotent replay whose
        /// readings were already present. False means an upstream anchor/cache must not advance.
        var committed: Bool
    }

    func appendBatch(
        readings: [Reading],
        updatingSources: [DataSource] = [],
        removingReadingIDs: Set<UUID> = []
    ) -> BatchCommitResult {
        store(
            readings,
            mode: .append,
            updatingSources: updatingSources,
            removingReadingIDs: removingReadingIDs
        )
    }

    func upsertBatch(
        readings: [Reading],
        updatingSources: [DataSource] = [],
        removingReadingIDs: Set<UUID> = []
    ) -> BatchCommitResult {
        store(
            readings,
            mode: .upsert,
            updatingSources: updatingSources,
            removingReadingIDs: removingReadingIDs
        )
    }

    private func store(
        _ candidates: [Reading],
        mode: HealthDatabase.WriteMode,
        updatingSources sourceUpdates: [DataSource] = [],
        removingReadingIDs: Set<UUID> = []
    ) -> BatchCommitResult {
        guard !candidates.isEmpty || !sourceUpdates.isEmpty || !removingReadingIDs.isEmpty else {
            return BatchCommitResult(acceptedReadings: [], committed: true)
        }
        let sourcesBeforeCommit = sources
        for source in sourceUpdates { _ = merge(source) }
        let sourcesChanged = sources != sourcesBeforeCommit

        var latest: [UUID: Reading] = [:]
        var order: [UUID] = []
        let now = Date.now
        for reading in candidates {
            guard reading.isPlausible, isTemporallyValid(reading, now: now) else { continue }
            if mode == .append, latest[reading.id] != nil { continue }
            if latest.updateValue(reading, forKey: reading.id) == nil { order.append(reading.id) }
        }
        var valid = order.compactMap { latest[$0] }

        if persistenceEnabled, loadState != .loaded {
            var changed: [Reading] = []
            for reading in valid {
                if mode == .append, bufferedIDs.contains(reading.id) { continue }
                if let index = unavailableBuffer.firstIndex(where: { $0.id == reading.id }) {
                    guard mode == .upsert, unavailableBuffer[index] != reading else { continue }
                    unavailableBuffer[index] = reading
                } else {
                    unavailableBuffer.append(reading)
                    bufferedIDs.insert(reading.id)
                }
                changed.append(reading)
            }
            unavailableBuffer.sort { $0.end < $1.end }
            trimUnavailableArchiveBufferIfNeeded()
            dataGeneration &+= changed.isEmpty && !sourcesChanged ? 0 : 1
            return BatchCommitResult(acceptedReadings: changed, committed: false)
        }

        guard let database else {
            sources = sourcesBeforeCommit
            return BatchCommitResult(acceptedReadings: [], committed: false)
        }
        do {
            // An interval average is never folded into a window (see `compact`), so a
            // compacted window at its midpoint says nothing about it, and Oura may still
            // revise it. One lookup for the batch, not one per reading.
            let aggregateIDs = Dictionary(
                valid.filter { !$0.isIntervalAverage }.map { ($0.id, compactedReadingID(for: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
            let compacted = try database.existingIDs(Array(Set(aggregateIDs.values)))
            if !compacted.isEmpty {
                valid.removeAll { reading in
                    guard let aggregate = aggregateIDs[reading.id] else { return false }
                    return compacted.contains(aggregate) && reading.id != aggregate
                }
            }
            let changed = try database.changedReadings(valid, mode: mode)
            guard !changed.isEmpty || sourcesChanged || !removingReadingIDs.isEmpty else {
                return BatchCommitResult(acceptedReadings: [], committed: true)
            }
            noteObserved(changed)
            // Only rows that differ from what is stored. Every source used to be rewritten on
            // every commit because one source's last-seen time had moved.
            let previous = Dictionary(sourcesBeforeCommit.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let changedSources = sources.filter { previous[$0.id] != $0 }
            do {
                let removed = try database.commit(
                    readings: changed,
                    mode: mode,
                    sources: changedSources,
                    removingReadingIDs: removingReadingIDs
                )
                rewindCompactionIfNeeded(for: changed)
                dataGeneration &+= (!changed.isEmpty || sourcesChanged || removed > 0) ? 1 : 0
                removalGeneration &+= removed > 0 ? 1 : 0
                return BatchCommitResult(acceptedReadings: changed, committed: true)
            } catch {
                sources = sourcesBeforeCommit
                throw error
            }
        } catch {
            sources = sourcesBeforeCommit
            record(error)
            return BatchCommitResult(acceptedReadings: [], committed: false)
        }
    }

    @discardableResult
    func remove(readingIDs: some Sequence<UUID>) -> Int {
        let ids = Set(readingIDs)
        guard !ids.isEmpty else { return 0 }
        if persistenceEnabled, loadState != .loaded {
            let before = unavailableBuffer.count
            unavailableBuffer.removeAll { ids.contains($0.id) }
            bufferedIDs = Set(unavailableBuffer.map(\.id))
            return before - unavailableBuffer.count
        }
        do {
            let removed = try database?.removeReadingIDs(ids) ?? 0
            dataGeneration &+= removed > 0 ? 1 : 0
            removalGeneration &+= removed > 0 ? 1 : 0
            return removed
        } catch {
            record(error)
            return 0
        }
    }

    /// Removes HeartSync's own estimates that are no longer current.
    ///
    /// - Parameter sourceID: limits the sweep to the source that owns the estimates. Without
    ///   it every estimated row of `kinds` is a candidate, which is only right for a metric
    ///   no transport reports as an estimate.
    @discardableResult
    func reconcileEstimates(
        kinds: Set<MetricKind>,
        keeping validIDs: Set<UUID>,
        currentSince: Date? = nil,
        sourceID: String? = nil
    ) -> Int {
        guard isReadyToPersist || !persistenceEnabled else { return 0 }
        do {
            let removed = try database?.removeEstimates(
                kinds: kinds,
                keeping: validIDs,
                currentSince: currentSince,
                sourceID: sourceID
            ) ?? 0
            dataGeneration &+= removed > 0 ? 1 : 0
            return removed
        } catch {
            record(error)
            return 0
        }
    }

    /// Runs a database read, converting a throw or a missing handle into a named failure.
    ///
    /// Deliberately free of side effects. These queries are called from SwiftUI view
    /// bodies while an immutable snapshot is being resolved, so recording the failure in
    /// observed state here would mutate the model during a view update. The failure
    /// travels back to the screen inside the snapshot that asked for it instead.
    ///
    /// Reads go through the read-only pool, never the writer connection, so a main-actor
    /// read and an off-main snapshot read never share a connection.
    private func query<Value>(_ body: (HealthDatabase) throws -> Value) -> HealthStoreQueryOutcome<Value> {
        guard let readers else {
            return .failure(.storeUnavailable(lastPersistenceError ?? "No database handle is open."))
        }
        do {
            return .success(try readers.read(body))
        } catch {
            logger.error("History query failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.queryFailed(error.localizedDescription))
        }
    }

    func readingsOutcome(
        kind: MetricKind,
        in range: DateInterval? = nil,
        enabledOnly: Bool = true
    ) -> HealthStoreQueryOutcome<[Reading]> {
        _ = dataGeneration
        guard loadState == .loaded else {
            guard persistenceEnabled else { return .success(unavailableBuffer.filter { $0.kind == kind }) }
            return .failure(.notLoaded)
        }
        let enabled = enabledOnly ? Set(enabledSources.map(\.id)) : nil
        return query { try $0.readings(kind: kind, range: range, sourceIDs: enabled) }
    }

    func readingsOutcome(in range: DateInterval, enabledOnly: Bool = true) -> HealthStoreQueryOutcome<[Reading]> {
        _ = dataGeneration
        guard loadState == .loaded else {
            guard persistenceEnabled else { return .success(unavailableBuffer.filter { range.contains($0.midpoint) }) }
            return .failure(.notLoaded)
        }
        let enabled = enabledOnly ? Set(enabledSources.map(\.id)) : nil
        return query { try $0.readings(range: range, sourceIDs: enabled) }
    }

    /// Readings of every metric that end at or after `end`, limited to midpoints in `range`.
    ///
    /// For live screens: a reading is current by its *end*, and a long interval reading —
    /// an overnight average that finished minutes ago — has a midpoint hours back, outside
    /// any short midpoint window. Reading through the `end` index finds those without
    /// scanning days of history.
    func readingsOutcome(
        endingAtOrAfter end: Date,
        midpointIn range: DateInterval,
        enabledOnly: Bool = true
    ) -> HealthStoreQueryOutcome<[Reading]> {
        _ = dataGeneration
        guard loadState == .loaded else {
            guard persistenceEnabled else {
                return .success(unavailableBuffer.filter { $0.end >= end && range.contains($0.midpoint) })
            }
            return .failure(.notLoaded)
        }
        let enabled = enabledOnly ? Set(enabledSources.map(\.id)) : nil
        return query { try $0.readings(endingAtOrAfter: end, midpointIn: range) }
            .map { rows in enabled.map { ids in rows.filter { ids.contains($0.sourceID) } } ?? rows }
    }

    func readings(kind: MetricKind, in range: DateInterval? = nil, enabledOnly: Bool = true) -> [Reading] {
        guard loadState == .loaded || !persistenceEnabled else {
            return unavailableBuffer.filter { $0.kind == kind }
        }
        return readingsOutcome(kind: kind, in: range, enabledOnly: enabledOnly).valueOrEmpty
    }

    func readings(in range: DateInterval, enabledOnly: Bool = true) -> [Reading] {
        guard loadState == .loaded || !persistenceEnabled else {
            return unavailableBuffer.filter { range.contains($0.midpoint) }
        }
        return readingsOutcome(in: range, enabledOnly: enabledOnly).valueOrEmpty
    }

    func readingsPage(
        kind: MetricKind? = nil,
        in range: DateInterval? = nil,
        limit: Int = 1_000,
        offset: Int = 0
    ) -> [Reading] {
        readingsPageOutcome(kind: kind, in: range, limit: limit, offset: offset).valueOrEmpty
    }

    func readingsPageOutcome(
        kind: MetricKind? = nil,
        in range: DateInterval? = nil,
        sourceID: String? = nil,
        limit: Int = 1_000,
        offset: Int = 0
    ) -> HealthStoreQueryOutcome<[Reading]> {
        _ = dataGeneration
        return query {
            try $0.readings(kind: kind, range: range, sourceID: sourceID, limit: limit, offset: offset)
        }
    }

    /// What removing one source would delete, stated before anything is deleted.
    struct SourceHistorySummary: Equatable, Sendable {
        /// Stored rows for the source. After compaction a row can be a window median, so
        /// this counts what the database holds, not how many measurements were ever taken.
        var readingCount: Int
        /// Midpoint of the earliest stored reading, or nil when nothing is stored.
        var earliest: Date?
    }

    /// Row count and earliest stored reading for one source, from the source index.
    ///
    /// A failure is returned rather than a zero: a removal confirmation that said "no
    /// readings" because the count could not be read would understate what is deleted.
    func sourceHistorySummaryOutcome(sourceID: String) -> HealthStoreQueryOutcome<SourceHistorySummary> {
        _ = dataGeneration
        guard loadState == .loaded || !persistenceEnabled else { return .failure(.notLoaded) }
        return query { database in
            let history = try database.sourceHistory(sourceID: sourceID)
            return SourceHistorySummary(readingCount: history.count, earliest: history.earliestMidpoint)
        }
    }

    /// How many readings a fixed period holds for some sources, and which ones.
    struct PeriodReadingSummary: Equatable, Sendable {
        var count: Int
        /// Identity summary of the rows counted; see `HealthDatabase.readingSummary`.
        var fingerprint: Int64
    }

    /// Counts a session's own readings (its sources and metric) from the index, without
    /// decoding them. A failure is returned, never a zero: a revisit notice that said
    /// "unchanged" because the count could not be read would be false.
    func periodSummaryOutcome(
        interval: DateInterval,
        sourceIDs: Set<String>?,
        kind: MetricKind?
    ) -> HealthStoreQueryOutcome<PeriodReadingSummary> {
        history.periodSummaryOutcome(interval: interval, sourceIDs: sourceIDs, kind: kind)
    }

    /// Whole-history read for the explicit export. Throws rather than returning an empty
    /// array so a failed query cannot be shared as an empty history.
    func allReadingsForExport() throws -> [Reading] {
        _ = dataGeneration
        guard loadState == .loaded || !persistenceEnabled else { throw HealthStoreQueryError.notLoaded }
        return try query { try $0.allReadings() }.get()
    }

    func latest(kind: MetricKind, sourceID: String) -> Reading? {
        _ = dataGeneration
        return query { try $0.latest(kind: kind, sourceID: sourceID) }.value ?? nil
    }

    func lastDataDate(sourceID: String) -> Date? {
        _ = dataGeneration
        return query { try $0.lastDataDate(sourceID: sourceID) }.value ?? nil
    }

    var availableMetrics: [MetricKind] {
        let observed = Set(enabledSources.flatMap(\.observedMetrics))
        return MetricKind.allCases.filter { observed.contains($0) }
    }

    func comparableMetrics(in range: DateInterval) -> [MetricKind] {
        MetricKind.allCases.filter { Set(readings(kind: $0, in: range).map(\.sourceID)).count >= 2 }
    }

    // MARK: - Retention and compaction

    struct RetentionImpact: Equatable, Sendable {
        var cutoff: Date
        var readingsDeleted: Int
        var readingsEligibleForCompaction: Int
    }

    /// What a retention of `days` would delete and what compaction would still fold, counted
    /// in SQL on the `end` index rather than by decoding the history.
    func retentionImpact(days: Int, now: Date = .now) -> RetentionImpact {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        guard loadState == .loaded || !persistenceEnabled else {
            return RetentionImpact(cutoff: cutoff, readingsDeleted: 0, readingsEligibleForCompaction: 0)
        }
        let counts = query { database in
            (
                try database.readingCount(endingBefore: cutoff),
                try database.rawReadingCount(endingFrom: cutoff, before: now.addingTimeInterval(-compactionAge))
            )
        }.value
        return RetentionImpact(
            cutoff: cutoff,
            readingsDeleted: counts?.0 ?? 0,
            readingsEligibleForCompaction: counts?.1 ?? 0
        )
    }

    // MARK: - Retention confirmation

    /// Installs a retention that may delete data, and remembers it in the database.
    ///
    /// `retention` starts at 30 days and is also what an unreadable, reset, or newer-schema
    /// settings file falls back to. Pruning with that value would delete months of history
    /// on the strength of a default the user never chose, so a persisting store prunes only
    /// once a caller that trusts its source has confirmed a period.
    ///
    /// The last confirmed period is recorded in the `metadata` table. A settings file lost
    /// and recreated with the default therefore cannot shorten it: a period shorter than the
    /// one on record holds pruning until the user chooses one (`userInitiated`).
    @discardableResult
    func confirmRetention(days: Int, userInitiated: Bool = false) -> Bool {
        retention = TimeInterval(days) * 86_400
        guard persistenceEnabled else {
            retentionIsConfirmed = true
            return true
        }
        guard loadState == .loaded, let database else {
            retentionIsConfirmed = false
            return false
        }
        let recorded = (try? database.metadataValue(Self.retentionMetadataKey)).flatMap { $0 }.flatMap(Int.init)
        if !userInitiated, let recorded, days < recorded {
            retentionIsConfirmed = false
            retentionHeldBackDays = recorded
            return false
        }
        if recorded != days {
            do { try database.setMetadata(String(days), forKey: Self.retentionMetadataKey) }
            catch {
                // Without a record the guard above cannot protect a later launch, so treat
                // the period as unconfirmed rather than deleting on an unrecorded choice.
                record(error)
                retentionIsConfirmed = false
                return false
            }
        }
        retentionIsConfirmed = true
        retentionHeldBackDays = nil
        return true
    }

    /// Stops pruning until a retention is confirmed again, for a source that cannot be
    /// trusted right now (settings that failed to load or were reset).
    func suspendRetention() {
        guard persistenceEnabled else { return }
        retentionIsConfirmed = false
    }

    /// Deletes readings older than the confirmed retention, and rows with impossible clocks
    /// when `includingInvalidRows` is set (once, at load: they need a scan).
    ///
    /// Returns false only for a failure. While the retention is unconfirmed it deletes no
    /// aged history, which is a deliberate no-op rather than an error.
    @discardableResult
    func prune(now: Date = .now, includingInvalidRows: Bool = false) -> Bool {
        guard loadState == .loaded, let database else { return false }
        let cutoff = retentionIsConfirmed ? now.addingTimeInterval(-retention) : Date.distantPast
        let originalSources = sources
        var clamped: [DataSource] = []
        do {
            for index in sources.indices where (sources[index].lastSeenAt ?? .distantPast) > now {
                sources[index].lastSeenAt = now
                clamped.append(sources[index])
            }
            // A row may begin up to the accepted clock skew ahead; only one beyond it is
            // impossible and goes.
            let removed = try database.prune(
                cutoff: cutoff,
                now: now.addingTimeInterval(Self.maximumFutureSkew),
                changedSources: clamped,
                includingInvalidRows: includingInvalidRows
            )
            dataGeneration &+= removed > 0 ? 1 : 0
            removalGeneration &+= removed > 0 ? 1 : 0
            return true
        } catch {
            sources = originalSources
            record(error)
            return false
        }
    }

    @discardableResult
    func compact(now: Date = .now) -> Bool {
        guard loadState == .loaded, let database else { return false }
        let oldest: Date
        do {
            guard let first = try database.readings(limit: 1).first else { return true }
            oldest = first.end
        } catch {
            record(error)
            return false
        }
        let ageCutoff = now.addingTimeInterval(-compactionAge)
        let passStart = max(compactionCursor ?? oldest, oldest)
        guard passStart < ageCutoff else { return true }
        let cutoff = min(ageCutoff, passStart.addingTimeInterval(Self.compactionSpanPerPass))
        let aged: [Reading]
        do {
            // Only this pass's span, plus one comparison window behind it: a window that
            // straddled the previous pass's cutoff was left whole then, and needs its earlier
            // rows now. Rows already folded there are single aggregates and are skipped below.
            let readStart = passStart.addingTimeInterval(-Self.longestComparisonWindow)
            aged = try database.readings(range: DateInterval(start: readStart, end: cutoff))
        } catch {
            record(error)
            return false
        }
        guard !aged.isEmpty else {
            compactionCursor = cutoff
            return true
        }

        var replacements: [Reading] = []
        var supersededIDs: Set<UUID> = []
        for (kind, group) in Dictionary(grouping: aged, by: \.kind) {
            var members: [CompactionBucket: [Reading]] = [:]
            // An interval average stays a row of its own. Folded into the window at its
            // midpoint, a night's mean would lose its span and be paired as one minute.
            for reading in group where reading.isPlausible && !reading.isIntervalAverage {
                let start = ComparisonEngine.floorToWindow(reading.midpoint, size: kind.comparisonWindow)
                members[CompactionBucket(start: start, sourceID: reading.sourceID), default: []].append(reading)
            }
            let windows = ComparisonEngine.windows(
                from: group,
                kind: kind,
                windowSize: kind.comparisonWindow,
                includeEstimated: true
            )
            for window in windows where window.end <= cutoff {
                for value in window.values {
                    let bucket = CompactionBucket(start: window.start, sourceID: value.sourceID)
                    guard let collapsed = members[bucket], collapsed.count > 1 else { continue }
                    let aggregateID = compactedReadingID(
                        sourceID: value.sourceID,
                        kind: kind,
                        windowStart: window.start
                    )
                    if collapsed.contains(where: { $0.id == aggregateID }) {
                        supersededIDs.formUnion(collapsed.filter { $0.id != aggregateID }.map(\.id))
                        continue
                    }
                    supersededIDs.formUnion(collapsed.map(\.id))
                    replacements.append(Reading(
                        id: aggregateID,
                        sourceID: value.sourceID,
                        kind: kind,
                        value: value.value,
                        start: window.start,
                        end: window.end,
                        provenance: value.provenance,
                        metadata: ReadingMetadata(aggregation: AggregationMetadata(
                            originalSampleCount: value.sampleCount,
                            originalStandardDeviation: value.standardDeviation
                        ))
                    ))
                }
            }
        }
        guard !supersededIDs.isEmpty else {
            compactionCursor = cutoff
            return true
        }
        do {
            try database.replaceReadings(removing: supersededIDs, with: replacements)
            compactionCursor = cutoff
            dataGeneration &+= 1
            logger.info("Compacted \(supersededIDs.count) readings into \(replacements.count)")
            return true
        } catch {
            record(error)
            return false
        }
    }

    // MARK: - Persistence and migration

    func loadIfNeeded() async {
        guard persistenceEnabled, loadState != .loaded else { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        if database == nil {
            do {
                let url = try configuredDatabaseURL ?? HealthDatabase.defaultURL()
                let reopened = try HealthDatabase(url: url)
                database = reopened
                readers = HealthDatabase.ReaderPool(writer: reopened)
                needsLegacyMigration = reopened.requiresLegacyMigration
                lastPersistenceError = nil
            } catch {
                loadState = .failed
                lastPersistenceError = error.localizedDescription
                unavailableCollections = ["health.sqlite3: \(error.localizedDescription)"]
                return
            }
        }
        guard let database else { return }
        unavailableCollections.removeAll()
        recoveredCorruptCollections.removeAll()
        do {
            if needsLegacyMigration {
                let sourcesOutcome = await archive.readOutcome([DataSource].self, from: ReadingArchive.File.sources)
                let readingsOutcome = await archive.readOutcome([Reading].self, from: ReadingArchive.File.readings)
                noteOutcome(sourcesOutcome, collection: ReadingArchive.File.sources)
                noteOutcome(readingsOutcome, collection: ReadingArchive.File.readings)
                guard sourcesOutcome.isConclusive, readingsOutcome.isConclusive else {
                    loadState = .failed
                    return
                }
                sources = sourcesOutcome.value ?? []
                var migratedReadings = readingsOutcome.value ?? []
                migratedReadings.append(contentsOf: unavailableBuffer)
                migratedReadings = deduplicated(migratedReadings)
                noteObserved(migratedReadings)
                try database.replaceAll(
                    readings: migratedReadings,
                    sources: sources,
                    completingLegacyMigration: true
                )
                needsLegacyMigration = false
            } else {
                sources = try database.allSources()
                if !unavailableBuffer.isEmpty {
                    let changed = try database.changedReadings(unavailableBuffer, mode: .append)
                    noteObserved(changed)
                    try database.commit(readings: changed, mode: .append, sources: sources)
                }
            }
            unavailableBuffer.removeAll()
            bufferedIDs.removeAll()
            loadState = .loaded
            lastPersistenceError = nil
            compactionCursor = nil
            dataGeneration &+= 1
            removalGeneration &+= 1
            // Aged history waits for `confirmRetention`; only impossible rows go now.
            prune(includingInvalidRows: true)
            logger.info("Loaded \(self.readingCount) readings across \(self.sources.count) sources")
        } catch {
            loadState = .failed
            record(error)
        }
    }

    /// Maintenance: prune, compact a bounded backlog, checkpoint the write-ahead log.
    ///
    /// Not a durability step. A committed transaction is already on disk (`synchronous =
    /// FULL`), so ingest paths, the HealthKit anchor among them, do not wait for this. Run it
    /// on a timer and at background transitions.
    @discardableResult
    func saveNow() async -> Bool {
        guard persistenceEnabled, loadState == .loaded, let database else { return false }
        guard prune() else { return false }
        for _ in 0..<Self.maximumCompactionPassesPerMaintenance {
            guard compact() else { return false }
            // No cursor means the database holds nothing to compact; otherwise stop once the
            // cursor has reached the age cutoff.
            guard let cursor = compactionCursor,
                  cursor < Date.now.addingTimeInterval(-compactionAge)
            else { break }
        }
        do {
            // Rows written before schema 3 get their value column a bounded batch at a time.
            // Until then they are read from their payload, so this is speed, not correctness.
            let filled = try database.backfillValueColumns()
            if filled > 0 { logger.info("Backfilled value columns for \(filled) readings") }
            try database.checkpoint()
            return true
        } catch {
            record(error)
            return false
        }
    }

    @discardableResult
    func deleteAllReadings() -> Bool {
        let originalSources = sources
        let originalBuffer = unavailableBuffer
        let originalBufferedIDs = bufferedIDs
        for index in sources.indices {
            sources[index].observedMetrics.removeAll()
            sources[index].lastSeenAt = nil
        }
        unavailableBuffer.removeAll()
        bufferedIDs.removeAll()
        compactionCursor = nil
        guard loadState == .loaded else {
            sources = originalSources
            unavailableBuffer = originalBuffer
            bufferedIDs = originalBufferedIDs
            return false
        }
        do {
            try database?.deleteAllReadings(sources: sources)
            dataGeneration &+= 1
            removalGeneration &+= 1
            return true
        } catch {
            sources = originalSources
            unavailableBuffer = originalBuffer
            bufferedIDs = originalBufferedIDs
            record(error)
            return false
        }
    }

    /// Stable, machine-readable columns for the whole-history export.
    ///
    /// Documented and append-only, following the same contract as `PairwiseExporter`:
    /// consumers may rely on column order, on values being locale-independent, and on an
    /// empty field meaning *unknown* rather than zero. `unit` and the transport/model
    /// columns come from the export-stable spellings so the bytes do not change with the
    /// device language.
    static let exportColumns = [
        "id",
        "source_id",
        "source_name",
        "source_transport",
        "source_model",
        "source_identifies_healthkit_writer",
        "source_upstream_relationship_id",
        "metric",
        "unit",
        "value",
        "start_utc",
        "end_utc",
        "provenance",
        "aggregation",
        "original_sample_count",
        "original_standard_deviation",
        "corrections_are_final",
        "measurement_quality",
        "observation_duration_seconds",
        "accepted_beat_count",
        "artefact_fraction",
    ]

    /// A complete dump of the stored readings.
    ///
    /// **This is not a backup.** There is no import or restore path, so the file cannot
    /// reconstitute this database; it is an analysis artefact for taking the history
    /// somewhere else. It is also not a record of every measurement ever taken: rows older
    /// than the compaction age are one median per source per comparison window, and the raw
    /// samples behind them are gone. `aggregation` says which kind of row each line is, and
    /// `original_sample_count`/`original_standard_deviation` carry what was retained about
    /// the discarded distribution — empty where a legacy compacted row never recorded it.
    ///
    /// Throws rather than returning a partial file: a header-only CSV produced by a failed
    /// query is indistinguishable from a genuinely empty history, and handing a user an
    /// empty file that claims to be their history is worse than handing them an error.
    func exportCSV() throws -> String {
        let rows = try allReadingsForExport()
        return Self.exportCSV(readings: rows, sources: sources)
    }

    /// Streams the whole-history export into `url` a page at a time.
    ///
    /// Pages rather than materializing the archive plus one complete CSV string in memory:
    /// a month of 1 Hz strap data is millions of rows, and the previous whole-string export
    /// was built during view rendering. Rows are read in the database's total
    /// `ORDER BY end, rowid`, so successive pages do not overlap or skip.
    ///
    /// If any page fails the partial file is deleted and the error is rethrown. A truncated
    /// CSV is indistinguishable from a complete one once it has been shared, so a partial
    /// export must not survive.
    ///
    /// - Parameter sourceID: limits the file to one source's rows, for the export offered
    ///   before that source is removed. Nil exports the whole history.
    /// - Parameter shouldContinue: consulted between pages; returning false cancels the
    ///   export and removes the partial file.
    /// - Returns: the number of data rows written.
    @discardableResult
    func writeExportCSV(
        to url: URL,
        sourceID: String? = nil,
        pageSize: Int = 5_000,
        shouldContinue: (Int) -> Bool = { _ in true }
    ) throws -> Int {
        guard loadState == .loaded || !persistenceEnabled else { throw HealthStoreQueryError.notLoaded }

        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw HealthStoreQueryError.queryFailed("Could not create the export file.")
        }
        let handle = try FileHandle(forWritingTo: url)
        var written = 0

        func abort() { try? handle.close(); try? manager.removeItem(at: url) }

        do {
            try handle.write(contentsOf: Data((Self.exportColumns.joined(separator: ",") + "\r\n").utf8))
            var offset = 0
            while true {
                guard shouldContinue(written) else {
                    abort()
                    throw CancellationError()
                }
                let page = try readingsPageOutcome(sourceID: sourceID, limit: pageSize, offset: offset).get()
                if page.isEmpty { break }
                let chunk = Self.exportRows(readings: page, sources: sources)
                try handle.write(contentsOf: Data(chunk.utf8))
                written += page.count
                offset += page.count
                if page.count < pageSize { break }
            }
            try handle.close()
            return written
        } catch {
            abort()
            throw error
        }
    }

    /// Pure projection so the schema is testable without a database.
    static func exportCSV(readings: [Reading], sources: [DataSource]) -> String {
        exportColumns.joined(separator: ",") + "\r\n" + exportRows(readings: readings, sources: sources)
    }

    /// Data rows only, each terminated by CRLF, so the paged writer and the whole-string
    /// projection cannot drift into two different schemas.
    static func exportRows(readings: [Reading], sources: [DataSource]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [String] = []
        for reading in readings {
            let source = byID[reading.sourceID]
            let aggregation = reading.metadata?.aggregation
            let metadata = reading.metadata

            // Built in named groups rather than one literal: a single 21-element
            // heterogeneous array defeats the type checker on this expression.
            var fields: [String] = []
            fields.append(reading.id.uuidString)
            fields.append(reading.sourceID)
            fields.append(CSV.spreadsheetSafe(source?.displayName ?? ""))
            fields.append(source?.transport.exportTitle ?? "")
            fields.append(CSV.spreadsheetSafe(source?.model ?? ""))
            fields.append(Self.boolean(source?.identifiesHealthKitWriter))
            fields.append(source?.upstreamDeviceRelationshipID ?? "")
            fields.append(reading.kind.rawValue)
            fields.append(reading.kind.exportUnit)
            fields.append(number(reading.value))
            fields.append(formatter.string(from: reading.start))
            fields.append(formatter.string(from: reading.end))
            fields.append(reading.provenance.rawValue)
            fields.append(aggregation == nil ? "raw" : "compacted_window_median")
            fields.append(Self.integer(aggregation?.originalSampleCount))
            fields.append(Self.decimal(aggregation?.originalStandardDeviation))
            fields.append(Self.boolean(aggregation?.correctionsAreFinal))
            fields.append(metadata?.quality?.rawValue ?? "")
            fields.append(Self.decimal(metadata?.observationDuration))
            fields.append(Self.integer(metadata?.acceptedBeatCount))
            fields.append(Self.decimal(metadata?.artefactFraction))

            rows.append(fields.map(CSV.escape).joined(separator: ","))
        }
        return rows.isEmpty ? "" : rows.joined(separator: "\r\n") + "\r\n"
    }

    /// Unknown optionals become an empty field, never a substituted zero or `false`.
    private static func boolean(_ value: Bool?) -> String {
        guard let value else { return "" }
        return value ? "true" : "false"
    }

    private static func integer(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value else { return "" }
        return number(value)
    }

    /// Locale-independent numeric formatting, matching the pairwise export's contract.
    private static func number(_ value: Double) -> String {
        String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Write transactions committed since the database opened; see `HealthDatabase.commitCount`.
    var commitCount: Int { database?.commitCount ?? 0 }

    func injectDatabaseFailureOnNextCommitForTesting() {
        database?.injectFailureOnNextCommitForTesting()
    }

    /// Makes history reads fail until cleared, so the difference between "no rows" and
    /// "the read failed" can be asserted after a successful startup.
    func injectQueryFailureForTesting(_ failing: Bool = true) {
        database?.injectQueryFailureForTesting(failing)
        readers?.injectQueryFailureForTesting(failing)
    }

    // MARK: - Helpers

    private var isReadyToPersist: Bool { !persistenceEnabled || loadState == .loaded }

    /// Writes changed source rows and returns the failure, if any. Nil also when persistence
    /// is not ready yet, which leaves the change in memory only, as ingestion always did.
    private func persistSourcesIfReady(_ changed: [DataSource]) -> String? {
        guard isReadyToPersist else { return nil }
        do {
            try database?.saveSources(changed)
            return nil
        } catch {
            record(error)
            return error.localizedDescription
        }
    }

    private func noteObserved(_ stored: [Reading]) {
        var perSource: [String: (metrics: Set<MetricKind>, latest: Date)] = [:]
        let now = Date.now
        for reading in stored {
            var entry = perSource[reading.sourceID] ?? ([], .distantPast)
            entry.metrics.insert(reading.kind)
            entry.latest = max(entry.latest, min(reading.end, now))
            perSource[reading.sourceID] = entry
        }
        for (sourceID, entry) in perSource {
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { continue }
            // Assigning into `sources` wakes every view that reads it, so touch it only for
            // a change a reader could see: a metric seen for the first time, or a last-seen
            // time that moved by more than the resolution anything displays. A strap that
            // reports every second used to rewrite this array once per reading.
            if !entry.metrics.isSubset(of: sources[index].observedMetrics) {
                sources[index].observedMetrics.formUnion(entry.metrics)
            }
            let known = sources[index].lastSeenAt ?? .distantPast
            if entry.latest.timeIntervalSince(known) >= Self.lastSeenResolution {
                sources[index].lastSeenAt = entry.latest
            }
        }
    }

    private func boundedLastSeen(_ date: Date?, now: Date = .now) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return min(date, now)
    }

    /// How far ahead of this phone's clock a device's timestamp may be and still be kept.
    ///
    /// The same allowance Bluetooth admission already gives
    /// (`BluetoothIngestionPolicy.maximumFutureSkew`). A HealthKit sample written by a watch
    /// whose clock runs a few seconds ahead used to be dropped here while its anchor moved
    /// past it, so it was never imported at all.
    nonisolated static let maximumFutureSkew: TimeInterval = 5 * 60

    private func isTemporallyValid(_ reading: Reading, now: Date) -> Bool {
        let latestAcceptable = now.addingTimeInterval(Self.maximumFutureSkew)
        guard reading.start.timeIntervalSinceReferenceDate.isFinite,
              reading.end.timeIntervalSinceReferenceDate.isFinite,
              reading.start <= reading.end,
              reading.start <= latestAcceptable
        else { return false }
        guard reading.end > latestAcceptable else { return true }
        let aggregate = reading.provenance == .estimated || reading.sourceID == DataSource.ouraSourceID
        return aggregate && reading.end.timeIntervalSince(now) <= 86_400
    }

    private func compactedReadingID(for reading: Reading) -> UUID {
        compactedReadingID(
            sourceID: reading.sourceID,
            kind: reading.kind,
            windowStart: ComparisonEngine.floorToWindow(reading.midpoint, size: reading.kind.comparisonWindow)
        )
    }

    private func compactedReadingID(sourceID: String, kind: MetricKind, windowStart: Date) -> UUID {
        UUID(stableFrom: "compact.\(sourceID).\(kind.rawValue).\(Int(windowStart.timeIntervalSince1970))")
    }

    private func rewindCompactionIfNeeded(for changed: [Reading]) {
        guard let cursor = compactionCursor, let earliest = changed.map(\.end).min(), earliest < cursor else { return }
        compactionCursor = earliest
    }

    private func trimUnavailableArchiveBufferIfNeeded() {
        let excess = unavailableBuffer.count - Self.maximumReadingsWhileArchiveUnavailable
        guard excess > 0 else { return }
        unavailableBuffer.removeFirst(excess)
        bufferedIDs = Set(unavailableBuffer.map(\.id))
    }

    private func deduplicated(_ input: [Reading]) -> [Reading] {
        var byID: [UUID: Reading] = [:]
        for reading in input where reading.isPlausible { byID[reading.id] = reading }
        return byID.values.sorted { $0.end < $1.end }
    }

    private func noteOutcome<T: Sendable>(_ outcome: ReadingArchive.ReadOutcome<T>, collection: String) {
        switch outcome {
        case .unreadable(let reason):
            unavailableCollections.append("\(collection): \(reason)")
        case .corrupt(let reason):
            recoveredCorruptCollections.append("\(collection): \(reason)")
        case .missing, .value:
            break
        }
    }

    private func record(_ error: any Error) {
        lastPersistenceError = error.localizedDescription
        logger.error("Persistence failed: \(error.localizedDescription, privacy: .public)")
    }
}
