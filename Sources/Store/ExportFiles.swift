import Foundation

/// A running export's progress and its Cancel, shared between the thread writing the file
/// and the screen showing it. The writer checks `isCancelled` between pages.
///
/// Locked rather than actor-isolated because the writer is synchronous: it runs on a pooled
/// database connection off the main actor and cannot await between pages.
final class ExportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var rowsWritten = 0
    private var rowsTotal: Int?

    var isCancelled: Bool { lock.withLock { cancelled } }
    /// Data rows written so far.
    var written: Int { lock.withLock { rowsWritten } }
    /// Rows in the snapshot being exported; nil until the writer has counted them.
    var total: Int? { lock.withLock { rowsTotal } }

    func cancel() { lock.withLock { cancelled = true } }

    func begin(total: Int) { lock.withLock { rowsTotal = total } }

    func advance(by rows: Int) { lock.withLock { rowsWritten += rows } }
}

/// Temporary directories that hold an export while the share sheet is open.
///
/// Each export gets its own directory, removed when the sheet is dismissed. A crash or a kill
/// while sharing skips that, and the directory is health data left in `tmp`, so launch sweeps
/// what an earlier process left (`sweep`).
enum ExportDirectory {
    /// Whole-history and per-source reading exports.
    static let readingsPrefix = "HeartSync-Export-"
    /// The pairwise observations and summary.
    static let pairwisePrefix = "HeartSync-Pairwise-"
    /// Only these are swept. `HeartSync-ephemeral` holds a live throwaway database and is not
    /// an export.
    static let prefixes = [readingsPrefix, pairwisePrefix]

    static func make(prefix: String, in base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// Writes `files` into a fresh export directory. On any failure the directory is removed
    /// and the error rethrown, so nothing partial is left to share.
    static func write(
        _ files: [(name: String, data: Data)],
        prefix: String,
        in base: URL = FileManager.default.temporaryDirectory
    ) throws -> (directory: URL, urls: [URL]) {
        let directory = try make(prefix: prefix, in: base)
        do {
            var urls: [URL] = []
            for file in files {
                let url = directory.appendingPathComponent(file.name)
                try file.data.write(to: url, options: .atomic)
                urls.append(url)
            }
            return (directory, urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Removes export directories created before `cutoff`, and returns how many it removed.
    ///
    /// Launch passes its own start time, so an export this process begins while the sweep is
    /// still running is never removed from under its share sheet.
    @discardableResult
    static func sweep(in base: URL = FileManager.default.temporaryDirectory, createdBefore cutoff: Date) -> Int {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        guard let entries = try? manager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else { return 0 }
        var removed = 0
        for entry in entries where prefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let created = values.creationDate, created < cutoff
            else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

/// A prepared readings export waiting for the share sheet, plus the temporary directory that
/// holds it so the directory can be removed once the sheet is dismissed.
struct ReadingsExportPayload: Identifiable, Sendable {
    let id = UUID()
    var url: URL
    var directory: URL

    /// Writes the CSV for one source (or the whole history when `sourceID` is nil) into a
    /// fresh temporary directory. Throws, and leaves nothing behind, on failure or Cancel
    /// (`CancellationError`); returns nil when there are no rows, because an empty file must
    /// not look like an exported history.
    ///
    /// Synchronous and free of the main actor: run it with `HealthHistory.offMain`.
    static func prepare(
        history: HealthHistory,
        sourceID: String?,
        filename: String,
        progress: ExportProgress? = nil,
        in base: URL = FileManager.default.temporaryDirectory
    ) throws -> ReadingsExportPayload? {
        let directory = try ExportDirectory.make(prefix: ExportDirectory.readingsPrefix, in: base)
        let url = directory.appendingPathComponent(filename)
        do {
            let rows = try history.writeExportCSV(to: url, sourceID: sourceID, progress: progress)
            guard rows > 0 else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return ReadingsExportPayload(url: url, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
