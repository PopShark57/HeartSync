import Foundation
import Testing
@testable import HeartSyncMac

@Suite("Mac application orchestration")
@MainActor
struct MacMirrorServiceTests {
    @MainActor
    private final class Storage {
        var state: MacMirrorPairingStore.State?
        var failClear = false
        var failSaveNumber: Int?
        var saves = 0
        var clears = 0
        init(_ record: MacMirrorPairingRecord) { state = .init(records: [record]) }
        var actions: MacMirrorService.Actions {
            .init(load: { self.state }, save: { state in
                self.saves += 1
                if self.saves == self.failSaveNumber { return false }
                self.state = state
                return true
            }, clear: { store in
                self.clears += 1
                return !self.failClear && store.clearMirror()
            }, listen: false)
        }
    }

    private func record(_ name: String) -> MacMirrorPairingRecord {
        .init(identity: name, key: Data(repeating: 1, count: 32), peer: .init(id: UUID(), name: name), pairedAt: .now)
    }

    @Test("Unpair and replacement recover after each durable boundary")
    func recoversDurableSteps() async throws {
        for replacing in [false, true] {
            for failure in ["journal", "erase", "finalKey"] {
                let old = record("old")
                let replacement = record("new")
                let storage = Storage(old)
                let store = HealthStore(persistenceEnabled: false)
                store.upsert(.init(id: "old", displayName: "Old phone", transport: .healthKit))
                store.append(.init(sourceID: "old", kind: .heartRate, value: 70, start: .now.addingTimeInterval(-60)))
                let service = MacMirrorService(macName: "Mac", actions: storage.actions)
                await service.start(store: store)
                storage.failClear = failure == "erase"
                storage.failSaveNumber = failure == "journal" ? 1 : failure == "finalKey" ? 2 : nil
                let succeeded = replacing ? await service.replacePairing(replacement) : await service.unpair()
                #expect(!succeeded)
                if failure == "journal" {
                    #expect(storage.state?.pending == nil)
                    #expect(store.readings.count == 1)
                    #expect(service.pairing == old)
                } else {
                    #expect(storage.state?.pending != nil)
                    #expect(service.cleanupPending)
                    #expect(service.pairing == nil)
                    #expect(store.readings.count == (failure == "erase" ? 1 : 0))
                }
                // New service instance simulates process termination. No listener may run
                // with a pending operation; startup replays the idempotent erase first.
                storage.failClear = false
                storage.failSaveNumber = nil
                let restarted = MacMirrorService(macName: "Mac", actions: storage.actions)
                await restarted.start(store: store)
                if failure == "journal" {
                    #expect(restarted.pairing == old)
                    #expect(store.readings.count == 1)
                } else {
                    #expect(storage.state?.pending == nil)
                    #expect(store.readings.isEmpty)
                    #expect(store.sources.isEmpty)
                    #expect(restarted.pairing == (replacing ? replacement : nil))
                    #expect(!restarted.cleanupPending)
                }
            }
        }
    }

    @Test("An unavailable pairing refuses replacement without erasing unknown history")
    func unavailablePairing() async {
        let storage = Storage(record("old"))
        storage.state = nil
        let store = HealthStore(persistenceEnabled: false)
        let service = MacMirrorService(macName: "Mac", actions: storage.actions)
        await service.start(store: store)
        #expect(await service.replacePairing(record("new")) == false)
        #expect(storage.clears == 0)
        #expect(storage.saves == 0)
        #expect(service.pairingUnavailable)
    }

    @Test("Composition root starts once with isolated stores and services disabled")
    func compositionRoot() async {
        let model = AppModel(store: HealthStore(persistenceEnabled: false), settings: AppSettings(persistenceEnabled: false), sessions: ComparisonSessionStore(persistenceEnabled: false), runServices: false)
        await model.start()
        #expect(model.startupState == .ready)
        await model.start()
        #expect(model.store.sources.isEmpty)
    }
}
