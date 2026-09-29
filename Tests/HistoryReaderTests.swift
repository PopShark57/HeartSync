import Foundation
import SQLite3
import Testing
@testable import HeartSyncChecker

/// History read off the main actor (improvement 50): the pooled read connections, the
/// schema-3 value columns and their migration, and SQL source filters.

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// An hour of two sources, whole-second timestamps, one with metadata.
private func fixture(now: Date) -> [Reading] {
    var readings: [Reading] = []
    for minute in 0..<60 {
        let at = now.addingTimeInterval(-Double(minute) * 60 - 30)
        readings.append(Reading(sourceID: "strap", kind: .heartRate, value: 60 + Double(minute % 7), start: at))
        readings.append(Reading(sourceID: "ring", kind: .heartRate, value: 62 + Double(minute % 5), start: at.addingTimeInterval(4)))
    }
    readings.append(Reading(
        sourceID: "strap", kind: .hrvRMSSD, value: 41, start: now.addingTimeInterval(-900), end: now.addingTimeInterval(-600),
        provenance: .derived, metadata: ReadingMetadata(quality: .accepted, observationDuration: 300, acceptedBeatCount: 280, artefactFraction: 0.02)
    ))
    return readings
}

@Suite("History reads off the main actor")
@MainActor
struct HistoryReaderTests {

    private func populatedStore(now: Date) -> HealthStore {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
        store.append(contentsOf: fixture(now: now))
        return store
    }

    @Test("A snapshot built off the main actor equals one built in place")
    func offMainSnapshotMatches() async {
        let now = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let store = populatedStore(now: now)
        let period = ComparisonPeriod.fixed(DateInterval(start: now.addingTimeInterval(-3_600), end: now))
        let inPlace = MetricDetailSnapshot(store: store, kind: .heartRate, period: period, includeEstimates: false, hrvQuality: [:])
        let history = store.history
        let offMain = await HealthHistory.offMain {
            MetricDetailSnapshot(history: history, kind: .heartRate, period: period, includeEstimates: false, hrvQuality: [:])
        }
        #expect(offMain.pairwiseAnalyses == inPlace.pairwiseAnalyses)
        #expect(offMain.points.map(\.value) == inPlace.points.map(\.value))
        #expect(offMain.series.map(\.sourceID) == inPlace.series.map(\.sourceID))
        #expect(offMain.generation == store.changeToken)
        #expect(offMain.pairwiseAnalyses.first?.pairedWindowCount == 60)
    }

    @Test("A read sees what the writer has just committed")
    func readerSeesCommits() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        let history = store.history
        #expect(history.readings(kind: .heartRate, enabledOnly: false).isEmpty)
        store.append(Reading(sourceID: "strap", kind: .heartRate, value: 60, start: .now.addingTimeInterval(-10)))
        #expect(history.readings(kind: .heartRate, enabledOnly: false).count == 1)
    }

    @Test("Rows without metadata come back from their columns exactly; rows with it from the payload")
    func columnAndPayloadPaths() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
        let written = fixture(now: now)
        store.append(contentsOf: written)
        let read = store.readings(in: DateInterval(start: now.addingTimeInterval(-7_200), end: now), enabledOnly: false)
        #expect(Set(read) == Set(written))
    }

    @Test("Source filters run in the query: a paused source's rows are not returned")
    func sourceFilterInSQL() {
        let now = Date.now
        let store = populatedStore(now: now)
        store.setEnabled(false, forSource: "ring")
        let range = DateInterval(start: now.addingTimeInterval(-7_200), end: now)
        #expect(Set(store.readings(kind: .heartRate, in: range).map(\.sourceID)) == ["strap"])
        #expect(Set(store.history.readings(kind: .heartRate, in: range).map(\.sourceID)) == ["strap"])
        #expect(Set(store.readings(kind: .heartRate, in: range, enabledOnly: false).map(\.sourceID)) == ["strap", "ring"])
        store.setEnabled(false, forSource: "strap")
        #expect(store.readings(kind: .heartRate, in: range).isEmpty)
    }

    @Test("An injected read failure reaches a snapshot built from the history")
    func failureReachesHistory() async {
        let store = populatedStore(now: .now)
        store.injectQueryFailureForTesting()
        let history = store.history
        let snapshot = await HealthHistory.offMain {
            MetricDetailSnapshot(history: history, kind: .heartRate, period: .rolling(.day), includeEstimates: false, hrvQuality: [:])
        }
        #expect(snapshot.queryFailure != nil)
        store.injectQueryFailureForTesting(false)
    }

    @Test("A history taken before loading reports not loaded, never empty")
    func notLoadedHistory() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: folder.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: folder)
        )
        #expect(store.history.readingsOutcome(kind: .heartRate).error == .notLoaded)
    }

    @Test("A store without persistence keeps its database in a temporary directory it removes")
    func ephemeralFileIsRemoved() throws {
        var directory: URL?
        do {
            let database = try HealthDatabase(url: nil)
            #expect(database.isEphemeral)
            directory = database.fileURL.deletingLastPathComponent()
            #expect(FileManager.default.fileExists(atPath: database.fileURL.path))
        }
        let removed = try #require(directory)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
    }
}

