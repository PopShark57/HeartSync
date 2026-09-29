import Foundation
import OSLog

/// What a history screen needs from `HealthStore`, as a value any thread may read.
///
/// `HealthStore` is main-actor state. A snapshot that reads a month of 1 Hz readings and
/// windows them used to do all of it on the main actor, inside the view's `.task`, and hold
/// the interface still while it ran. This carries the source list and generation the store
/// had when it was taken, plus a pool of read-only database connections, so the whole read
/// and analysis can run elsewhere (`HealthHistory.offMain`) and only the finished snapshot
/// is published on the main actor.
///
/// Reads see the database as committed at the moment each read runs, which may be newer
/// than `generation`. That is the same freshness the main-actor reads had; a screen still
/// compares `generation` with the store's to say when it is behind.
struct HealthHistory: Sendable {
    /// Every source, enabled or not, as the store listed them.
    let sources: [DataSource]
    /// `HealthStore.changeToken` when this was taken.
    let changeToken: Int
    /// `HealthStore.removalGeneration` when this was taken.
    let removalGeneration: Int
    /// `HealthStore.recentRemovals` when this was taken.
    let recentRemovals: [HealthStore.RemovalRecord]
    let loadState: HealthStore.LoadState
    private let access: Access

    private enum Access: Sendable {
        case database(HealthDatabase.ReaderPool)
        /// Startup has not finished. `pending` is what the store is holding in memory until
        /// it has somewhere durable to put it; range reads report `.notLoaded`.
        case notLoaded(pending: [Reading])
        case unavailable(String)
    }

    private static let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Store")

    init(
        sources: [DataSource],
        changeToken: Int,
        removalGeneration: Int,
        recentRemovals: [HealthStore.RemovalRecord] = [],
        loadState: HealthStore.LoadState,
        readers: HealthDatabase.ReaderPool?,
        pending: [Reading],
        unavailableDetail: String?
    ) {
        self.sources = sources
        self.changeToken = changeToken
        self.removalGeneration = removalGeneration
        self.recentRemovals = recentRemovals
        self.loadState = loadState
        if loadState != .loaded {
            access = .notLoaded(pending: pending)
        } else if let readers {
            access = .database(readers)
        } else {
            access = .unavailable(unavailableDetail ?? "No database handle is open.")
        }
    }

