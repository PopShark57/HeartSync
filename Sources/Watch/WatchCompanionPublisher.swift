import Foundation
import Observation

/// Coalesces high-frequency ingest and also observes rename, hide, deletion, and reset
/// paths, which can change the wrist projection without adding a reading.
@MainActor
final class WatchCompanionPublisher {
    let connection = CompanionSession()
    private weak var store: HealthStore?
    private var pending: Task<Void, Never>?
    private var lastPublished = Date.distantPast

    func start(store: HealthStore, onRefresh: @escaping @MainActor () -> Void) {
        guard self.store == nil else { return }
        self.store = store
        connection.onRefresh = onRefresh
        connection.onActivation = { [weak self] in self?.publishNow() }
        observeStore()
        connection.start()
    }

    func publishNow() {
        pending?.cancel()
        pending = nil
        guard connection.isInstalled, let store else { return }
        connection.publish(WatchSnapshotBuilder.make(store: store))
        lastPublished = .now
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
