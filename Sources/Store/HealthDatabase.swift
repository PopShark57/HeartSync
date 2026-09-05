import Foundation
import SQLite3

/// Transactional, indexed persistence for sources and readings.
///
/// The payload columns keep Codable compatibility while the scalar columns provide the
/// stable-id, metric, source, and time indexes used by every query. All calls are made from
/// `HealthStore` on the main actor; transactions are short and batch-oriented.
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

    let wasNew: Bool
    private(set) var requiresLegacyMigration = false
    private let fileURL: URL?
    private var handle: OpaquePointer?
    private var failNextCommit = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(url: URL?) throws {
        fileURL = url
        wasNew = url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw error("open database")
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
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
            try execute("PRAGMA user_version = 2")
            protectFiles()
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func allSources() throws -> [DataSource] {
        try decodedRows("SELECT payload FROM sources ORDER BY rowid", as: DataSource.self)
    }

    func allReadings() throws -> [Reading] {
        try decodedRows("SELECT payload FROM readings ORDER BY end, rowid", as: Reading.self)
    }

    func readingCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM readings")
    }

    func readings(
        kind: MetricKind? = nil,
        range: DateInterval? = nil,
        sourceID: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Reading] {
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
        var sql = "SELECT payload FROM readings"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY end, rowid"
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            bindings.append(.int(max(0, limit)))
            bindings.append(.int(max(0, offset)))
        }
        return try decodedRows(sql, bindings: bindings, as: Reading.self)
    }

    func latest(kind: MetricKind, sourceID: String) throws -> Reading? {
        try decodedRows(
            "SELECT payload FROM readings WHERE kind = ? AND source_id = ? ORDER BY end DESC, rowid DESC LIMIT 1",
            bindings: [.text(kind.rawValue), .text(sourceID)],
            as: Reading.self
        ).first
    }

    func lastDataDate(sourceID: String) throws -> Date? {
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
    func changedReadings(_ candidates: [Reading], mode: WriteMode) throws -> [Reading] {
        var changed: [Reading] = []
        for reading in candidates {
            let existing = try payload(forReadingID: reading.id)
            switch mode {
            case .append:
                if existing == nil { changed.append(reading) }
            case .upsert:
                let payload = try encoder.encode(reading)
                if existing != payload { changed.append(reading) }
            }
        }
        return changed
    }

    func contains(readingID: UUID) throws -> Bool {
        try payload(forReadingID: readingID) != nil
    }

    @discardableResult
    func commit(
        readings: [Reading],
        mode: WriteMode,
        sources: [DataSource],
        removingReadingIDs: Set<UUID> = []
    ) throws -> Int {
        try transaction {
            for source in sources { try write(source) }
            for reading in readings { try write(reading, mode: mode) }
            // Deletions deliberately follow writes. HealthKit can report a sample as both
            // added and deleted between two anchors; the committed generation must end with
            // that sample absent. Oura withdrawal ids never overlap its fetched ids, so the
            // same ordering is correct there too.
            var removed = 0
            for id in removingReadingIDs {
                try execute("DELETE FROM readings WHERE id = ?", bindings: [.text(id.uuidString)])
                removed += Int(sqlite3_changes(handle))
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
    func removeReadingIDs(_ ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try transaction {
            var count = 0
            for id in ids {
                try execute("DELETE FROM readings WHERE id = ?", bindings: [.text(id.uuidString)])
                count += Int(sqlite3_changes(handle))
            }
            return count
        }
    }

    @discardableResult
    func removeEstimates(
        kinds: Set<MetricKind>,
        keeping ids: Set<UUID>,
        currentSince: Date?
    ) throws -> Int {
        let candidates = try readings().filter { reading in
            guard reading.provenance == .estimated, kinds.contains(reading.kind) else { return false }
            if let currentSince, reading.end < currentSince { return false }
            return !ids.contains(reading.id)
        }
        return try removeReadingIDs(Set(candidates.map(\.id)))
    }

    @discardableResult
    func prune(cutoff: Date, now: Date, sources: [DataSource]) throws -> Int {
        try transaction {
            let sql = "DELETE FROM readings WHERE end < ? OR start > end OR start > ?"
            try execute(sql, bindings: [
                .double(cutoff.timeIntervalSince1970),
                .double(now.timeIntervalSince1970),
            ])
            let removed = Int(sqlite3_changes(handle))
            for source in sources { try write(source) }
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

    func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
        protectFiles()
    }

    func injectFailureOnNextCommitForTesting() { failNextCommit = true }

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
            "\(verb) INTO readings(id, source_id, kind, start, end, midpoint, provenance, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(reading.id.uuidString), .text(reading.sourceID), .text(reading.kind.rawValue),
                .double(reading.start.timeIntervalSince1970), .double(reading.end.timeIntervalSince1970),
                .double(reading.midpoint.timeIntervalSince1970), .text(reading.provenance.rawValue),
                .blob(try encoder.encode(reading)),
            ]
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

    private func decodedRows<T: Decodable>(
        _ sql: String,
        bindings: [Binding] = [],
        as type: T.Type
    ) throws -> [T] {
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

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            if failNextCommit {
                failNextCommit = false
                throw DatabaseError(operation: "injected transaction", message: "test failure")
            }
            let result = try body()
            try execute("COMMIT")
            protectFiles()
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
        guard let fileURL else { return }
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        for url in [fileURL, URL(fileURLWithPath: fileURL.path + "-wal"), URL(fileURLWithPath: fileURL.path + "-shm")] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}