    /// Runs `work` away from the main actor and returns its result.
    ///
    /// Explicitly detached rather than relying on a `nonisolated async` function's default
    /// executor, which a later language setting could change back to the caller's actor.
    /// The work only computes a value; publishing it stays with the caller.
    static func offMain<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: priority, operation: work).value
    }

    // MARK: - Removals

    /// The latest `end` of any row removed after `generation`, for a cache built at that
    /// generation. Nil when nothing has been removed since; `.distantFuture` when the
    /// removals since are not all on record, so the caller must assume they reached it.
    func latestRemovedEnd(since generation: Int) -> Date? {
        guard generation < removalGeneration else {
            return generation == removalGeneration ? nil : .distantFuture
        }
        // Each advance appends one record, so the log is complete back to its first entry.
        guard let first = recentRemovals.first, first.generation <= generation + 1 else {
            return .distantFuture
        }
        return recentRemovals.filter { $0.generation > generation }.map(\.latestEnd).max() ?? .distantFuture
    }

    // MARK: - Sources

    func source(id: String) -> DataSource? { sources.first { $0.id == id } }
    func displayName(forSource id: String) -> String { source(id: id)?.displayName ?? "Unknown device" }
    var enabledSources: [DataSource] { sources.filter(\.isEnabled) }

    // MARK: - Reads

    /// Runs a read on a pooled connection, converting a throw or a missing handle into a
    /// named failure. Free of side effects, like the store's own reads.
    func query<Value>(_ body: (HealthDatabase) throws -> Value) -> HealthStoreQueryOutcome<Value> {
        switch access {
        case .notLoaded:
            return .failure(.notLoaded)
        case .unavailable(let detail):
            return .failure(.storeUnavailable(detail))
        case .database(let readers):
            do {
                return .success(try readers.read(body))
            } catch {
                Self.logger.error("History query failed: \(error.localizedDescription, privacy: .public)")
                return .failure(.queryFailed(error.localizedDescription))
            }
        }
    }

    private var enabledIDs: Set<String> { Set(enabledSources.map(\.id)) }

    func readingsOutcome(
        kind: MetricKind,
        in range: DateInterval? = nil,
        enabledOnly: Bool = true
    ) -> HealthStoreQueryOutcome<[Reading]> {
        let ids = enabledOnly ? enabledIDs : nil
        return query { try $0.readings(kind: kind, range: range, sourceIDs: ids) }
    }

    func readingsOutcome(in range: DateInterval, enabledOnly: Bool = true) -> HealthStoreQueryOutcome<[Reading]> {
        let ids = enabledOnly ? enabledIDs : nil
        return query { try $0.readings(range: range, sourceIDs: ids) }
    }

    /// Readings of every metric that end at or after `end`, limited to midpoints in `range`.
    /// See `HealthStore.readingsOutcome(endingAtOrAfter:midpointIn:enabledOnly:)`.
    func readingsOutcome(
        endingAtOrAfter end: Date,
        midpointIn range: DateInterval,
        enabledOnly: Bool = true
    ) -> HealthStoreQueryOutcome<[Reading]> {
        let ids = enabledOnly ? enabledIDs : nil
        return query { try $0.readings(endingAtOrAfter: end, midpointIn: range) }
            .map { rows in ids.map { ids in rows.filter { ids.contains($0.sourceID) } } ?? rows }
    }

    /// Rows, or what the store holds in memory before startup finishes. Only for callers
    /// with no way to present a failure.
    func readings(kind: MetricKind, in range: DateInterval? = nil, enabledOnly: Bool = true) -> [Reading] {
        if case .notLoaded(let pending) = access {
            return pending.filter { $0.kind == kind && (range?.contains($0.midpoint) ?? true) }
        }
        return readingsOutcome(kind: kind, in: range, enabledOnly: enabledOnly).valueOrEmpty
    }

    func readings(in range: DateInterval, enabledOnly: Bool = true) -> [Reading] {
        if case .notLoaded(let pending) = access {
            return pending.filter { range.contains($0.midpoint) }
        }
        return readingsOutcome(in: range, enabledOnly: enabledOnly).valueOrEmpty
    }

    func latest(kind: MetricKind, sourceID: String) -> Reading? {
        query { try $0.latest(kind: kind, sourceID: sourceID) }.value ?? nil
    }

    var readingCountOutcome: HealthStoreQueryOutcome<Int> {
        if case .notLoaded(let pending) = access { return .success(pending.count) }
        return query { try $0.readingCount() }
    }

    // MARK: - Export

    /// Streams the whole history, or one source's rows, into `url` as the CSV that
    /// `HealthStore.exportCSV` describes, and returns the number of data rows.
    ///
    /// For running off the main actor (`HealthHistory.offMain`). It holds one pooled read
    /// connection for the whole file and reads it in keyset pages inside one read
    /// transaction (`HealthDatabase.forEachExportPage`), so the file is one consistent
    /// snapshot however long it takes. Source names come from this value's source list.
    ///
    /// On failure, or when `progress` is cancelled (`CancellationError`), the partial file is
    /// deleted: a truncated CSV is indistinguishable from a complete one once shared.
    @discardableResult
    func writeExportCSV(
        to url: URL,
        sourceID: String? = nil,
        pageSize: Int = 5_000,
        progress: ExportProgress? = nil
    ) throws -> Int {
        let readers: HealthDatabase.ReaderPool
        switch access {
        case .notLoaded: throw HealthStoreQueryError.notLoaded
        case .unavailable(let detail): throw HealthStoreQueryError.storeUnavailable(detail)
        case .database(let pool): readers = pool
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw HealthStoreQueryError.queryFailed("Could not create the export file.")
        }
        var written = 0
        var handle: FileHandle?
        do {
            let file = try FileHandle(forWritingTo: url)
            handle = file
            try file.write(contentsOf: Data((HealthStore.exportColumns.joined(separator: ",") + "\r\n").utf8))
            try readers.read { database in
                try database.forEachExportPage(
                    sourceID: sourceID,
                    pageSize: pageSize,
                    onTotal: { progress?.begin(total: $0) }
                ) { page in
                    if progress?.isCancelled == true { throw CancellationError() }
                    try file.write(contentsOf: Data(HealthStore.exportRows(readings: page, sources: sources).utf8))
                    written += page.count
                    progress?.advance(by: page.count)
                    return true
                }
            }
            // A Cancel after the last page still discards the file: the user asked for none.
            if progress?.isCancelled == true { throw CancellationError() }
            handle = nil
            try file.close()
            return written
        } catch {
            try? handle?.close()
            try? manager.removeItem(at: url)
            throw error
        }
    }

    /// See `HealthStore.periodSummaryOutcome`.
    func periodSummaryOutcome(
        interval: DateInterval,
        sourceIDs: Set<String>?,
        kind: MetricKind?
    ) -> HealthStoreQueryOutcome<HealthStore.PeriodReadingSummary> {
        query { database in
            var count = 0
            var fingerprint: Int64 = 0
            for metric in kind.map({ [$0] }) ?? MetricKind.allCases {
                let part = try database.readingSummary(kind: metric, sourceIDs: sourceIDs, range: interval)
                count += part.count
                fingerprint &+= part.fingerprint
            }
            return HealthStore.PeriodReadingSummary(count: count, fingerprint: fingerprint)
        }
    }
}
