import Foundation
import SQLite3

/// Transactional, indexed persistence for sources and readings.
///
/// The connection runs `synchronous = FULL` in WAL mode, so every commit is on disk when it
/// returns. `NORMAL` would survive an app crash but can lose the last transactions to a
/// power cut, and HealthKit's anchor and Oura's cache move on the strength of a commit
/// returning: a lost commit there is data that is never fetched again. The fsync is paid
/// per transaction instead, which is why Bluetooth values are batched
/// (`BluetoothIngestBuffer`) rather than committed one at a time.
///
/// The payload columns keep Codable compatibility while the scalar columns provide the
/// stable-id, metric, source, and time indexes used by every query.
///
/// One instance is one SQLite connection and is not thread-safe. `HealthStore` owns the
/// single writer connection on the main actor; history reads use read-only connections from
/// `HealthDatabase.ReaderPool`, one per thread at a time, so a snapshot can read and decode
/// off the main actor while the writer commits. WAL gives each read its own consistent view.
final class HealthDatabase {
    enum WriteMode: Equatable { case append, upsert }

    struct DatabaseError: Error, LocalizedError, CustomStringConvertible {
        var operation: String
        var message: String
        var description: String { "\(operation): \(message)" }
        var errorDescription: String? { description }
    }

    static func defaultURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSync", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("health.sqlite3")
    }

    /// Schema this build writes. Each step in `migrate()` raises `PRAGMA user_version` by
    /// one; a database from a newer build is opened as it is and never lowered.
    ///
    /// - 2: the indexed readings, sources, and metadata tables.
    /// - 3: `value` and `has_metadata` columns, so a reading without metadata is rebuilt
    ///   from its columns instead of decoding its JSON payload. Rows written before 3 have
    ///   NULL there and are decoded from the payload until maintenance backfills them.
    static let schemaVersion = 3

    let wasNew: Bool
    private(set) var requiresLegacyMigration = false
    /// The file every connection opens. A store without persistence gets a private file in
    /// the temporary directory (`isEphemeral`), not `:memory:`, because an in-memory
    /// database cannot be shared with a second connection.
    let fileURL: URL
    let isEphemeral: Bool
    let isReadOnly: Bool
    private var handle: OpaquePointer?
    /// Committed write transactions on this connection since it opened. The device
    /// performance workload reports it as commits per minute (improvement 52).
    private(set) var commitCount = 0
    /// Whether the WAL and shared-memory files have had their protection class set since
    /// this connection opened. They are created by the first write, after `init` has run.
    private var companionFilesProtected = false
    private var failNextCommit = false
    fileprivate(set) var failQueries = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(PayloadDates.encode)
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(PayloadDates.decode)
        return decoder
    }()

    /// Date spelling for stored payloads.
    ///
    /// The `start`, `end`, and `midpoint` columns keep full precision, while the payload
    /// used to be written with `.iso8601`, which drops fractions. Analysis bins the decoded
    /// dates, so a one-second reading from 59.7 s to 60.7 s came back as 59.0 s to 60.0 s and
    /// landed in the previous window, and HRV observation intervals and pair-timing
    /// separations lost their fractions. Millisecond precision is kept now.
    ///
    /// A whole-second date is still written without a fraction, byte for byte as before, so
    /// existing rows and the upsert comparison against them are unaffected, and rows written
    /// by an earlier build decode unchanged.
    enum PayloadDates {
        private static let plain = Date.ISO8601FormatStyle()
        private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        static func string(from date: Date) -> String {
            let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
            // Half a millisecond up: the format style truncates, and a value like
            // 1709649000.731 is stored as ...730999 in binary, which would print as .730.
            let nudged = Date(timeIntervalSince1970: (milliseconds + 0.5) / 1_000)
            let isWholeSecond = milliseconds.truncatingRemainder(dividingBy: 1_000) == 0
            return nudged.formatted(isWholeSecond ? plain : fractional)
        }

        static func date(from string: String) -> Date? {
            if string.contains(".") { return try? fractional.parse(string) }
            return try? plain.parse(string)
        }

        static func encode(_ date: Date, to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }

        static func decode(from decoder: any Decoder) throws -> Date {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(text)"
                )
            }
            return date
        }
    }

    /// Opens (creating if needed) the writer connection.
    ///
    /// - Parameter url: the database file; nil for a throwaway database in the temporary
    ///   directory, removed when this connection is released.
    init(url: URL?) throws {
        let ephemeral = url == nil
        let fileURL = try url ?? Self.ephemeralURL()
        self.fileURL = fileURL
        self.isEphemeral = ephemeral
        self.isReadOnly = false
        wasNew = !FileManager.default.fileExists(atPath: fileURL.path)
        guard sqlite3_open_v2(
            fileURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw error("open database")
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            // A throwaway database has nothing to lose to a power cut.
            try execute(ephemeral ? "PRAGMA synchronous = OFF" : "PRAGMA synchronous = FULL")
            try execute("PRAGMA busy_timeout = 3000")
            try execute("""
                CREATE TABLE IF NOT EXISTS sources (
                    id TEXT PRIMARY KEY NOT NULL,
                    transport TEXT NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS readings (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    start REAL NOT NULL,
                    end REAL NOT NULL,
                    midpoint REAL NOT NULL,
                    provenance TEXT NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS readings_kind_time ON readings(kind, midpoint)")
            try execute("CREATE INDEX IF NOT EXISTS readings_source_time ON readings(source_id, midpoint)")
            try execute("CREATE INDEX IF NOT EXISTS readings_end ON readings(end)")
            try execute("""
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """)
            if wasNew {
                try execute(
                    "INSERT OR IGNORE INTO metadata(key, value) VALUES ('legacy_migration', 'pending')"
                )
            } else if try scalarText("SELECT value FROM metadata WHERE key = 'legacy_migration'") == nil {
                // Compatibility for databases made by an earlier development build of the
                // SQLite migration. A populated existing database must never be replaced by
                // absent legacy JSON merely because it predates the marker.
                try execute(
                    "INSERT INTO metadata(key, value) VALUES ('legacy_migration', 'complete')"
                )
            }
            requiresLegacyMigration = try scalarText(
                "SELECT value FROM metadata WHERE key = 'legacy_migration'"
            ) != "complete"
            try migrate()
            protectFiles()
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    /// Opens a read-only connection to the same file as `writer`, for `ReaderPool`.
    ///
    /// Opened only after the writer has created and migrated the schema. `query_only`
    /// makes any write through it fail rather than take the write lock.
    private init(readerOf writer: HealthDatabase) throws {
        fileURL = writer.fileURL
        isEphemeral = false
        isReadOnly = true
        wasNew = false
        guard sqlite3_open_v2(
            writer.fileURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK else {
            let failure = error("open read connection")
            sqlite3_close(handle)
            handle = nil
            throw failure
        }
        do {
            try execute("PRAGMA busy_timeout = 3000")
            try execute("PRAGMA query_only = ON")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
        if isEphemeral { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    }

    private static func ephemeralURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-ephemeral", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("health.sqlite3")
    }

    /// Raises the schema to `schemaVersion` one step at a time, each step in its own
    /// transaction with its version bump, so an interrupted launch resumes at the step it
    /// stopped on. Only additive steps belong here: the payload stays authoritative, so an
    /// older build can still read every row.
    private func migrate() throws {
        var version = try scalarInt("PRAGMA user_version")
        // 0 is a file created just now or by the first SQLite build, which never set it; both
        // hold exactly the version-2 tables created above.
        if version < 2 {
            try execute("PRAGMA user_version = 2")
            version = 2
        }
        if version < 3 {
            try transaction {
                let columns = try columnNames(of: "readings")
                if !columns.contains("value") { try execute("ALTER TABLE readings ADD COLUMN value REAL") }
                if !columns.contains("has_metadata") { try execute("ALTER TABLE readings ADD COLUMN has_metadata INTEGER") }
                try execute("PRAGMA user_version = 3")
            }
            version = 3
        }
    }

    private func columnNames(of table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    /// Fills `value` and `has_metadata` for up to `limit` rows written before schema 3.
    /// Returns how many rows it filled; zero means none are left.
    ///
    /// Bounded so maintenance can spread a large history over several runs instead of
    /// holding the write lock for all of it at once. A row that is never backfilled is
    /// still read correctly, from its payload.
    @discardableResult
    func backfillValueColumns(limit: Int = 20_000) throws -> Int {
        try transaction {
            try execute(
                """
                UPDATE readings
                SET value = json_extract(CAST(payload AS TEXT), '$.value'),
                    has_metadata = (json_type(CAST(payload AS TEXT), '$.metadata') IS NOT NULL)
                WHERE rowid IN (SELECT rowid FROM readings WHERE value IS NULL LIMIT ?)
                """,
                bindings: [.int(max(1, limit))]
            )
            return Int(sqlite3_changes(handle))
        }
    }

    /// Rows still waiting for `backfillValueColumns`.
    func rowsAwaitingValueBackfill() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM readings WHERE value IS NULL")
    }

    // MARK: - Reader pool

    /// Read-only connections for history reads, handed out one caller at a time.
    ///
    /// A pool rather than one shared reader, so the main actor's small reads never wait
    /// behind a month-long snapshot read on another thread: each caller gets its own
    /// connection, opening one when all are busy. Idle connections are kept up to
    /// `maximumIdle`. `Sendable` because the connections are only reached through `read`,
    /// which never lends one to two callers at once.
    final class ReaderPool: @unchecked Sendable {
        private let writer: HealthDatabase
        private let lock = NSLock()
        private var idle: [HealthDatabase] = []
        private var failQueries = false
        private let maximumIdle = 3

        /// The writer is retained so an ephemeral file outlives every reader using it.
        init(writer: HealthDatabase) {
            self.writer = writer
        }

        /// Closes the idle readers before the writer is released. A throwaway database's
        /// writer deletes its files as it goes, and iOS invalidates the descriptors of any
        /// connection still open on them ("vnode unlinked while in use").
        deinit {
            idle.removeAll()
        }

        func read<T>(_ body: (HealthDatabase) throws -> T) throws -> T {
            let (connection, failing) = try checkOut()
            connection.failQueries = failing
            defer { checkIn(connection) }
            return try body(connection)
        }

        func injectQueryFailureForTesting(_ failing: Bool) {
            lock.withLock { failQueries = failing }
        }

        private func checkOut() throws -> (HealthDatabase, Bool) {
            let pooled: (HealthDatabase?, Bool) = lock.withLock { (idle.popLast(), failQueries) }
            if let connection = pooled.0 { return (connection, pooled.1) }
            return (try HealthDatabase(readerOf: writer), pooled.1)
        }

        private func checkIn(_ connection: HealthDatabase) {
            lock.withLock {
                if idle.count < maximumIdle { idle.append(connection) }
            }
        }
    }

    func allSources() throws -> [DataSource] {
        try decodedRows("SELECT payload FROM sources ORDER BY rowid", as: DataSource.self)
    }

    func allReadings() throws -> [Reading] {
        try readingRows("SELECT \(Self.readingColumns) FROM readings ORDER BY end, rowid")
    }

    func readingCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM readings")
    }

    /// - Parameter sourceIDs: when given, only these sources' rows, filtered in SQL so a
    ///   hidden or paused source's rows are never decoded. An empty set returns nothing.
    func readings(
        kind: MetricKind? = nil,
        range: DateInterval? = nil,
        sourceID: String? = nil,
        sourceIDs: Set<String>? = nil,
        limit: Int? = nil
    ) throws -> [Reading] {
        if let sourceIDs, sourceIDs.isEmpty {
            try checkInjectedQueryFailure("decode rows")
            return []
        }
        var clauses: [String] = []
        var bindings: [Binding] = []
        if let kind {
            clauses.append("kind = ?")
            bindings.append(.text(kind.rawValue))
        }
        if let range {
            clauses.append("midpoint >= ? AND midpoint <= ?")
            bindings.append(.double(range.start.timeIntervalSince1970))
            bindings.append(.double(range.end.timeIntervalSince1970))
        }
        if let sourceID {
            clauses.append("source_id = ?")
            bindings.append(.text(sourceID))
        }
        if let sourceIDs {
            let ordered = sourceIDs.sorted()
            // `+source_id` keeps the planner on the (kind, midpoint) index for a metric read;
            // the source list is a filter on those rows, not a reason to scan by source.
            let column = kind == nil ? "source_id" : "+source_id"
            clauses.append("\(column) IN (\(Array(repeating: "?", count: ordered.count).joined(separator: ", ")))")
            bindings.append(contentsOf: ordered.map { .text($0) })
        }
        var sql = "SELECT \(Self.readingColumns) FROM readings"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY end, rowid"
        if let limit {
            sql += " LIMIT ?"
            bindings.append(.int(max(0, limit)))
        }
        return try readingRows(sql, bindings: bindings)
    }

    /// Every stored row, or one source's, in the total order `(end, rowid)`, handed to `page`
    /// a page at a time until it returns false. `onTotal` first receives how many rows the
    /// pages will hold.
    ///
    /// All of it runs in one read transaction, so every page reads the same committed
    /// snapshot: a prune or a HealthKit deletion that commits mid-export can neither skip nor
    /// repeat a row. Pages are keyset pages: each starts after the last `(end, rowid)` of the
    /// one before, found through the `end` index (which ends in `rowid`), so the thousandth
    /// page costs what the first does. The `LIMIT … OFFSET` pages this replaces re-read every
    /// earlier row for each page, which is quadratic over millions of rows.
    func forEachExportPage(
        sourceID: String?,
        pageSize: Int,
        onTotal: (Int) throws -> Void = { _ in },
        _ page: ([Reading]) throws -> Bool
    ) throws {
        let size = max(1, pageSize)
        try readTransaction {
            if let sourceID {
                try onTotal(count("SELECT COUNT(*) FROM readings WHERE source_id = ?", [.text(sourceID)]))
            } else {
                try onTotal(count("SELECT COUNT(*) FROM readings", []))
            }
            var after: (end: Double, rowid: Int64)?
            while true {
                var clauses: [String] = []
                var bindings: [Binding] = []
                if let sourceID {
                    // `+source_id` keeps the scan on the `end` index; the source index would
                    // have to re-sort the source's remaining rows for every page.
                    clauses.append("+source_id = ?")
                    bindings.append(.text(sourceID))
                }
                if let after {
                    clauses.append("(end, rowid) > (?, ?)")
                    bindings.append(.double(after.end))
                    bindings.append(.int(Int(after.rowid)))
                }
                var sql = "SELECT \(Self.readingColumns), rowid FROM readings"
                if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
                sql += " ORDER BY end, rowid LIMIT ?"
                bindings.append(.int(size))
                var last: (end: Double, rowid: Int64)?
                let rows = try readingRows(sql, bindings: bindings) { statement in
                    last = (sqlite3_column_double(statement, 4), sqlite3_column_int64(statement, 9))
                }
                guard !rows.isEmpty, try page(rows), rows.count == size, let last else { return }
                after = last
            }
        }
    }

    /// Readings that end at or after `end`, of every metric, whose midpoint lies in `range`.
    ///
    /// Answered from the `end` index. The midpoint bounds are written `+midpoint` so SQLite
    /// cannot trade the `end` index for a composite one: filtering by metric here instead
    /// would let it pick `(kind, midpoint)` and scan that metric's whole history to find
    /// the last few minutes.
    func readings(endingAtOrAfter end: Date, midpointIn range: DateInterval) throws -> [Reading] {
        try readingRows(
            "SELECT \(Self.readingColumns) FROM readings WHERE end >= ? AND +midpoint >= ? AND +midpoint <= ? ORDER BY end, rowid",
            bindings: [
                .double(end.timeIntervalSince1970),
                .double(range.start.timeIntervalSince1970),
                .double(range.end.timeIntervalSince1970),
            ]
        )
    }

    /// The newest row of one metric from one source whose midpoint lies in `range`.
    ///
    /// Walks the `(source_id, midpoint)` index backwards from the range's end and stops at the
    /// first row of `kind`, so its cost is this source's own newer rows of other metrics.
    /// `+kind` keeps the planner off the metric index: walking that one would step over every
    /// row another device wrote since, which next to a 1 Hz strap is a day's worth of rows
    /// for a ring last measured yesterday.
    func latest(kind: MetricKind, sourceID: String, midpointIn range: DateInterval) throws -> Reading? {
        try readingRows(
            "SELECT \(Self.readingColumns) FROM readings WHERE source_id = ? AND midpoint >= ? AND midpoint <= ? AND +kind = ? ORDER BY midpoint DESC, rowid DESC LIMIT 1",
            bindings: [
                .text(sourceID),
                .double(range.start.timeIntervalSince1970),
                .double(range.end.timeIntervalSince1970),
                .text(kind.rawValue),
            ]
        ).first
    }

    /// Count, sum, and sum of squares of one metric's stored values by local hour of day,
    /// in one aggregate pass that decodes no rows.
    ///
    /// Only rows with the schema-3 `value` column, provenance other than estimated, and a
    /// duration of at most `maximumDuration` count: an estimate or a night's average is not
    /// what a heart rate at that hour looks like. Rows not yet backfilled are left out rather
    /// than decoded, which only thins an old baseline.
    ///
    /// - Parameter utcOffset: seconds east of UTC, so hour 0 is local midnight.
    func hourOfDayMoments(
        kind: MetricKind,
        range: DateInterval,
        utcOffset: Int,
        maximumDuration: TimeInterval
    ) throws -> [Int: HourMoments] {
        try checkInjectedQueryFailure("summarise hours")
        let statement = try prepare("""
            SELECT ((CAST(midpoint AS INTEGER) + ?) % 86400 + 86400) % 86400 / 3600 AS hour,
                   COUNT(value), SUM(value), SUM(value * value)
            FROM readings
            WHERE kind = ? AND midpoint >= ? AND midpoint <= ?
              AND value IS NOT NULL AND provenance != 'estimated' AND end - start <= ?
            GROUP BY hour
            """)
        defer { sqlite3_finalize(statement) }
        try bind([
            .int(utcOffset),
            .text(kind.rawValue),
            .double(range.start.timeIntervalSince1970),
            .double(range.end.timeIntervalSince1970),
            .double(maximumDuration),
        ], to: statement)
        var result: [Int: HourMoments] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let hour = Int(sqlite3_column_int64(statement, 0))
                result[hour] = HourMoments(
                    count: Int(sqlite3_column_int64(statement, 1)),
                    sum: sqlite3_column_double(statement, 2),
                    sumOfSquares: sqlite3_column_double(statement, 3)
                )
            case SQLITE_DONE:
                return result
            default:
                throw error("summarise hours")
            }
        }
    }

    func latest(kind: MetricKind, sourceID: String) throws -> Reading? {
        try readingRows(
            "SELECT \(Self.readingColumns) FROM readings WHERE kind = ? AND source_id = ? ORDER BY end DESC, rowid DESC LIMIT 1",
            bindings: [.text(kind.rawValue), .text(sourceID)]
        ).first
    }

    /// Stored rows and the earliest observation for one source, answered from the
    /// `(source_id, midpoint)` index without decoding a payload. This is exactly the set
    /// `removeSource(id:)` deletes, so a confirmation can state it before anything happens.
    func sourceHistory(sourceID: String) throws -> (count: Int, earliestMidpoint: Date?) {
        try checkInjectedQueryFailure("read source history")
        let statement = try prepare("SELECT COUNT(*), MIN(midpoint) FROM readings WHERE source_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error("read source history") }
        let count = Int(sqlite3_column_int64(statement, 0))
        guard sqlite3_column_type(statement, 1) != SQLITE_NULL else { return (count, nil) }
        return (count, Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
    }

    func lastDataDate(sourceID: String) throws -> Date? {
        try checkInjectedQueryFailure("read last data date")
        let statement = try prepare("SELECT MAX(end) FROM readings WHERE source_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(sourceID)], to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw error("read last data date")
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// Determines the exact changed subset without mutating. `HealthStore` uses this before
    /// updating source metadata, then commits both together in one transaction.
    ///
    /// One `IN (…)` lookup per few hundred candidates rather than one query per reading:
    /// a Bluetooth batch used to cost a statement per value before its insert.
    func changedReadings(_ candidates: [Reading], mode: WriteMode) throws -> [Reading] {
        guard !candidates.isEmpty else { return [] }
        switch mode {
        case .append:
            let existing = try existingIDs(candidates.map(\.id))
            return candidates.filter { !existing.contains($0.id) }
        case .upsert:
            let stored = try payloads(forReadingIDs: candidates.map(\.id))
            return try candidates.filter { reading in
                guard let payload = stored[reading.id] else { return true }
                return try encoder.encode(reading) != payload
            }
        }
    }

    func contains(readingID: UUID) throws -> Bool {
        try payload(forReadingID: readingID) != nil
    }

    /// Which of `ids` are stored, in batches of `lookupBatchSize`.
    func existingIDs(_ ids: [UUID]) throws -> Set<UUID> {
        var found: Set<UUID> = []
        try forEachIDBatch(ids, columns: "id") { statement in
            if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) {
                found.insert(id)
            }
        }
        return found
    }

    private func payloads(forReadingIDs ids: [UUID]) throws -> [UUID: Data] {
        var found: [UUID: Data] = [:]
        try forEachIDBatch(ids, columns: "id, payload") { statement in
            if let text = sqlite3_column_text(statement, 0),
               let id = UUID(uuidString: String(cString: text)),
               let payload = data(at: 1, statement: statement) {
                found[id] = payload
            }
        }
        return found
    }

    /// Well under SQLite's default limit of 32,766 bound parameters.
    private static let lookupBatchSize = 500

    private func forEachIDBatch(_ ids: [UUID], columns: String, row: (OpaquePointer?) -> Void) throws {
        let unique = Array(Set(ids))
        var start = 0
        while start < unique.count {
            let batch = unique[start..<min(start + Self.lookupBatchSize, unique.count)]
            start += batch.count
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let statement = try prepare("SELECT \(columns) FROM readings WHERE id IN (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            try bind(batch.map { .text($0.uuidString) }, to: statement)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW { row(statement); continue }
                if result == SQLITE_DONE { break }
                throw error("look up readings")
            }
        }
    }

    /// What a delete removed: how many rows, and the latest `end` among them, so a cache
    /// of a recent period can tell whether the removal reached it (`HealthStore.RemovalRecord`).
    struct DeletedRows: Equatable, Sendable {
        var count = 0
        /// Nil when nothing was removed. May be later than any removed row (a bound), never
        /// earlier.
        var latestEnd: Date?

        mutating func add(_ other: DeletedRows) {
            count += other.count
            latestEnd = [latestEnd, other.latestEnd].compactMap { $0 }.max()
        }
    }

    @discardableResult
    func commit(
        readings: [Reading],
        mode: WriteMode,
        sources: [DataSource],
        removingReadingIDs: Set<UUID> = []
    ) throws -> DeletedRows {
        try transaction {
            for source in sources { try write(source) }
            for reading in readings { try write(reading, mode: mode) }
            // Deletions deliberately follow writes. HealthKit can report a sample as both
            // added and deleted between two anchors; the committed generation must end with
            // that sample absent. Oura withdrawal ids never overlap its fetched ids, so the
            // same ordering is correct there too.
            var removed = DeletedRows()
            for id in removingReadingIDs {
                removed.add(try delete("DELETE FROM readings WHERE id = ? RETURNING end", bindings: [.text(id.uuidString)]))
            }
            return removed
        }
    }

    func replaceAll(
        readings: [Reading],
        sources: [DataSource],
        completingLegacyMigration: Bool = false
    ) throws {
        try transaction {
            try execute("DELETE FROM readings")
            try execute("DELETE FROM sources")
            for source in sources { try write(source) }
            for reading in readings { try write(reading, mode: .append) }
            if completingLegacyMigration {
                try execute(
                    "INSERT OR REPLACE INTO metadata(key, value) VALUES ('legacy_migration', 'complete')"
                )
            }
        }
        if completingLegacyMigration { requiresLegacyMigration = false }
    }

    func saveSources(_ sources: [DataSource]) throws {
        try transaction { for source in sources { try write(source) } }
    }

    func removeSource(id: String) throws {
        try transaction {
            try execute("DELETE FROM readings WHERE source_id = ?", bindings: [.text(id)])
            try execute("DELETE FROM sources WHERE id = ?", bindings: [.text(id)])
        }
    }

    @discardableResult
    func removeReadingIDs(_ ids: Set<UUID>) throws -> DeletedRows {
        guard !ids.isEmpty else { return DeletedRows() }
        return try transaction {
            var removed = DeletedRows()
            for id in ids {
                removed.add(try delete("DELETE FROM readings WHERE id = ? RETURNING end", bindings: [.text(id.uuidString)]))
            }
            return removed
        }
    }

    /// Stored estimates of the given kinds, read through the `(kind, midpoint)` index.
    ///
    /// Candidates only: this decodes estimate rows, never the whole table. `sourceID` scopes
    /// the read to the source HeartSync writes its own model output under; `since` bounds it
    /// to rows that end at or after that instant.
    func estimateReadings(kinds: Set<MetricKind>, sourceID: String?, since: Date?) throws -> [Reading] {
        guard !kinds.isEmpty else { return [] }
        let ordered = kinds.map(\.rawValue).sorted()
        var clauses = [
            "kind IN (\(Array(repeating: "?", count: ordered.count).joined(separator: ", ")))",
            "provenance = ?",
        ]
        var bindings: [Binding] = ordered.map { .text($0) }
        bindings.append(.text(Provenance.estimated.rawValue))
        if let sourceID {
            clauses.append("source_id = ?")
            bindings.append(.text(sourceID))
        }
        if let since {
            clauses.append("end >= ?")
            bindings.append(.double(since.timeIntervalSince1970))
        }
        return try readingRows(
            "SELECT \(Self.readingColumns) FROM readings WHERE \(clauses.joined(separator: " AND ")) ORDER BY end, rowid",
            bindings: bindings
        )
    }

    /// Deletes estimates of `kinds` that are no longer current.
    ///
    /// Reads and deletes only estimate rows in the requested scope. The earlier form read the
    /// whole table, twice, and matched on provenance alone, so it also deleted a ring's
    /// blood-pressure readings, which are stored as estimates under the ring's own source.
    /// `sourceID` is the positive identification: the synthetic estimate source for blood
    /// pressure. VO\u{2082} max estimates are written under each device's own source ID, so
    /// they carry `ReadingMetadata.modelledBy` instead; a row with no marker predates it and
    /// is HeartSync's own, since no transport reports an estimated VO\u{2082} max.
    @discardableResult
    func removeEstimates(
        kinds: Set<MetricKind>,
        keeping ids: Set<UUID>,
        currentSince: Date?,
        sourceID: String? = nil
    ) throws -> Int {
        let candidates = try estimateReadings(kinds: kinds, sourceID: sourceID, since: currentSince)
            .filter { reading in
                if ids.contains(reading.id) { return false }
                guard let marker = reading.metadata?.modelledBy else { return true }
                return marker == ReadingMetadata.heartSyncModel
            }
        return try removeReadingIDs(Set(candidates.map(\.id))).count
    }

    /// Deletes every stored reading of one source and leaves the source row itself.
    @discardableResult
    func removeReadings(sourceID: String) throws -> Int {
        try transaction {
            try execute("DELETE FROM readings WHERE source_id = ?", bindings: [.text(sourceID)])
            return Int(sqlite3_changes(handle))
        }
    }

    /// Removes rows that ended before `cutoff` and rows that begin in the future, and
    /// optionally rows whose interval runs backwards, and writes only the source rows the
    /// caller changed.
    ///
    /// Both routine deletes are ranges on the `end` index: a row that starts after `now` also
    /// ends after it, so the future check reads only the newest rows. The `start > end` check
    /// cannot use an index, and joining it to the others with `OR` turned every prune into a
    /// table scan, so callers ask for it once, at load.
    ///
    /// The aged rows report `cutoff` as their latest end rather than returning each row: a
    /// first prune after the retention is shortened can remove millions.
    @discardableResult
    func prune(
        cutoff: Date,
        now: Date,
        changedSources: [DataSource],
        includingInvalidRows: Bool = false
    ) throws -> DeletedRows {
        try transaction {
            try execute("DELETE FROM readings WHERE end < ?", bindings: [.double(cutoff.timeIntervalSince1970)])
            let aged = Int(sqlite3_changes(handle))
            var removed = DeletedRows(count: aged, latestEnd: aged > 0 ? cutoff : nil)
            removed.add(try delete(
                "DELETE FROM readings WHERE end > ? AND start > ? RETURNING end",
                bindings: [.double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970)]
            ))
            if includingInvalidRows {
                removed.add(try delete("DELETE FROM readings WHERE start > end RETURNING end"))
            }
            for source in changedSources { try write(source) }
            return removed
        }
    }

    func replaceReadings(removing ids: Set<UUID>, with replacements: [Reading]) throws {
        try transaction {
            for id in ids {
                try execute("DELETE FROM readings WHERE id = ?", bindings: [.text(id.uuidString)])
            }
            for reading in replacements { try write(reading, mode: .upsert) }
        }
    }

    func deleteAllReadings(sources: [DataSource]) throws {
        try transaction {
            try execute("DELETE FROM readings")
            for source in sources { try write(source) }
        }
    }

    // MARK: - Metadata and counts

    func metadataValue(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(key)], to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw error("read metadata")
        }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    func setMetadata(_ value: String, forKey key: String) throws {
        try transaction {
            try execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
                bindings: [.text(key), .text(value)]
            )
        }
    }

    /// Rows that ended before `date`: what a shorter retention would delete.
    func readingCount(endingBefore date: Date) throws -> Int {
        try count("SELECT COUNT(*) FROM readings WHERE end < ?", [.double(date.timeIntervalSince1970)])
    }

    /// Raw rows that ended in `[start, end)`: what compaction would still fold into window
    /// medians. A compacted row is recognised by the `aggregation` object in its payload, so
    /// the count decodes no rows.
    func rawReadingCount(endingFrom start: Date, before end: Date) throws -> Int {
        try count(
            """
            SELECT COUNT(*) FROM readings WHERE end >= ? AND end < ?
            AND instr(CAST(payload AS TEXT), '"aggregation"') = 0
            """,
            [.double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970)]
        )
    }

    /// Rows of one metric whose midpoint lies in `range`, optionally limited to some
    /// sources, from the `(kind, midpoint)` index, with a fingerprint of their identities.
    ///
    /// The fingerprint sums a stable hash of each ID, so five rows added and five removed
    /// differ from "unchanged" even though the count does not move. No payload is decoded.
    func readingSummary(
        kind: MetricKind,
        sourceIDs: Set<String>?,
        range: DateInterval
    ) throws -> (count: Int, fingerprint: Int64) {
        try checkInjectedQueryFailure("summarise readings")
        let statement = try prepare(
            "SELECT id, source_id FROM readings WHERE kind = ? AND midpoint >= ? AND midpoint <= ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(kind.rawValue),
            .double(range.start.timeIntervalSince1970),
            .double(range.end.timeIntervalSince1970),
        ], to: statement)
        var count = 0
        var fingerprint: Int64 = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let sourceIDs {
                    guard let raw = sqlite3_column_text(statement, 1),
                          sourceIDs.contains(String(cString: raw))
                    else { continue }
                }
                count += 1
                if let raw = sqlite3_column_text(statement, 0) {
                    fingerprint &+= Self.stableHash(String(cString: raw))
                }
            case SQLITE_DONE:
                return (count, fingerprint)
            default:
                throw error("summarise readings")
            }
        }
    }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    private static func stableHash(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    private func count(_ sql: String, _ bindings: [Binding]) throws -> Int {
        try checkInjectedQueryFailure("count readings")
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error("count readings") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
        protectFiles()
    }

    func injectFailureOnNextCommitForTesting() { failNextCommit = true }

    /// Makes every subsequent read throw until cleared, standing in for a corrupt page, a
    /// file-protection denial, or a row that no longer decodes. Reads are what the app does
    /// constantly after startup, and their failure mode used to be indistinguishable from an
    /// empty history, so it needs to be reachable from a test.
    func injectQueryFailureForTesting(_ failing: Bool = true) { failQueries = failing }

    // MARK: - SQL helpers

    private enum Binding {
        case text(String)
        case double(Double)
        case int(Int)
        case blob(Data)
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func write(_ source: DataSource) throws {
        let payload = try encoder.encode(source)
        try execute(
            "INSERT OR REPLACE INTO sources(id, transport, payload) VALUES (?, ?, ?)",
            bindings: [.text(source.id), .text(source.transport.rawValue), .blob(payload)]
        )
    }

    private func write(_ reading: Reading, mode: WriteMode) throws {
        let verb = mode == .append ? "INSERT OR IGNORE" : "INSERT OR REPLACE"
        try execute(
            "\(verb) INTO readings(id, source_id, kind, start, end, midpoint, provenance, payload, value, has_metadata) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(reading.id.uuidString), .text(reading.sourceID), .text(reading.kind.rawValue),
                .double(reading.start.timeIntervalSince1970), .double(reading.end.timeIntervalSince1970),
                .double(reading.midpoint.timeIntervalSince1970), .text(reading.provenance.rawValue),
                .blob(try encoder.encode(reading)),
                .double(reading.value), .int(reading.metadata == nil ? 0 : 1),
            ]
        )
    }

    /// Columns `readingRows` reads, in its order.
    private static let readingColumns =
        "id, source_id, kind, start, end, provenance, value, has_metadata, payload"

    /// Rows selected with `readingColumns`, rebuilt without JSON where the row allows.
    ///
    /// A row with a stored `value`, no metadata, and recognised enum spellings is built from
    /// its columns: that is every plain heart-rate sample, which is almost the whole table.
    /// Anything else decodes its payload exactly as before, so a row this build does not
    /// fully understand fails the same way it always did.
    ///
    /// The column times are the full-precision `Double`s the indexes use; the payload keeps
    /// milliseconds. The two differ below a millisecond, never at a window boundary a
    /// payload date could land on the other side of.
    ///
    /// `eachRow` sees every row's statement, for a caller that selected extra columns after
    /// `readingColumns`.
    private func readingRows(
        _ sql: String,
        bindings: [Binding] = [],
        eachRow: (OpaquePointer?) -> Void = { _ in }
    ) throws -> [Reading] {
        try checkInjectedQueryFailure("decode rows")
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [Reading] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                eachRow(statement)
                if let reading = columnReading(statement) {
                    result.append(reading)
                    continue
                }
                guard let payload = data(at: 8, statement: statement) else {
                    throw DatabaseError(operation: "decode row", message: "missing payload")
                }
                result.append(try decoder.decode(Reading.self, from: payload))
            case SQLITE_DONE:
                return result
            default:
                throw error("step query")
            }
        }
    }

    private func columnReading(_ statement: OpaquePointer?) -> Reading? {
        guard sqlite3_column_type(statement, 6) != SQLITE_NULL,
              sqlite3_column_type(statement, 7) != SQLITE_NULL,
              sqlite3_column_int64(statement, 7) == 0,
              let idText = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idText)),
              let sourceText = sqlite3_column_text(statement, 1),
              let kindText = sqlite3_column_text(statement, 2),
              let kind = MetricKind(rawValue: String(cString: kindText)),
              let provenanceText = sqlite3_column_text(statement, 5),
              let provenance = Provenance(rawValue: String(cString: provenanceText))
        else { return nil }
        return Reading(
            id: id,
            sourceID: String(cString: sourceText),
            kind: kind,
            value: sqlite3_column_double(statement, 6),
            start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            provenance: provenance
        )
    }

    private func payload(forReadingID id: UUID) throws -> Data? {
        let statement = try prepare("SELECT payload FROM readings WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw error("read reading payload")
        }
        return data(at: 0, statement: statement)
    }

    /// Read-path chokepoint for the injected failure. Deliberately not placed in
    /// `prepare(_:)`, which writes share: a test for "reads fail after a healthy startup"
    /// must not also disable the writes whose behaviour it is asserting stays intact.
    private func checkInjectedQueryFailure(_ operation: String) throws {
        guard failQueries else { return }
        throw DatabaseError(operation: operation, message: "injected query failure")
    }

    private func decodedRows<T: Decodable>(
        _ sql: String,
        bindings: [Binding] = [],
        as type: T.Type
    ) throws -> [T] {
        try checkInjectedQueryFailure("decode rows")
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let payload = data(at: 0, statement: statement) else {
                    throw DatabaseError(operation: "decode row", message: "missing payload")
                }
                result.append(try decoder.decode(T.self, from: payload))
            case SQLITE_DONE:
                return result
            default:
                throw error("step query")
            }
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try checkInjectedQueryFailure("read integer scalar")
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error("read integer scalar") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw error("read text scalar")
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func data(at column: Int32, statement: OpaquePointer?) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error("prepare SQL")
        }
        return statement
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .int(let value):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .blob(let value):
                result = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
                }
            }
            guard result == SQLITE_OK else { throw error("bind SQL") }
        }
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        // Several write-capable PRAGMAs (notably journal_mode and wal_checkpoint) return
        // one or more rows before SQLITE_DONE. Drain them instead of treating their first
        // result row as a failed write or relying on sqlite3_stmt_readonly, which correctly
        // reports journal_mode as mutating.
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw error("execute SQL")
            }
        }
    }

    /// Runs `body` in one read transaction, so every statement in it sees the same snapshot.
    /// Unlike `transaction`, it takes no write lock and counts no commit.
    private func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs a `DELETE … RETURNING end` and reports the rows it removed.
    private func delete(_ sql: String, bindings: [Binding] = []) throws -> DeletedRows {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var removed = DeletedRows()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                removed.add(DeletedRows(count: 1, latestEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))))
            case SQLITE_DONE:
                return removed
            default:
                throw error("delete readings")
            }
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            if failNextCommit {
                failNextCommit = false
                throw DatabaseError(operation: "injected transaction", message: "test failure")
            }
            let result = try body()
            try execute("COMMIT")
            commitCount += 1
            // Once per connection, after the first write has created the WAL; after that at
            // open and at each checkpoint. Three `setAttributes` calls per commit added up to
            // tens of thousands of file-system calls over a night of 1 Hz ingest.
            if !companionFilesProtected {
                protectFiles()
                companionFilesProtected = true
            }
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func error(_ operation: String) -> DatabaseError {
        DatabaseError(
            operation: operation,
            message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        )
    }

    private func protectFiles() {
        guard !isEphemeral, !isReadOnly else { return }
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        for url in [fileURL, URL(fileURLWithPath: fileURL.path + "-wal"), URL(fileURLWithPath: fileURL.path + "-shm")] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}
