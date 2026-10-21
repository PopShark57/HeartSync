import Foundation
import Observation
import Testing
@testable import HeartSyncChecker

private final class SourceObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

@Suite("Source metadata and user choices")
@MainActor
struct SourceMetadataTests {
    @Test("Status-only writes do not invalidate analysis, and failures remain visible")
    func metadataInvalidationAndFailure() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(.init(id: "a", displayName: "Sensor", transport: .bluetooth))
        let observed = SourceObservationFlag()
        withObservationTracking {
            _ = store.history
        } onChange: { observed.mark() }
        let generation = store.changeToken
        #expect(store.updateBattery(80, forSource: "a") == .applied)
        #expect(store.markSeen(sourceID: "a", at: .now.addingTimeInterval(-60)) == .applied)
        #expect(!observed.value)
        #expect(store.changeToken == generation)
        store.injectDatabaseFailureOnNextCommitForTesting()
        if case .failed = store.updateBattery(40, forSource: "a") {} else { Issue.record("Expected write failure") }
        #expect(store.source(id: "a")?.batteryPercent == 80)
        #expect(store.sourceMetadataIssue != nil)
        #expect(store.updateBattery(40, forSource: "a") == .applied)
        #expect(store.sourceMetadataIssue == nil)
    }

    @Test("Health and Oura aliases and explicit relationships survive transport updates")
    func aliasesAndRelationships() throws {
        let store = HealthStore(persistenceEnabled: false)
        let a = DataSource(id: "health", displayName: "Reported Health name", transport: .healthKit)
        let b = DataSource(id: "oura", displayName: "Reported Oura name", transport: .oura)
        store.upsert(a)
        store.upsert(b)
        #expect(store.rename(sourceID: a.id, to: "My Watch") == .applied)
        #expect(store.rename(sourceID: b.id, to: "My Ring") == .applied)
        #expect(store.setRelationship(sourceID: a.id, sameDeviceAs: b.id) == .applied)
        store.upsert(a)
        store.upsert(b)
        let health = try #require(store.source(id: a.id))
        let oura = try #require(store.source(id: b.id))
        #expect(health.displayName == "My Watch")
        #expect(oura.displayName == "My Ring")
        #expect(health.likelyRepresentsSameDevice(as: oura))
        store.injectDatabaseFailureOnNextCommitForTesting()
        if case .failed = store.setRelationship(sourceID: a.id, sameDeviceAs: nil) {} else { Issue.record("Expected failed write") }
        #expect(store.source(id: a.id)?.likelyRepresentsSameDevice(as: oura) == true)
        #expect(store.setRelationship(sourceID: a.id, sameDeviceAs: nil) == .applied)
        store.upsert(a)
        #expect(store.source(id: a.id)?.likelyRepresentsSameDevice(as: oura) == false)
        let persisted = try store.history.query { try $0.allSources() }.get()
        #expect(persisted.first(where: { $0.id == a.id })?.relationshipIsUserChosen == true)
    }

    @Test("Grouped latest reads match indexed individual queries including ties")
    func groupedLatest() throws {
        let store = HealthStore(persistenceEnabled: false)
        for id in ["a", "b"] { store.upsert(.init(id: id, displayName: id, transport: .bluetooth)) }
        let now = Date.now.addingTimeInterval(-60)
        store.append(contentsOf: [
            .init(sourceID: "a", kind: .heartRate, value: 60, start: now),
            .init(sourceID: "a", kind: .heartRate, value: 61, start: now),
            .init(sourceID: "a", kind: .spo2, value: 98, start: now),
            .init(sourceID: "b", kind: .heartRate, value: 70, start: now.addingTimeInterval(-60)),
            .init(sourceID: "b", kind: .heartRate, value: 71, start: now)
        ])
        let grouped = try store.history.query { try $0.latestReadings(sourceIDs: ["a", "b"]) }.get()
        #expect(grouped.count == 3)
        for reading in grouped { #expect(store.latest(kind: reading.kind, sourceID: reading.sourceID) == reading) }
    }
}
