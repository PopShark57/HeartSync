import Foundation
import Observation
import OSLog

/// The app's single in-memory record of every reading from every source, plus the list of
/// configured sources.
///
/// Main-actor and `@Observable` so SwiftUI can bind to it directly. Volumes are modest \u{2014}
/// a continuously streaming chest strap produces on the order of tens of thousands of
/// readings per retention window \u{2014} so keeping them in memory and persisting as one
/// atomic JSON file is a reasonable trade for v1. If retention grows past a few weeks of
/// 1 Hz data, this is the seam where SwiftData or SQLite would go: the public API here
/// (`append`, `readings(kind:range:)`, `prune`) is deliberately query-shaped so callers
/// would not change.
@MainActor
@Observable
final class HealthStore {

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Store")

    private(set) var readings: [Reading] = []
    private(set) var sources: [DataSource] = []

    /// How long readings are kept. Older ones are pruned on launch and after each save.
    var retention: TimeInterval = 30 * 86_400

    private var knownReadingIDs: Set<UUID> = []
    private var saveTask: Task<Void, Never>?
    private var isLoaded = false

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
            existing.displayName = source.displayName
            existing.model = source.model ?? existing.model
            existing.lastSeenAt = source.lastSeenAt ?? existing.lastSeenAt
            if let battery = source.batteryPercent { existing.batteryPercent = battery }
            existing.observedMetrics.formUnion(source.observedMetrics)
            sources[index] = existing
            scheduleSave()
            return existing
        }
        var newSource = source
        newSource.colorIndex = nextColorIndex()
        sources.append(newSource)
        scheduleSave()
        return newSource
    }

    func remove(sourceID: String) {
        sources.removeAll { $0.id == sourceID }
        let removed = readings.filter { $0.sourceID == sourceID }
        knownReadingIDs.subtract(removed.map(\.id))
        readings.removeAll { $0.sourceID == sourceID }
        scheduleSave()
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

    func markSeen(sourceID: String, at date: Date = .now) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
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
    /// De-duplication matters more than it sounds: HealthKit anchored queries re-deliver
    /// samples when an anchor is reset, and the Oura API returns overlapping ranges at
    /// page boundaries. Without this, a re-sync would double every value and then the
    /// comparison engine would report the resulting artefacts as real disagreements.
    @discardableResult
    func append(_ reading: Reading) -> Bool {
        guard reading.isPlausible else {
            logger.debug("Rejected implausible \(reading.kind.rawValue, privacy: .public) value \(reading.value)")
            return false
        }
        guard !knownReadingIDs.contains(reading.id) else { return false }

        knownReadingIDs.insert(reading.id)
        // Readings arrive in time order from live sources but out of order from batch
        // pulls, so insert at the right position instead of sorting the whole array.
        let index = readings.lastIndex { $0.end <= reading.end }.map { $0 + 1 } ?? 0
        readings.insert(reading, at: index)

        if let sourceIndex = sources.firstIndex(where: { $0.id == reading.sourceID }) {
            sources[sourceIndex].observedMetrics.insert(reading.kind)
            sources[sourceIndex].lastSeenAt = max(sources[sourceIndex].lastSeenAt ?? .distantPast, reading.end)
        }
        scheduleSave()
        return true
    }

    @discardableResult
    func append(contentsOf newReadings: [Reading]) -> Int {
        var accepted = 0
        for reading in newReadings where append(reading) { accepted += 1 }
        return accepted
    }

    /// Inserts new records and replaces an existing record with the same stable id when a
    /// cloud provider revises it. Live Bluetooth remains append-only; Oura uses this path
    /// because sleep and daily documents can be recalculated after their first publication.
    @discardableResult
    func upsert(contentsOf newReadings: [Reading]) -> Int {
        var changed = 0
        for reading in newReadings {
            guard reading.isPlausible else { continue }
            if let index = readings.firstIndex(where: { $0.id == reading.id }) {
                guard readings[index] != reading else { continue }
                readings.remove(at: index)
                knownReadingIDs.remove(reading.id)
            }
            if append(reading) { changed += 1 }
        }
        return changed
    }

    /// Readings for one metric, optionally clamped to a time range, from enabled sources only.
    func readings(kind: MetricKind, in range: DateInterval? = nil, enabledOnly: Bool = true) -> [Reading] {
        let enabled = Set(enabledSources.map(\.id))
        return readings.filter { reading in
            guard reading.kind == kind else { return false }
            if enabledOnly, !enabled.contains(reading.sourceID) { return false }
            if let range, !range.contains(reading.midpoint) { return false }
            return true
        }
    }

    func readings(in range: DateInterval, enabledOnly: Bool = true) -> [Reading] {
        let enabled = Set(enabledSources.map(\.id))
        return readings.filter { reading in
            if enabledOnly, !enabled.contains(reading.sourceID) { return false }
            return range.contains(reading.midpoint)
        }
    }

    func latest(kind: MetricKind, sourceID: String) -> Reading? {
        readings.last { $0.kind == kind && $0.sourceID == sourceID }
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

    /// Metrics for which two or more enabled sources have data \u{2014} the ones worth comparing.
    func comparableMetrics(in range: DateInterval) -> [MetricKind] {
        MetricKind.allCases.filter { kind in
            let sourceIDs = Set(readings(kind: kind, in: range).map(\.sourceID))
            return sourceIDs.count >= 2
        }
    }

    // MARK: - Persistence

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        let loadedSources = await ReadingArchive.shared.read([DataSource].self, from: ReadingArchive.File.sources) ?? []
        let loadedReadings = await ReadingArchive.shared.read([Reading].self, from: ReadingArchive.File.readings) ?? []

        sources = loadedSources
        readings = loadedReadings.sorted { $0.end < $1.end }
        knownReadingIDs = Set(readings.map(\.id))
        prune()
        logger.info("Loaded \(self.readings.count) readings across \(self.sources.count) sources")
    }

    /// Drops readings past the retention horizon.
    func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-retention)
        guard let firstKept = readings.firstIndex(where: { $0.end >= cutoff }) else {
            if !readings.isEmpty {
                knownReadingIDs.removeAll()
                readings.removeAll()
            }
            return
        }
        guard firstKept > 0 else { return }
        let dropped = readings[..<firstKept]
        knownReadingIDs.subtract(dropped.map(\.id))
        readings.removeFirst(firstKept)
    }

    /// Coalesces saves so a 1 Hz stream does not trigger a file write every second.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await self.saveNow()
        }
    }

    func saveNow() async {
        prune()
        let readingsSnapshot = readings
        let sourcesSnapshot = sources
        await ReadingArchive.shared.write(readingsSnapshot, to: ReadingArchive.File.readings)
        await ReadingArchive.shared.write(sourcesSnapshot, to: ReadingArchive.File.sources)
    }

    /// Removes every stored reading but keeps the configured devices.
    func deleteAllReadings() {
        readings.removeAll()
        knownReadingIDs.removeAll()
        for index in sources.indices { sources[index].observedMetrics.removeAll() }
        scheduleSave()
    }
}
