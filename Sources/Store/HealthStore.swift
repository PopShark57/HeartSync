import Foundation
import Observation
import OSLog

/// Identifies one (source, comparison window) cell during compaction.
///
/// File scope rather than nested inside `HealthStore` so it stays outside the store's
/// `@MainActor` isolation: it is a plain value used only as a dictionary key.
private struct CompactionBucket: Hashable {
    let start: Date
    let sourceID: String
}

/// The app's single in-memory record of every reading from every source, plus the list of
/// configured sources.
///
/// Main-actor and `@Observable` so SwiftUI can bind to it directly. `readings` is kept
/// sorted by `end` ascending at all times, and two side indexes are maintained alongside it:
/// one from reading id to position, so identity lookups during de-duplication and upsert are
/// O(1) instead of a linear scan, and one from metric to positions, so `readings(kind:in:)`
/// costs O(matching) instead of O(total). Both are rebuilt wholesale by
/// `rebuildIndexes()` whenever a mutation can shift positions; the only mutation that
/// updates them incrementally is appending past the tail, where nothing moves. That choice
/// is deliberate — a partial index that has to be patched through insert, remove, prune and
/// compact is exactly the kind of thing that silently goes wrong.
///
/// Persistence is one atomic JSON file per collection, coalesced so a 1 Hz stream does not
/// write every second, and `compact(now:)` downsamples ageing history so the file cannot
/// grow without bound. If retention grows past what whole-file JSON can carry, this is the
/// seam where SwiftData or SQLite would go: the public API here (`append`,
/// `readings(kind:in:)`, `prune`, `compact`) is deliberately query-shaped so callers would
/// not change.
@MainActor
@Observable
final class HealthStore {

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Store")

    private(set) var readings: [Reading] = []
    private(set) var sources: [DataSource] = []

    /// How long readings are kept. Older ones are pruned on launch and after each save.
    var retention: TimeInterval = 30 * 86_400

    /// Readings may never be compacted before they are this old.
    ///
    /// Fourteen days is not a round number picked for taste. The Oura sync window is 14 days
    /// and the HealthKit anchored-query window is 30 days, so anything newer than the Oura
    /// window would be re-inserted in raw form by the very next sync, immediately after
    /// compaction replaced it — churn with no storage benefit.
    static let minimumCompactionAge: TimeInterval = 14 * 86_400

    /// How much history one `compact(now:)` pass may work through.
    ///
    /// Bounds the main-actor cost of the first pass over a large existing archive: without
    /// it, a device that has been streaming at 1 Hz for a fortnight would collapse its
    /// entire backlog inside a single save. Compaction resumes from the new oldest reading
    /// on the next save, so the backlog still drains — just in bounded steps.
    ///
    /// The floor is the largest comparison window, and that is an invariant rather than
    /// caution: `compact(now:)` only collapses windows that fit wholly inside the pass, so a
    /// span shorter than one window would let the oldest window fail to fit on every pass
    /// and compaction would stall forever.
    static let compactionSpanPerPass: TimeInterval = max(
        3 * 86_400,
        MetricKind.allCases.map(\.comparisonWindow).max() ?? 0,
    )

    private var compactionAgeStorage: TimeInterval = HealthStore.minimumCompactionAge

    /// How old a reading must be before `compact(now:)` may collapse it. Clamped so it can
    /// never drop below `minimumCompactionAge`.
    var compactionAge: TimeInterval {
        get { compactionAgeStorage }
        set { compactionAgeStorage = max(Self.minimumCompactionAge, newValue) }
    }

    /// Reading id to its position in `readings`. Also serves as the membership set that
    /// makes ingestion idempotent.
    private var idIndex: [UUID: Int] = [:]
    /// Metric to the positions in `readings` holding it, ascending — which, because
    /// `readings` is sorted by `end`, is also time order.
    private var kindIndex: [MetricKind: [Int]] = [:]

    /// Whether the archive has been read successfully yet.
    ///
    /// Tri-state, not a Bool, because "we have not read the archive" and "we tried and
    /// could not" have to be told apart. `HealthStore` is the in-memory *copy* of the
    /// archive, so writing it back is only ever safe once we know what the archive
    /// contained. Persisting from `.notLoaded` or `.failed` would replace the user's entire
    /// history with whatever this session happens to hold.
    enum LoadState: Sendable, Equatable {
        /// No load has completed yet. A load may or may not be in flight.
        case notLoaded
        /// The archive's contents are known — decoded, genuinely absent, or preserved aside
        /// as `.corrupt`. Only in this state may the store be written back.
        case loaded
        /// The archive exists and could not be read. The data is intact on disk; retry.
        case failed
    }