@Suite("Schema 3 migration")
struct SchemaMigrationTests {

    /// Writes a database exactly as schema 2 left it: no value columns.
    private func writeVersion2Database(at url: URL, readings: [Reading]) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = [
            "PRAGMA journal_mode = WAL",
            "CREATE TABLE sources (id TEXT PRIMARY KEY NOT NULL, transport TEXT NOT NULL, payload BLOB NOT NULL)",
            "CREATE TABLE readings (id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, midpoint REAL NOT NULL, provenance TEXT NOT NULL, payload BLOB NOT NULL)",
            "CREATE INDEX readings_kind_time ON readings(kind, midpoint)",
            "CREATE INDEX readings_source_time ON readings(source_id, midpoint)",
            "CREATE INDEX readings_end ON readings(end)",
            "CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)",
            "INSERT INTO metadata(key, value) VALUES ('legacy_migration', 'complete')",
            "PRAGMA user_version = 2",
        ]
        for sql in schema { #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for reading in readings {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, "INSERT INTO readings VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil)
            let payload = try encoder.encode(reading)
            sqlite3_bind_text(statement, 1, reading.id.uuidString, -1, transient)
            sqlite3_bind_text(statement, 2, reading.sourceID, -1, transient)
            sqlite3_bind_text(statement, 3, reading.kind.rawValue, -1, transient)
            sqlite3_bind_double(statement, 4, reading.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, reading.end.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, reading.midpoint.timeIntervalSince1970)
            sqlite3_bind_text(statement, 7, reading.provenance.rawValue, -1, transient)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 8, $0.baseAddress, Int32($0.count), transient) }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }

    private func userVersion(at url: URL) -> Int32 {
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
        return sqlite3_column_int(statement, 0)
    }

    @MainActor
    @Test("A schema-2 database gains the value columns, reads unchanged, and backfills in batches")
    func migratesAndBackfills() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("health.sqlite3")
        let now = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970).rounded(.down))
        let written = fixture(now: now)
        try writeVersion2Database(at: url, readings: written)

        let database = try HealthDatabase(url: url)
        #expect(userVersion(at: url) == 3)
        #expect(try database.rowsAwaitingValueBackfill() == written.count)
        // Before the backfill every row is decoded from its payload, as it always was.
        #expect(Set(try database.allReadings()) == Set(written))

        #expect(try database.backfillValueColumns(limit: 50) == 50)
        #expect(try database.rowsAwaitingValueBackfill() == written.count - 50)
        _ = try database.backfillValueColumns()
        #expect(try database.rowsAwaitingValueBackfill() == 0)
        // After it, plain rows come from their columns, and nothing changes.
        #expect(Set(try database.allReadings()) == Set(written))
        #expect(try database.backfillValueColumns() == 0)
    }

    @Test("A new database is created at the current schema")
    func newDatabaseIsCurrent() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("health.sqlite3")
        _ = try HealthDatabase(url: url)
        #expect(userVersion(at: url) == Int32(HealthDatabase.schemaVersion))
    }
}
