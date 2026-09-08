import Foundation
import Observation
import OSLog

/// Saved comparison sessions, persisted as one small atomic JSON archive.
///
/// Follows `AppSettings`' conventions deliberately: an unreadable archive refuses to save
/// rather than overwriting bytes it could not read, and hydration does not schedule a save
/// of what it just loaded. This is selection data, not measurements — it holds no readings
/// and is not a second history store.
@MainActor
@Observable
final class ComparisonSessionStore {
    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Sessions")

    private(set) var sessions: [ComparisonSession] = []

    enum LoadState: Sendable, Equatable { case notLoaded, loaded, failed }
    private(set) var loadState: LoadState
    private(set) var loadIssue: String?

    /// A saved session is cheap, but it is still user data in a file that is read on every
    /// launch. Capped so a runaway caller cannot grow the archive without bound.
    static let maximumSessions = 200

    private let persistenceEnabled: Bool
    private let archive: ReadingArchive
    private let archiveName: String
    private var loadTask: Task<Void, Never>?

    init(
        persistenceEnabled: Bool = true,
        archive: ReadingArchive = .shared,
        archiveName: String = ReadingArchive.File.comparisonSessions
    ) {
        self.persistenceEnabled = persistenceEnabled
        self.archive = archive
        self.archiveName = archiveName
        self.loadState = persistenceEnabled ? .notLoaded : .loaded
    }

    func loadIfNeeded() async {
        guard persistenceEnabled, loadState != .loaded else { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        let outcome = await archive.readOutcome([ComparisonSession].self, from: archiveName)
        guard outcome.isConclusive else {
            loadState = .failed
            if case .unreadable(let reason) = outcome { loadIssue = reason }
            logger.error("Comparison sessions unreadable; refusing to persist until a load succeeds")
            return
        }
        if case .corrupt(let reason) = outcome { loadIssue = reason } else { loadIssue = nil }
        sessions = (outcome.value ?? []).sorted { $0.createdAt > $1.createdAt }
        loadState = .loaded
    }

    @discardableResult
    func save(_ session: ComparisonSession) async -> Bool {
        var updated = sessions
        if let index = updated.firstIndex(where: { $0.id == session.id }) {
            updated[index] = session
        } else {
            updated.insert(session, at: 0)
        }
        updated.sort { $0.createdAt > $1.createdAt }
        if updated.count > Self.maximumSessions { updated.removeLast(updated.count - Self.maximumSessions) }
        sessions = updated
        return await persist()
    }

    @discardableResult
    func remove(id: UUID) async -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        sessions.removeAll { $0.id == id }
        return await persist()
    }

    /// Records that a session was opened, so the next revisit can disclose what changed.
    @discardableResult
    func noteViewed(id: UUID, readingCount: Int, at date: Date = .now) async -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions[index].lastViewedReadingCount = readingCount
        sessions[index].lastViewedAt = date
        return await persist()
    }

    private func persist() async -> Bool {
        guard persistenceEnabled else { return false }
        guard loadState == .loaded else {
            logger.error("Refusing to save comparison sessions: the archive has not loaded")
            return false
        }
        return await archive.write(sessions, to: archiveName)
    }
}