    /// The trailing debounce preserves the low write rate of the original implementation.
    private var saveTask: Task<Void, Never>?
    /// A second, non-resettable deadline prevents a continuous stream from postponing all
    /// maintenance forever. The two tasks are cancelled together by `saveNow()`.
    private var maximumSaveTask: Task<Void, Never>?
    /// In-flight load, so concurrent callers await the same read instead of racing two.
    private var loadTask: Task<Void, Never>?
    /// Exclusive end of the historical span examined by the previous compaction pass.
    ///
    /// A compacted window still occupies its original place in `readings`, so deriving the
    /// next pass from `readings.first` would revisit the same span forever. This in-memory
    /// cursor lets later saves walk forward. Historical ingestion rewinds it through
    /// `rewindCompactionIfNeeded(for:)`, so an anchor reset or cloud correction behind the
    /// cursor is examined again instead of escaping compaction.
    private var compactionCursor: Date?
    private var hasLoggedSaveRefusal = false
    private let persistenceEnabled: Bool

    /// Persistence cadence controls. The maximum is deliberately longer than the debounce so
    /// ordinary bursts still coalesce, but short enough to bound unsaved live readings.
    static let saveDebounce: Duration = .seconds(3)
    static let maximumSaveLatency: Duration = .seconds(30)

    /// Emergency in-memory ceiling while a protected archive cannot be opened. Normal stores
    /// are bounded by retention plus compaction; this smaller, fixed ceiling prevents a locked
    /// or transiently unreadable archive from turning a live transport into an unbounded queue.
    /// Rows beyond the ceiling are the least recent rows and cannot be persisted until the
    /// archive becomes readable, so keeping the newest window is the useful failure behavior.
    static let maximumReadingsWhileArchiveUnavailable = 10_000

    private(set) var loadState: LoadState

    init(persistenceEnabled: Bool = true) {
        self.persistenceEnabled = persistenceEnabled
        // A store with persistence off has no archive to lose and nothing to read, so it is
        // trivially loaded. Unit tests and the `--pairwise-demo` fixtures rely on this:
        // without it every retention/compaction path would refuse to run.
        self.loadState = persistenceEnabled ? .notLoaded : .loaded
    }

    // MARK: - Sources

    func source(id: String) -> DataSource? {
        sources.first { $0.id == id }
    }

    func displayName(forSource id: String) -> String {
        source(id: id)?.displayName ?? "Unknown device"
    }

    var enabledSources: [DataSource] { sources.filter(\.isEnabled) }

