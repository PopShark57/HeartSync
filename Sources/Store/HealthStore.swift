import Foundation
import Observation
import OSLog

private struct CompactionBucket: Hashable {
    let start: Date
    let sourceID: String
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
    private var unavailableBuffer: [Reading] = []
    private var bufferedIDs: Set<UUID> = []

    var retention: TimeInterval = 30 * 86_400
    static let minimumCompactionAge: TimeInterval = 14 * 86_400
    static let compactionSpanPerPass: TimeInterval = max(
        3 * 86_400,
        MetricKind.allCases.map(\.comparisonWindow).max() ?? 0
    )
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

    private let persistenceEnabled: Bool
    private let archive: ReadingArchive
    private let configuredDatabaseURL: URL?
    private var database: HealthDatabase?
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
            self.needsLegacyMigration = persistenceEnabled && database.requiresLegacyMigration
            self.loadState = persistenceEnabled ? .notLoaded : .loaded
        } catch {
            self.database = nil
            self.needsLegacyMigration = false
            self.loadState = persistenceEnabled ? .failed : .loaded
            self.lastPersistenceError = error.localizedDescription
        }
    }

    /// Compatibility access for tests and explicit whole-history export only. App screens
    /// use indexed range queries; ordinary rendering never materializes the full database.
    var readings: [Reading] {
        _ = dataGeneration
        if persistenceEnabled, loadState != .loaded { return unavailableBuffer }
        return (try? database?.allReadings()) ?? []
    }

    var readingCount: Int {
        _ = dataGeneration
        if persistenceEnabled, loadState != .loaded { return unavailableBuffer.count }
        return (try? database?.readingCount()) ?? 0
    }

    // MARK: - Sources

    func source(id: String) -> DataSource? { sources.first { $0.id == id } }
    func displayName(forSource id: String) -> String { source(id: id)?.displayName ?? "Unknown device" }
    var enabledSources: [DataSource] { sources.filter(\.isEnabled) }

    @discardableResult
    func upsert(_ source: DataSource) -> DataSource {
        let before = sources
        let stored = merge(source)
        guard sources != before else { return stored }
        persistSourcesIfReady([stored])
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
            existing.displayName = source.displayName
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

    @discardableResult
    func remove(sourceID: String) -> Bool {
        let sourceCount = sources.count
        sources.removeAll { $0.id == sourceID }
        let bufferedCount = unavailableBuffer.count
        unavailableBuffer.removeAll { $0.sourceID == sourceID }
        bufferedIDs = Set(unavailableBuffer.map(\.id))
        let existedInDatabase = ((try? database?.readings(sourceID: sourceID, limit: 1)) ?? []).isEmpty == false
        guard sourceCount != sources.count || bufferedCount != unavailableBuffer.count || existedInDatabase else { return false }
        if isReadyToPersist {
            do { try database?.removeSource(id: sourceID) }
            catch { record(error) }
        }
        dataGeneration &+= 1
        return true
    }

    func setEnabled(_ enabled: Bool, forSource id: String) {
        mutateSource(id) { $0.isEnabled = enabled }
    }

    func rename(sourceID: String, to name: String) {
        mutateSource(sourceID) { $0.displayName = name }
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

    private func mutateSource(_ id: String, mutation: (inout DataSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let before = sources[index]
        mutation(&sources[index])
        guard sources[index] != before else { return }
        persistSourcesIfReady([sources[index]])
        dataGeneration &+= 1
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
        valid.removeAll { reading in
            (try? database.contains(readingID: compactedReadingID(for: reading))) == true
                && reading.id != compactedReadingID(for: reading)
        }
        do {
            let changed = try database.changedReadings(valid, mode: mode)
            guard !changed.isEmpty || sourcesChanged || !removingReadingIDs.isEmpty else {
                return BatchCommitResult(acceptedReadings: [], committed: true)
            }
            noteObserved(changed)
            do {
                let removed = try database.commit(
                    readings: changed,
                    mode: mode,
                    sources: sources,
                    removingReadingIDs: removingReadingIDs
                )
                rewindCompactionIfNeeded(for: changed)
                dataGeneration &+= (!changed.isEmpty || sourcesChanged || removed > 0) ? 1 : 0
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
            return removed
        } catch {
            record(error)
            return 0
        }
    }

    @discardableResult
    func reconcileEstimates(
        kinds: Set<MetricKind>,
        keeping validIDs: Set<UUID>,
        currentSince: Date? = nil
    ) -> Int {
        guard isReadyToPersist || !persistenceEnabled else { return 0 }
        do {
            let removed = try database?.removeEstimates(
                kinds: kinds,
                keeping: validIDs,
                currentSince: currentSince
            ) ?? 0
            dataGeneration &+= removed > 0 ? 1 : 0
            return removed
        } catch {
            record(error)
            return 0
        }
    }

    func readings(kind: MetricKind, in range: DateInterval? = nil, enabledOnly: Bool = true) -> [Reading] {
        _ = dataGeneration
        guard loadState == .loaded else { return unavailableBuffer.filter { $0.kind == kind } }
        let enabled = enabledOnly ? Set(enabledSources.map(\.id)) : nil
        let rows = (try? database?.readings(kind: kind, range: range)) ?? []
        return enabled.map { ids in rows.filter { ids.contains($0.sourceID) } } ?? rows
    }

    func readings(in range: DateInterval, enabledOnly: Bool = true) -> [Reading] {
        _ = dataGeneration
        guard loadState == .loaded else { return unavailableBuffer.filter { range.contains($0.midpoint) } }
        let enabled = enabledOnly ? Set(enabledSources.map(\.id)) : nil
        let rows = (try? database?.readings(range: range)) ?? []
        return enabled.map { ids in rows.filter { ids.contains($0.sourceID) } } ?? rows
    }

    func readingsPage(
        kind: MetricKind? = nil,
        in range: DateInterval? = nil,
        limit: Int = 1_000,
        offset: Int = 0
    ) -> [Reading] {
        _ = dataGeneration
        return (try? database?.readings(kind: kind, range: range, limit: limit, offset: offset)) ?? []
    }

    func latest(kind: MetricKind, sourceID: String) -> Reading? {
        _ = dataGeneration
        return try? database?.latest(kind: kind, sourceID: sourceID)
    }

    func lastDataDate(sourceID: String) -> Date? {
        _ = dataGeneration
        return try? database?.lastDataDate(sourceID: sourceID)
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

    func retentionImpact(days: Int, now: Date = .now) -> RetentionImpact {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let all = readings
        return RetentionImpact(
            cutoff: cutoff,
            readingsDeleted: all.count { $0.end < cutoff },
            readingsEligibleForCompaction: all.count {
                $0.end >= cutoff && $0.end < now.addingTimeInterval(-compactionAge)
                    && $0.metadata?.aggregation == nil
            }
        )
    }

    @discardableResult
    func prune(now: Date = .now) -> Bool {
        guard loadState == .loaded, let database else { return false }
        let cutoff = now.addingTimeInterval(-retention)
        let originalSources = sources
        do {
            for index in sources.indices where (sources[index].lastSeenAt ?? .distantPast) > now {
                sources[index].lastSeenAt = now
            }
            let removed = try database.prune(cutoff: cutoff, now: now, sources: sources)
            dataGeneration &+= removed > 0 ? 1 : 0
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
            aged = try database.readings(range: DateInterval(start: .distantPast, end: cutoff))
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
            for reading in group where reading.isPlausible {
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
            prune()
            logger.info("Loaded \(self.readingCount) readings across \(self.sources.count) sources")
        } catch {
            loadState = .failed
            record(error)
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard persistenceEnabled, loadState == .loaded, let database else { return false }
        guard prune(), compact() else { return false }
        do {
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
            return true
        } catch {
            sources = originalSources
            unavailableBuffer = originalBuffer
            bufferedIDs = originalBufferedIDs
            record(error)
            return false
        }
    }

    func exportCSV() -> String {
        var rows = ["id,source_id,metric,value,start_utc,end_utc,provenance,aggregation"]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for reading in readings {
            let aggregation = reading.metadata?.aggregation == nil ? "raw" : "compacted_window_median"
            rows.append([
                reading.id.uuidString, reading.sourceID, reading.kind.rawValue,
                String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), reading.value),
                formatter.string(from: reading.start), formatter.string(from: reading.end),
                reading.provenance.rawValue, aggregation,
            ].map(Self.csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    func injectDatabaseFailureOnNextCommitForTesting() {
        database?.injectFailureOnNextCommitForTesting()
    }

    // MARK: - Helpers

    private var isReadyToPersist: Bool { !persistenceEnabled || loadState == .loaded }

    private func persistSourcesIfReady(_ changed: [DataSource]) {
        guard isReadyToPersist else { return }
        do { try database?.saveSources(changed) }
        catch { record(error) }
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
            sources[index].observedMetrics.formUnion(entry.metrics)
            sources[index].lastSeenAt = max(sources[index].lastSeenAt ?? .distantPast, entry.latest)
        }
    }

    private func boundedLastSeen(_ date: Date?, now: Date = .now) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return min(date, now)
    }

    private func isTemporallyValid(_ reading: Reading, now: Date) -> Bool {
        guard reading.start.timeIntervalSinceReferenceDate.isFinite,
              reading.end.timeIntervalSinceReferenceDate.isFinite,
              reading.start <= reading.end,
              reading.start <= now
        else { return false }
        guard reading.end > now else { return true }
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

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\r") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
