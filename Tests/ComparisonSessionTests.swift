import Foundation
import Testing
@testable import HeartSyncChecker

/// Saved comparison sessions with exact periods (improvement 22).
@Suite("Saved comparison sessions")
struct ComparisonSessionTests {

    private let anchor = Date(timeIntervalSince1970: 1_699_999_980)

    private func session(
        sourceIDs: [String] = ["a", "b"],
        lastViewedReadingCount: Int? = nil
    ) -> ComparisonSession {
        ComparisonSession(
            title: "Morning walk",
            context: "walk",
            interval: DateInterval(start: anchor, end: anchor.addingTimeInterval(1_800)),
            sourceIDs: sourceIDs,
            lastViewedReadingCount: lastViewedReadingCount
        )
    }

    // MARK: - Fixed periods

    @Test("A fixed period resolves to the same seconds every time; a rolling one moves")
    func fixedPeriodDoesNotSlide() async throws {
        let interval = DateInterval(start: anchor, end: anchor.addingTimeInterval(1_800))
        let fixed = ComparisonPeriod.fixed(interval)

        #expect(fixed.isFixed)
        #expect(fixed.interval == interval)
        // Resolving again returns the identical span — this is what makes a session
        // re-openable after late data arrives for that period.
        #expect(fixed.interval == fixed.interval)

        let rolling = ComparisonPeriod.rolling(.day)
        #expect(rolling.isFixed == false)
        let first = rolling.interval
        try await Task.sleep(for: .milliseconds(20))
        #expect(rolling.interval.end > first.end)
    }

    @Test("A session round-trips through Codable with its period intact")
    func sessionRoundTrips() throws {
        let original = session()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ComparisonSession.self, from: data)

        #expect(decoded == original)
        #expect(decoded.interval == original.interval)
        #expect(decoded.sourceIDs == ["a", "b"])
        #expect(decoded.context == "walk")
    }

    @Test("An untitled session falls back to its period rather than showing nothing")
    func untitledSessionHasADisplayTitle() {
        var untitled = session()
        untitled.title = "   "
        #expect(untitled.displayTitle.isEmpty == false)
        #expect(untitled.displayTitle != "   ")
    }

    // MARK: - Revisiting

    @Test("A first view makes no claim about what changed")
    func firstViewHasNoDisclosure() {
        #expect(session(lastViewedReadingCount: nil).revisitDisclosure(currentReadingCount: 40) == nil)
    }

    @Test("Late imports for the period are disclosed on revisit")
    func lateImportsAreDisclosed() throws {
        let notice = try #require(
            session(lastViewedReadingCount: 40).revisitDisclosure(currentReadingCount: 52)
        )
        #expect(notice.contains("12"))
        #expect(notice.contains("imported"))
    }

    @Test("Readings that disappeared are disclosed too, not silently ignored")
    func removedReadingsAreDisclosed() throws {
        let notice = try #require(
            session(lastViewedReadingCount: 40).revisitDisclosure(currentReadingCount: 31)
        )
        #expect(notice.contains("9"))
        #expect(notice.contains("no longer stored"))
    }

    @Test("An unchanged period says nothing rather than reassuring falsely")
    func unchangedPeriodIsSilent() {
        #expect(session(lastViewedReadingCount: 40).revisitDisclosure(currentReadingCount: 40) == nil)
    }

    // MARK: - Missing sources

    @Test("A removed device is reported, not quietly dropped from the comparison")
    func missingSourcesAreReported() {
        let known = [DataSource(id: "a", displayName: "Strap", transport: .bluetooth)]
        #expect(session().missingSourceIDs(in: known) == ["b"])
        #expect(session().missingSourceIDs(in: []) == ["a", "b"])
        #expect(
            session().missingSourceIDs(in: [
                DataSource(id: "a", displayName: "Strap", transport: .bluetooth),
                DataSource(id: "b", displayName: "Ring", transport: .oura),
            ]).isEmpty
        )
    }

    // MARK: - Store

    @MainActor
    @Test("Sessions persist, reload, and record when they were last viewed")
    func storePersistsAcrossReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartsync-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ReadingArchive(directory: directory)

        let store = ComparisonSessionStore(archive: archive, archiveName: "sessions-test.json")
        await store.loadIfNeeded()
        #expect(store.loadState == .loaded)

        let saved = session()
        #expect(await store.save(saved))
        #expect(store.sessions.count == 1)
        #expect(await store.noteViewed(id: saved.id, readingCount: 40))

        // A fresh store over the same archive sees the same session and its view state.
        let reloaded = ComparisonSessionStore(archive: archive, archiveName: "sessions-test.json")
        await reloaded.loadIfNeeded()
        let restored = try #require(reloaded.sessions.first)

        #expect(restored.id == saved.id)
        // The exact boundaries survive a relaunch, which is the whole point.
        #expect(restored.interval == saved.interval)
        #expect(restored.sourceIDs == saved.sourceIDs)
        #expect(restored.lastViewedReadingCount == 40)
        #expect(restored.revisitDisclosure(currentReadingCount: 45)?.contains("5") == true)
    }

    @MainActor
    @Test("Removing a session removes it from the archive as well as memory")
    func removalPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartsync-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ReadingArchive(directory: directory)

        let store = ComparisonSessionStore(archive: archive, archiveName: "sessions-test.json")
        await store.loadIfNeeded()
        let saved = session()
        #expect(await store.save(saved))
        #expect(await store.remove(id: saved.id))
        #expect(store.sessions.isEmpty)

        let reloaded = ComparisonSessionStore(archive: archive, archiveName: "sessions-test.json")
        await reloaded.loadIfNeeded()
        #expect(reloaded.sessions.isEmpty)
    }

    @MainActor
    @Test("A store that never loaded refuses to write over the archive")
    func unloadedStoreRefusesToWrite() async throws {
        // Mirrors AppSettings: an archive we could not read must not be overwritten by
        // an empty in-memory state.
        let store = ComparisonSessionStore(archive: ReadingArchive(directory: nil), archiveName: "sessions-test.json")
        #expect(store.loadState == .notLoaded)
        #expect(await store.save(session()) == false)
    }
}