    /// Adds a source, or refreshes the display name and model of one already known.
    /// Returns the stored source so callers can read back the assigned colour.
    @discardableResult
    func upsert(_ source: DataSource) -> DataSource {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            var existing = sources[index]
            let now = Date.now
            existing.displayName = source.displayName
            existing.model = source.model ?? existing.model
            existing.lastSeenAt = [existing.lastSeenAt, source.lastSeenAt]
                .compactMap { boundedLastSeen($0, now: now) }
                .max()
            existing.bodyLocation = source.bodyLocation ?? existing.bodyLocation
            if let battery = source.batteryPercent { existing.batteryPercent = battery }
            existing.observedMetrics.formUnion(source.observedMetrics)
            sources[index] = existing
            scheduleSave()
            return existing
        }
        var newSource = source
        newSource.lastSeenAt = boundedLastSeen(source.lastSeenAt)
        newSource.colorIndex = nextColorIndex()
        sources.append(newSource)
        scheduleSave()
        return newSource
    }

    @discardableResult
    func remove(sourceID: String) -> Bool {
        let sourceCount = sources.count
        sources.removeAll { $0.id == sourceID }
        let before = readings.count
        readings.removeAll { $0.sourceID == sourceID }
        if readings.count != before { rebuildIndexes() }
        guard sources.count != sourceCount || readings.count != before else { return false }
        scheduleSave()
        return true
    }

    func setEnabled(_ enabled: Bool, forSource id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        scheduleSave()
    }

    func rename(sourceID: String, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].displayName = name
        scheduleSave()
    }

    func updateBattery(_ percent: Int, forSource id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].batteryPercent = percent
        sources[index].lastSeenAt = .now
        scheduleSave()
    }

    /// Records where on the body a sensor sits, as reported by Body Sensor Location
    /// (0x2A38). Interpreting a discrepancy depends on this: an optical (PPG) ring and an
    /// electrical (ECG) chest strap are not measuring the same signal, so a gap between
    /// them is expected rather than a fault in either device.
    func setBodyLocation(_ location: BodySensorLocation, forSource id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        guard sources[index].bodyLocation != location else { return }
        sources[index].bodyLocation = location
        scheduleSave()
    }

    func markSeen(sourceID: String, at date: Date = .now) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        guard let date = boundedLastSeen(date) else { return }
        sources[index].lastSeenAt = date
    }

    private func nextColorIndex() -> Int {
        let used = Set(sources.map(\.colorIndex))
        for index in 0..<DataSource.palette.count where !used.contains(index) { return index }
        return sources.count % DataSource.palette.count
    }

    // MARK: - Readings

    /// Appends a reading, ignoring implausible values and anything already stored.
    ///
    /// Convenience over the batch path, which owns the actual validation, merge and save
    /// scheduling. Returns whether the reading was stored.
    @discardableResult
    func append(_ reading: Reading) -> Bool {
        !append(contentsOf: [reading]).isEmpty
    }

    /// Appends a batch idempotently and returns exactly the readings that were stored.
    ///
    /// De-duplication matters more than it sounds: HealthKit anchored queries re-deliver
    /// samples when an anchor is reset, and the Oura API returns overlapping ranges at page
    /// boundaries. Without this, a re-sync would double every value and then the comparison
    /// engine would report the resulting artefacts as real disagreements.
    ///
    /// The whole batch is validated and de-duplicated in one pass, merged into the sorted
    /// array with a single linear merge, and followed by exactly one `scheduleSave()`.
    /// Callers get the accepted subset back so that downstream mirroring (HealthKit
    /// write-back) reflects what was actually stored rather than what was offered — writing
    /// the rejected duplicates into the user's health record would silently corrupt it.
    @discardableResult
    func append(contentsOf newReadings: [Reading]) -> [Reading] {
        guard !newReadings.isEmpty else { return [] }

        var accepted: [Reading] = []
        accepted.reserveCapacity(newReadings.count)
        var seen: Set<UUID> = []
        let now = Date.now
        for reading in newReadings {
            guard reading.isPlausible else {
                logger.debug("Rejected implausible \(reading.kind.rawValue, privacy: .public) value \(reading.value)")
                continue
            }
            guard isTemporallyValid(reading, now: now) else {
                logger.debug("Rejected \(reading.kind.rawValue, privacy: .public) reading with invalid dates")
                continue
            }
            guard idIndex[reading.id] == nil, seen.insert(reading.id).inserted else { continue }
            // Compaction is intentionally lossy. Once a window has been reduced to its
            // stable aggregate, a late HealthKit re-delivery cannot be combined back into
            // the original median without the discarded raw distribution. Ignoring that
            // late row preserves the already-established aggregate; accepting it would
            // produce a median-of-a-median on the next pass and silently drift history.
            guard idIndex[compactedReadingID(for: reading)] == nil else { continue }
            accepted.append(reading)
        }
        guard !accepted.isEmpty else { return [] }

        rewindCompactionIfNeeded(for: accepted)
        merge(sortedByEnd(accepted))
        trimUnavailableArchiveBufferIfNeeded()
        noteObserved(accepted)
        scheduleSave()
        return accepted
    }

    /// Inserts new records and replaces an existing record with the same stable id when a
    /// cloud provider revises it. Live Bluetooth remains append-only; Oura uses this path
    /// because sleep and daily documents can be recalculated after their first publication.
    ///
    /// Returns the readings that actually changed the store — new records plus genuine
    /// revisions. A resend of an identical document changes nothing and returns nothing, so
    /// a caller can treat a non-empty result as "there is new data" without re-diffing.
    ///
    /// A revision may move a reading in time, so revised records are lifted out of the array
    /// and merged back in with the insertions rather than overwritten in place.
    @discardableResult
    func upsert(contentsOf newReadings: [Reading]) -> [Reading] {
        guard !newReadings.isEmpty else { return [] }

        // Collapse duplicate ids inside the batch, last write winning, while keeping the
        // batch's own order for determinism.
        var latestByID: [UUID: Reading] = [:]
        var orderedIDs: [UUID] = []
        let now = Date.now
        for reading in newReadings {
            guard reading.isPlausible else {
                logger.debug("Rejected implausible \(reading.kind.rawValue, privacy: .public) value \(reading.value)")
                continue
            }
            guard isTemporallyValid(reading, now: now) else {
                logger.debug("Rejected \(reading.kind.rawValue, privacy: .public) reading with invalid dates")
                continue
            }
            guard idIndex[compactedReadingID(for: reading)] == nil else { continue }
            if latestByID.updateValue(reading, forKey: reading.id) == nil {
                orderedIDs.append(reading.id)
            }
        }
        guard !orderedIDs.isEmpty else { return [] }

        var changed: [Reading] = []
        changed.reserveCapacity(orderedIDs.count)
        var revisedIDs: Set<UUID> = []
        for id in orderedIDs {
            guard let reading = latestByID[id] else { continue }
            if let position = idIndex[id] {
                guard readings[position] != reading else { continue }
                revisedIDs.insert(id)
            }
            changed.append(reading)
        }
        guard !changed.isEmpty else { return [] }

        rewindCompactionIfNeeded(for: changed)
        if !revisedIDs.isEmpty {
            readings.removeAll { revisedIDs.contains($0.id) }
            rebuildIndexes()
        }
        merge(sortedByEnd(changed))
        trimUnavailableArchiveBufferIfNeeded()
        noteObserved(changed)
        scheduleSave()
        return changed
    }

    /// Removes readings by id and reports how many were actually present.
    ///
    /// Exists so an upstream deletion can be honoured — a sample the user deletes in Apple
    /// Health must stop contributing to comparisons here too. `observedMetrics` is
    /// deliberately *not* recomputed: a source that once reported a metric still did, and
    /// re-deriving capability from surviving rows would make the device list flicker as
    /// history ages out.
    @discardableResult
    func remove(readingIDs: some Sequence<UUID>) -> Int {
        let targets = Set(readingIDs)
        guard !targets.isEmpty else { return 0 }
        let before = readings.count
        readings.removeAll { targets.contains($0.id) }
        let removed = before - readings.count
        guard removed > 0 else { return 0 }
        rebuildIndexes()
        scheduleSave()
        return removed
    }

    /// Readings for one metric, optionally clamped to a time range, from enabled sources only.
    ///
    /// Served from `kindIndex`, so the cost is proportional to the readings of that metric
    /// rather than to the whole archive. Results stay in ascending `end` order.
    func readings(kind: MetricKind, in range: DateInterval? = nil, enabledOnly: Bool = true) -> [Reading] {
        guard let positions = kindIndex[kind] else { return [] }
        let enabled: Set<String>? = enabledOnly ? Set(enabledSources.map(\.id)) : nil
        var result: [Reading] = []
        result.reserveCapacity(positions.count)
        for position in positions {
            let reading = readings[position]
            if let enabled, !enabled.contains(reading.sourceID) { continue }
            if let range, !range.contains(reading.midpoint) { continue }
            result.append(reading)
        }
        return result
    }

    func readings(in range: DateInterval, enabledOnly: Bool = true) -> [Reading] {
        let enabled = Set(enabledSources.map(\.id))
        return readings.filter { reading in
            if enabledOnly, !enabled.contains(reading.sourceID) { return false }
            return range.contains(reading.midpoint)
        }
    }

    func latest(kind: MetricKind, sourceID: String) -> Reading? {
        guard let positions = kindIndex[kind] else { return nil }
        for position in positions.reversed() where readings[position].sourceID == sourceID {
            return readings[position]
        }
        return nil
    }

    /// Most recent reading for a source across all metrics, used to show "last data" in
    /// the device list.
    func lastDataDate(sourceID: String) -> Date? {
        readings.last { $0.sourceID == sourceID }?.end
    }

    /// Metrics that at least one enabled source has actually produced.
    var availableMetrics: [MetricKind] {
        let observed = Set(enabledSources.flatMap(\.observedMetrics))
        return MetricKind.allCases.filter { observed.contains($0) }
    }

    /// Metrics for which two or more enabled sources have data — the ones worth comparing.
    func comparableMetrics(in range: DateInterval) -> [MetricKind] {
        MetricKind.allCases.filter { kind in
            let sourceIDs = Set(readings(kind: kind, in: range).map(\.sourceID))
            return sourceIDs.count >= 2
        }
    }

    // MARK: - Ordered storage

    private func boundedLastSeen(_ date: Date?, now: Date = .now) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return min(date, now)
    }

    /// Keeps failed-load buffering finite without applying destructive retention/compaction to a
    /// store whose on-disk contents are not known yet. Once the archive is readable, the normal
    /// retention and compaction rules resume and this path is inactive.
    private func trimUnavailableArchiveBufferIfNeeded() {
        guard persistenceEnabled, loadState == .failed else { return }
        let excess = readings.count - Self.maximumReadingsWhileArchiveUnavailable
        guard excess > 0 else { return }
        readings.removeFirst(excess)
        rebuildIndexes()
        compactionCursor = nil
    }

    /// Stored readings must be finite, ordered intervals whose start is not in the future. BLE
    /// applies a stricter device-clock age/skew policy before this shared boundary; this guard
    /// also protects HealthKit/Oura replays and keeps bad rows out of the archive even if another
    /// transport bypasses its own admission helper. An end after `now` is allowed only for the
    /// app's current-day estimates or Oura's daily interval, whose exclusive end is at most one
    /// day ahead.
    private func isTemporallyValid(_ reading: Reading, now: Date) -> Bool {
        guard reading.start.timeIntervalSinceReferenceDate.isFinite,
              reading.end.timeIntervalSinceReferenceDate.isFinite,
              reading.start <= reading.end,
              reading.start <= now
        else { return false }

        guard reading.end > now else { return true }
        let isCurrentDayAggregate = reading.provenance == .estimated
            || reading.sourceID == DataSource.ouraSourceID
        return isCurrentDayAggregate
            && reading.end.timeIntervalSince(now) <= 86_400
    }

    /// Sorts a batch by `end`, breaking ties by original offset so the result is
    /// deterministic (`Array.sorted` is not a stable sort).
    private func sortedByEnd(_ batch: [Reading]) -> [Reading] {
        batch.enumerated()
            .sorted { lhs, rhs in
                lhs.element.end == rhs.element.end
                    ? lhs.offset < rhs.offset
                    : lhs.element.end < rhs.element.end
            }
            .map(\.element)
    }

    /// Merges an already-sorted, already-validated batch into `readings` in one linear pass.
    ///
    /// Equal `end` values keep existing readings ahead of incoming ones, matching the
    /// insertion order the previous per-reading path produced.
    private func merge(_ incoming: [Reading]) {
        guard !incoming.isEmpty else { return }

        // Fast path: the batch lands entirely past the tail, so no existing position moves
        // and both indexes can be extended in place. This is the live 1 Hz stream.
        if readings.isEmpty || readings[readings.count - 1].end <= incoming[0].end {
            appendPastTail(incoming)
            return
        }

        var merged: [Reading] = []
        merged.reserveCapacity(readings.count + incoming.count)
        var existingIndex = readings.startIndex
        var incomingIndex = incoming.startIndex
        while existingIndex < readings.endIndex, incomingIndex < incoming.endIndex {
            if incoming[incomingIndex].end < readings[existingIndex].end {
                merged.append(incoming[incomingIndex])
                incomingIndex += 1
            } else {
                merged.append(readings[existingIndex])
                existingIndex += 1
            }
        }
        merged.append(contentsOf: readings[existingIndex...])
        merged.append(contentsOf: incoming[incomingIndex...])
        readings = merged
        rebuildIndexes()
    }

    private func appendPastTail(_ incoming: [Reading]) {
        readings.reserveCapacity(readings.count + incoming.count)
        for reading in incoming {
            readings.append(reading)
            let position = readings.count - 1
            idIndex[reading.id] = position
            kindIndex[reading.kind, default: []].append(position)
        }
    }

    /// Recomputes both indexes from scratch. Called after any mutation that can move an
    /// existing reading's position: merge into the middle, removal, prune, compaction, load.
    private func rebuildIndexes() {
        idIndex.removeAll(keepingCapacity: true)
        kindIndex.removeAll(keepingCapacity: true)
        idIndex.reserveCapacity(readings.count)
        for (position, reading) in readings.enumerated() {
            idIndex[reading.id] = position
            kindIndex[reading.kind, default: []].append(position)
        }
    }

    /// Reopens an already-examined historical span when new or revised rows land inside it.
    private func rewindCompactionIfNeeded(for changed: [Reading]) {
        guard let cursor = compactionCursor,
              let earliest = changed.map(\.end).min(),
              earliest < cursor
        else { return }
        compactionCursor = earliest
    }

    /// Stable identity of the compacted cell an ordinary reading belongs to.
    private func compactedReadingID(for reading: Reading) -> UUID {
        let start = ComparisonEngine.floorToWindow(
            reading.midpoint,
            size: reading.kind.comparisonWindow
        )
        return compactedReadingID(
            sourceID: reading.sourceID,
            kind: reading.kind,
            windowStart: start
        )
    }

    private func compactedReadingID(
        sourceID: String,
        kind: MetricKind,
        windowStart: Date
    ) -> UUID {
        UUID(stableFrom: "compact.\(sourceID).\(kind.rawValue).\(Int(windowStart.timeIntervalSince1970))")
    }

    /// Records that these sources produced these metrics, and how recently, in one pass over
    /// the batch rather than one source lookup per reading.
    private func noteObserved(_ stored: [Reading]) {
        guard !stored.isEmpty else { return }
        var perSource: [String: (metrics: Set<MetricKind>, latest: Date)] = [:]
        let now = Date.now
        for reading in stored {
            var entry = perSource[reading.sourceID] ?? (metrics: Set<MetricKind>(), latest: Date.distantPast)
            entry.metrics.insert(reading.kind)
            // A bad device timestamp must not make a source appear to have been seen in the
            // future, even during the short interval before the next maintenance pass prunes it.
            entry.latest = max(entry.latest, min(reading.end, now))
            perSource[reading.sourceID] = entry
        }
        for (sourceID, entry) in perSource {
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { continue }
            sources[index].observedMetrics.formUnion(entry.metrics)
            sources[index].lastSeenAt = max(sources[index].lastSeenAt ?? .distantPast, entry.latest)
        }
    }

    // MARK: - Retention and compaction

    /// Drops readings past the retention horizon and readings whose interval starts in the future.
    func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-retention)
        let before = readings.count
        readings.removeAll { reading in
            !isTemporallyValid(reading, now: now) || reading.end < cutoff
        }
        if readings.count != before { rebuildIndexes() }
        // Archives written by an older build may already contain a future last-seen value. Keep
        // source status on the same side of the time boundary as the rows that remain.
        for index in sources.indices {
            if let lastSeen = sources[index].lastSeenAt, lastSeen > now {
                sources[index].lastSeenAt = now
            }
        }
    }

    /// Downsamples history older than `compactionAge` so a long retention window stays
    /// within what a whole-file JSON archive can carry.
    ///
    /// Every reading older than the cutoff collapses to **one reading per (source, metric,
    /// comparison window)**, valued at the median of that window. The windowing and the
    /// aggregation both come from `ComparisonEngine` — `floorToWindow`, `windows` and
    /// `aggregate` — precisely so compaction and comparison can never drift apart: what is
    /// stored after compaction is what the comparison engine would have computed from the
    /// raw rows anyway.
    ///
    /// The compacted reading spans its window (`start` is the window start, `end` the window
    /// end), keeps its source, and keeps the strongest provenance present in the window
    /// (measured beats derived beats estimated, matching `ComparisonEngine.aggregate`). Its
    /// id is derived with `UUID(stableFrom:)` from source, metric and window start, so
    /// running compaction twice produces the same id and is idempotent.
    ///
    /// A window that already holds exactly one reading is left completely untouched, which
    /// makes this a no-op on sparse data — daily summaries, Oura documents, resting heart
    /// rate — and only bites on a streaming sensor.
    ///
    /// The 14-day floor on `compactionAge` is load-bearing. Oura syncs a rolling 14-day
    /// window and HealthKit's anchored queries request 30 days, so compacting anything
    /// newer than the Oura window would let the very next sync offer the raw rows
    /// compaction just replaced. HealthKit can likewise re-deliver rows between 14 and 30
    /// days old after an anchor reset. Ingestion recognises a cell's stable compacted id and
    /// drops those late rows: the original distribution no longer exists, so folding a new
    /// raw value into its median would create a biased median-of-a-median. This preserves
    /// history honestly at the cost already implied by lossy compaction: a compacted window
    /// is final and cannot incorporate a later correction.
    ///
    /// Lossy by design: raw sample counts and within-window spread for old data are gone
    /// after a pass. What survives is the windowed median every analysis and every export
    /// actually consumes.
    ///
    /// Only windows that lie *entirely* older than the cutoff are collapsed. A window
    /// straddling the cutoff still has rows arriving into it, and collapsing its aged half
    /// now would mean re-collapsing a median-of-medians next pass — the value would drift
    /// on every run instead of converging. Deferring it by one pass costs nothing.
    ///
    /// Each pass is bounded to `compactionSpanPerPass` of history starting at the oldest
    /// reading, so the first pass over a large existing archive cannot stall the main actor
    /// for the length of the whole backlog; subsequent saves walk forward until the backlog
    /// is gone. Within that span the whole aged prefix is re-examined, which is what keeps
    /// re-delivered rows from escaping collapse.
    ///
    /// Runs only once `loadState == .loaded`. Compacting a store that does not yet hold the
    /// archive's contents would be wasted work at best, and at worst would rewrite ids for
    /// windows whose other members are still on disk.
    func compact(now: Date = .now) {
        guard loadState == .loaded else { return }
        guard let oldest = readings.first?.end else { return }
        let ageCutoff = now.addingTimeInterval(-compactionAge)
        let passStart = max(compactionCursor ?? oldest, oldest)
        guard passStart < ageCutoff else { return }
        let cutoff = min(
            ageCutoff,
            passStart.addingTimeInterval(Self.compactionSpanPerPass)
        )
        let boundary = readings.firstIndex { $0.end >= cutoff } ?? readings.count
        // Advance even when this span contains only sparse, already-compacted, or no rows;
        // otherwise a gap before dense history would wedge the cursor just as surely as a
        // compacted first window did.
        compactionCursor = cutoff
        guard boundary > 0 else { return }
        let aged = Array(readings[..<boundary])

        var replacements: [Reading] = []
        var supersededIDs: Set<UUID> = []

        for (kind, group) in Dictionary(grouping: aged, by: \.kind) {
            let size = kind.comparisonWindow
            guard size > 0 else { continue }

            // Membership mirrors ComparisonEngine.windows' own filter exactly, so the rows
            // removed here are precisely the rows that produced the aggregate below.
            var members: [CompactionBucket: [Reading]] = [:]
            for reading in group where reading.isPlausible {
                let start = ComparisonEngine.floorToWindow(reading.midpoint, size: size)
                members[CompactionBucket(start: start, sourceID: reading.sourceID), default: []].append(reading)
            }

            let windows = ComparisonEngine.windows(
                from: group,
                kind: kind,
                windowSize: size,
                includeEstimated: true
            )
            for window in windows {
                // Whole windows only — see the note on drift above.
                guard window.end <= cutoff else { continue }
                for value in window.values {
                    let bucket = CompactionBucket(start: window.start, sourceID: value.sourceID)
                    guard let collapsed = members[bucket], collapsed.count > 1 else { continue }
                    let aggregateID = compactedReadingID(
                        sourceID: value.sourceID,
                        kind: kind,
                        windowStart: window.start
                    )
                    if collapsed.contains(where: { $0.id == aggregateID }) {
                        // A build predating the ingest guard may already have accepted raw
                        // rows after this cell was compacted. Keep the established median
                        // and discard only those late rows; re-aggregating the aggregate as
                        // if it were one raw sample would bias the value.
                        supersededIDs.formUnion(
                            collapsed.lazy.filter { $0.id != aggregateID }.map(\.id)
                        )
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
                        provenance: value.provenance
                    ))
                }
            }
        }

        guard !supersededIDs.isEmpty else { return }
        readings.removeAll { supersededIDs.contains($0.id) }
        rebuildIndexes()
        if !replacements.isEmpty { merge(sortedByEnd(replacements)) }
        logger.info("Compacted \(supersededIDs.count) readings into \(replacements.count)")
    }

    // MARK: - Persistence

    /// Reads the archive into memory, once.
    ///
    /// A failed read leaves `loadState == .failed` instead of latching a "loaded" flag, so a
    /// later call retries. That distinction is the whole point: the failure is transient.
    /// With a file protection class set, a CoreBluetooth state-restoration relaunch before
    /// the device's first unlock cannot open the archive at all, and the previous code
    /// treated that as "no data" — after which the next coalesced save replaced the user's
    /// entire history with an empty store.
    func loadIfNeeded() async {
        guard persistenceEnabled else { return }
        guard loadState != .loaded else { return }

        // Two callers racing would each read the archive, and the slower one would overwrite
        // whatever the faster one had already ingested. Share the in-flight read instead.
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        let sourcesOutcome = await ReadingArchive.shared.readOutcome(
            [DataSource].self,
            from: ReadingArchive.File.sources
        )
        let readingsOutcome = await ReadingArchive.shared.readOutcome(
            [Reading].self,
            from: ReadingArchive.File.readings
        )

        // Both files must be conclusive before the in-memory store may ever be written back.
        // A readable sources.json beside an unreadable readings.json is the dangerous case:
        // adopting it looks exactly like "this user has devices but no history", and saving
        // that is indistinguishable from deleting their history.
        guard sourcesOutcome.isConclusive, readingsOutcome.isConclusive else {
            loadState = .failed
            logger.error("Archive unreadable; refusing to persist until a load succeeds")
            return
        }

        sources = sourcesOutcome.value ?? []
        readings = (readingsOutcome.value ?? []).sorted { $0.end < $1.end }
        rebuildIndexes()
        compactionCursor = nil
        loadState = .loaded
        hasLoggedSaveRefusal = false
        prune()
        logger.info("Loaded \(self.readings.count) readings across \(self.sources.count) sources")
    }

    /// Coalesces saves so a 1 Hz stream does not trigger a file write every second.
    private func scheduleSave() {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.saveNow()
        }

        // Do not reset this task on every append. A live device can therefore keep the useful
        // three-second trailing debounce while still forcing prune/compact/archive work at a
        // finite maximum latency.
        if maximumSaveTask == nil {
            maximumSaveTask = Task { [weak self] in
                try? await Task.sleep(for: Self.maximumSaveLatency)
                guard !Task.isCancelled, let self else { return }
                await self.saveNow()
            }
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        guard persistenceEnabled else { return false }
        saveTask?.cancel()
        saveTask = nil
        maximumSaveTask?.cancel()
        maximumSaveTask = nil
        if loadState == .failed {
            // There is no safe archive to write yet, but the in-memory emergency buffer still
            // needs maintenance so a locked-device or transient I/O failure cannot become a
            // storage DoS while retries are pending. Do not prune/compact an inconclusively
            // loaded store: its missing history may still replace this session's memory later.
            trimUnavailableArchiveBufferIfNeeded()
            return false
        }
        // The guard that turns an unreadable archive into a retry rather than data loss.
        // Writing from `.notLoaded` or `.failed` would replace the archive with whatever
        // this session happens to hold, which after a locked-device launch is nothing.
        guard loadState == .loaded else {
            if !hasLoggedSaveRefusal {
                hasLoggedSaveRefusal = true
                logger.error("Refusing to save: archive load has not completed")
            }
            return false
        }
        prune()
        compact()
        let readingsSnapshot = readings
        let sourcesSnapshot = sources
        let readingsWritten = await ReadingArchive.shared.write(
            readingsSnapshot,
            to: ReadingArchive.File.readings
        )
        let sourcesWritten = await ReadingArchive.shared.write(
            sourcesSnapshot,
            to: ReadingArchive.File.sources
        )
        return readingsWritten && sourcesWritten
    }

    /// Removes every stored reading but keeps the configured devices.
    ///
    /// `lastSeenAt` is cleared alongside `observedMetrics`: a source whose history has just
    /// been wiped has no evidence left for a recent sighting, and leaving the timestamp in
    /// place made the device list claim data the store no longer holds.
    func deleteAllReadings() {
        readings.removeAll()
        idIndex.removeAll()
        kindIndex.removeAll()
        compactionCursor = nil
        for index in sources.indices {
            sources[index].observedMetrics.removeAll()
            sources[index].lastSeenAt = nil
        }
        scheduleSave()
    }
}
