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
        loadState: HealthStore.LoadState,
        readers: HealthDatabase.ReaderPool?,
        pending: [Reading],
        unavailableDetail: String?
    ) {
        self.sources = sources
        self.changeToken = changeToken
        self.removalGeneration = removalGeneration
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
