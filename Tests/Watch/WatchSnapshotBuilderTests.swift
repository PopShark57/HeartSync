import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Watch snapshot projection")
@MainActor
struct WatchSnapshotBuilderTests {
    private func populate(_ store: HealthStore, sourceID: String, value: Double, count: Int = 6, provenance: Provenance = .measured, now: Date) {
        store.upsert(DataSource(id: sourceID, displayName: sourceID, transport: .bluetooth))
        for index in 1...count {
            store.append(Reading(sourceID: sourceID, kind: .heartRate, value: value, start: now.addingTimeInterval(-Double(index) * 60), provenance: provenance))
        }
    }

    @Test("Disabled sources and removed readings are absent from the next snapshot")
    func hideAndDelete() throws {
        let now = Date.now
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, now: now)
        populate(store, sourceID: "b", value: 72, now: now)
        store.setEnabled(false, forSource: "b")
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first)
        #expect(metric.readings.map(\.sourceName) == ["a"])
        #expect(metric.comparison.readyPairs == 0)
        #expect(store.deleteAllReadings())
        #expect(WatchSnapshotBuilder.make(store: store, now: now).metrics.isEmpty)
    }

    @Test("Estimates retain their badge but never contribute comparison evidence")
    func excludeEstimates() throws {
        let now = Date.now
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, now: now)
        populate(store, sourceID: "estimate", value: 70, provenance: .estimated, now: now)
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first)
        #expect(metric.readings.contains { $0.provenance == .estimated })
        #expect(metric.comparison.readyPairs == 0)
        #expect(!metric.comparison.allPairsAgree)
    }

    @Test("The small row limit does not truncate comparison inputs or hide a gap")
    func boundedRowsFullEvidence() throws {
        let now = Date.now
        let store = HealthStore(persistenceEnabled: false)
        for index in 0..<6 {
            populate(store, sourceID: "source-\(index)", value: index == 5 ? 120 : 70, now: now)
        }
        let snapshot = WatchSnapshotBuilder.make(store: store, now: now)
        let metric = try #require(snapshot.metrics.first)
        #expect(metric.readings.count == 4)
        #expect(metric.omittedSourceCount == 2)
        #expect(metric.comparison.readyPairs == 15)
        #expect(metric.comparison.outsideTolerancePairs == 5)
        #expect(!metric.comparison.allPairsAgree)
        #expect(try snapshot.encoded().count < WatchSnapshot.maximumBytes)
    }

    @Test("Four paired windows are still insufficient")
    func minimumEvidence() throws {
        let now = Date.now
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, count: 4, now: now)
        populate(store, sourceID: "b", value: 70, count: 4, now: now)
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first)
        #expect(metric.comparison.readyPairs == 0)
        #expect(metric.comparison.incompletePairs == 1)
        #expect(!metric.comparison.allPairsAgree)
    }

    @Test("Renames reach the payload while long Unicode names remain bounded")
    func renamedSources() throws {
        let now = Date.now
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, now: now)
        store.rename(sourceID: "a", to: String(repeating: "💓", count: 200))
        let snapshot = WatchSnapshotBuilder.make(store: store, now: now)
        #expect(snapshot.metrics.first?.readings.first?.sourceName.count == 100)
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)
    }
}
