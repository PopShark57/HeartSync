import Foundation
import Observation

/// Coalesces high-frequency ingest and also observes rename, hide, deletion, and reset
/// paths, which can change the wrist projection without adding a reading.
@MainActor
final class WatchCompanionPublisher {
    let connection = CompanionSession()
    private weak var store: HealthStore?
    private var pending: Task<Void, Never>?
    /// The build in flight, and a number that only the newest build may publish under, so a
    /// slow build that finishes after a newer one cannot replace it.
    private var building: Task<Void, Never>?
    private var buildSequence = 0
    private var lastPublished = Date.distantPast
    /// Keeps the 24-hour, 7-day, and 30-day periods between publications.
    private let chartCache = WatchChartCache()

    func start(
        store: HealthStore,
        onRefresh: @escaping @MainActor () -> Void,
        onSyncAll: @escaping @MainActor () async -> WatchSyncReport
    ) {
        guard self.store == nil else { return }
        self.store = store
        connection.onRefresh = onRefresh
        connection.onSyncAll = onSyncAll
        connection.onActivation = { [weak self] in self?.publishNow() }
        observeStore()
        connection.start()
    }

    /// Starts a publication now. The snapshot is read, built, and encoded off the main actor;
    /// only handing the bytes to WatchConnectivity happens here.
    func publishNow() {
        pending?.cancel()
        pending = nil
        guard connection.isInstalled, let store else { return }
        let history = store.history
        let cache = chartCache
        buildSequence &+= 1
        let sequence = buildSequence
        lastPublished = .now
        building = Task { [weak self] in
            // Built and encoded off the main actor; only the finished bytes come back.
            let payload = await HealthHistory.offMain(priority: .utility) {
                WatchSnapshotBuilder.makePayload(history: history, cache: cache)
            }
            guard let self, sequence == self.buildSequence, let data = payload.data else { return }
            self.connection.publish(encoded: data)
        }
    }

    /// Waits for the build in flight, for tests and for callers that must know the
    /// newest snapshot has been handed over.
    func waitForPublication() async {
        await building?.value
    }

    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.changeToken
            _ = store.sources
            _ = store.loadState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStore()
                self.schedulePublish()
            }
        }
    }

    private func schedulePublish() {
        guard pending == nil else { return }
        let delay = max(0, 30 - Date.now.timeIntervalSince(lastPublished))
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }
}
