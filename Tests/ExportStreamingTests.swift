import Foundation
import Testing
@testable import HeartSyncChecker

/// Exports written off the main actor in keyset pages, with progress, Cancel, and the
/// launch sweep of export files a crash left behind (improvement 59).
@Suite("Export streaming")
@MainActor
struct ExportStreamingTests {
    private let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-86_400), size: 60)

    private func makeStore(rows: Int, sameEnd: Bool = false) -> HealthStore {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "strap", displayName: "Chest Strap", transport: .bluetooth))
        store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
        for index in 0..<rows {
            let start = anchor.addingTimeInterval(sameEnd ? 0 : Double(index) * 60)
            #expect(store.append(Reading(sourceID: index.isMultiple(of: 3) ? "ring" : "strap", kind: .heartRate, value: 60 + Double(index % 40), start: start)))
        }
        return store
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-streaming-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func dataLines(_ url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        return Array(lines.dropFirst())
    }

    @Test("Keyset pages return every row once, in order, even when many rows share an end")
    func keysetPagesAreComplete() throws {
        for sameEnd in [false, true] {
            let store = makeStore(rows: 23, sameEnd: sameEnd)
            let expected = try #require(try? store.allReadingsForExport()).map(\.id)
            var paged: [UUID] = []
            var total: Int?
            _ = try store.history.query { database in
                try database.forEachExportPage(sourceID: nil, pageSize: 4, onTotal: { total = $0 }) { page in
                    paged += page.map(\.id)
                    return true
                }
            }.get()
            #expect(total == 23)
            #expect(paged == expected)

            var ringOnly: [Reading] = []
            _ = try store.history.query { database in
                try database.forEachExportPage(sourceID: "ring", pageSize: 3) { page in
                    ringOnly += page
                    return true
                }
            }.get()
            #expect(ringOnly.count == 8)
            #expect(ringOnly.allSatisfy { $0.sourceID == "ring" })
            #expect(ringOnly.map(\.id) == expected.filter { id in ringOnly.contains { $0.id == id } })
        }
    }

    @Test("A deletion committed mid-export neither skips nor repeats a row")
    func exportReadsOneSnapshot() throws {
        let store = makeStore(rows: 12)
        let before = try store.allReadingsForExport()
        var paged: [UUID] = []
        var deleted = false
        _ = try store.history.query { database in
            try database.forEachExportPage(sourceID: nil, pageSize: 5) { page in
                paged += page.map(\.id)
                if !deleted {
                    // The writer commits while the export's read transaction is open.
                    deleted = true
                    #expect(store.remove(readingIDs: before.prefix(7).map(\.id)) == 7)
                }
                return true
            }
        }.get()
        #expect(paged == before.map(\.id))
        #expect(try store.allReadingsForExport().count == 5)
    }

    @Test("The off-main writer reports progress and matches the whole-string export")
    func writerMatchesProjection() throws {
        let store = makeStore(rows: 11)
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let progress = ExportProgress()
        let payload = try #require(try ReadingsExportPayload.prepare(
            history: store.history,
            sourceID: nil,
            filename: "all.csv",
            progress: progress,
            in: base
        ))
        #expect(payload.directory.lastPathComponent.hasPrefix(ExportDirectory.readingsPrefix))
        #expect(progress.total == 11)
        #expect(progress.written == 11)
        let whole = try store.exportCSV()
        #expect(try String(contentsOf: payload.url, encoding: .utf8) == whole)
    }

    @Test("Cancel removes the partial file and its directory")
    func cancelLeavesNothing() throws {
        let store = makeStore(rows: 9)
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let progress = ExportProgress()
        progress.cancel()
        #expect(throws: CancellationError.self) {
            _ = try ReadingsExportPayload.prepare(history: store.history, sourceID: nil, filename: "all.csv", progress: progress, in: base)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)

        // No rows: no file, and no directory either.
        let empty = HealthStore(persistenceEnabled: false)
        #expect(try ReadingsExportPayload.prepare(history: empty.history, sourceID: nil, filename: "none.csv", in: base) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("Before startup finishes the export fails rather than writing an empty history")
    func notLoadedFails() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HealthStore(databaseURL: base.appendingPathComponent("health.sqlite3"))
        #expect(throws: HealthStoreQueryError.self) {
            _ = try ReadingsExportPayload.prepare(history: store.history, sourceID: nil, filename: "all.csv", in: base)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).allSatisfy { !$0.hasPrefix(ExportDirectory.readingsPrefix) })
    }

    @Test("The job reports the payload; a cancelled job reports nothing and leaves no file")
    func jobCompletesAndCancels() async throws {
        let store = makeStore(rows: 7)
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let job = ReadingsExportJob()

        let result = await withCheckedContinuation { continuation in
            job.start(history: store.history, sourceID: "strap", filename: "strap.csv", in: base) {
                continuation.resume(returning: $0)
            }
        }
        let payload = try #require(try result.get())
        #expect(!job.isRunning)
        #expect(job.written == 4)
        #expect(job.total == 4)
        #expect(try dataLines(payload.url).count == 4)
        try FileManager.default.removeItem(at: payload.directory)

        var reported = false
        job.start(history: store.history, sourceID: nil, filename: "all.csv", in: base) { _ in reported = true }
        #expect(job.isRunning)
        job.cancel()
        #expect(!job.isRunning)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!reported)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("The launch sweep removes only export directories from before launch")
    func sweepRemovesOnlyStaleExports() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        let stale = try ExportDirectory.make(prefix: ExportDirectory.readingsPrefix, in: base)
        try Data("id\r\n".utf8).write(to: stale.appendingPathComponent("HeartSync-readings.csv"))
        let stalePair = try ExportDirectory.make(prefix: ExportDirectory.pairwisePrefix, in: base)
        let ephemeral = base.appendingPathComponent("HeartSync-ephemeral", isDirectory: true)
        try manager.createDirectory(at: ephemeral, withIntermediateDirectories: false)
        let strayFile = base.appendingPathComponent(ExportDirectory.readingsPrefix + "file.csv")
        try Data().write(to: strayFile)
        let hourAgo = Date.now.addingTimeInterval(-3_600)
        for url in [stale, stalePair, ephemeral, strayFile] {
            try manager.setAttributes([.creationDate: hourAgo], ofItemAtPath: url.path)
        }
        let launchedAt = Date.now.addingTimeInterval(-60)
        let fresh = try ExportDirectory.make(prefix: ExportDirectory.readingsPrefix, in: base)

        #expect(ExportDirectory.sweep(in: base, createdBefore: launchedAt) == 2)
        #expect(!manager.fileExists(atPath: stale.path))
        #expect(!manager.fileExists(atPath: stalePair.path))
        #expect(manager.fileExists(atPath: fresh.path))
        #expect(manager.fileExists(atPath: ephemeral.path))
        #expect(manager.fileExists(atPath: strayFile.path))
    }

    @Test("Pairwise files are written together or not at all")
    func pairwiseFilesAreAtomic() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = try ExportDirectory.write(
            [("pairs.csv", Data("a\r\n".utf8)), ("summary.txt", Data("b".utf8))],
            prefix: ExportDirectory.pairwisePrefix,
            in: base
        )
        #expect(files.urls.map(\.lastPathComponent) == ["pairs.csv", "summary.txt"])
        #expect(files.directory.lastPathComponent.hasPrefix(ExportDirectory.pairwisePrefix))

        #expect(throws: (any Error).self) {
            _ = try ExportDirectory.write(
                [("pairs.csv", Data()), ("missing/summary.txt", Data())],
                prefix: ExportDirectory.pairwisePrefix,
                in: base
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == [files.directory.lastPathComponent])
    }
}
