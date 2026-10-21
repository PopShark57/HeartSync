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
    private var mutationTail: Task<Bool, Never>?

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

    /// Queue edits on the main actor, but publish only after the atomic archive write.
    /// Each edit reads the state committed by its predecessor, including after a failure.
    private func mutate(_ edit: @escaping @MainActor ([ComparisonSession]) -> [ComparisonSession]?) async -> Bool {
        let previous = mutationTail
        let task = Task { @MainActor in
            _ = await previous?.value
            guard self.loadState == .loaded, let proposed = edit(self.sessions) else { return false }
            if self.persistenceEnabled {
                guard await self.archive.write(proposed, to: self.archiveName) else { return false }
            }
            self.sessions = proposed
            return true
        }
        mutationTail = task
        return await task.value
    }

    @discardableResult
    func save(_ session: ComparisonSession) async -> Bool {
        await mutate { sessions in
            var updated = sessions.filter { $0.id != session.id }
            updated.append(session)
            updated.sort { $0.createdAt > $1.createdAt }
            return Array(updated.prefix(Self.maximumSessions))
        }
    }

    @discardableResult
    func remove(id: UUID) async -> Bool {
        await mutate { sessions in
            guard sessions.contains(where: { $0.id == id }) else { return nil }
            return sessions.filter { $0.id != id }
        }
    }

    @discardableResult
    func noteViewed(id: UUID, readingCount: Int, fingerprint: Int64? = nil, at date: Date = .now) async -> Bool {
        await mutate { sessions in
            var updated = sessions
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return nil }
            updated[index].lastViewedReadingCount = readingCount
            updated[index].lastViewedFingerprint = fingerprint
            updated[index].lastViewedAt = date
            return updated
        }
    }
}
