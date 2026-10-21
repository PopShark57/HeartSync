import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Projection read failures")
@MainActor
struct ProjectionFailureTests {
    private let source = DataSource(id: "strap", displayName: "Strap", transport: .bluetooth)

    private var unavailable: HealthHistory {
        HealthHistory(sources: [source], changeToken: 1, removalGeneration: 0, loadState: .loaded, readers: nil, pending: [], unavailableDetail: "Injected unavailable history")
    }

    @Test("Unavailable reads cannot cache a baseline or authorize reconciliation")
    func estimatesFailExplicitly() {
        let inputs = DerivedEstimates.Inputs(vo2MaxEnabled: true, estimatedMaxHeartRate: 190, bloodPressureCalibration: nil, estimateSourceID: AppModel.estimateSourceID)
        let failed = DerivedEstimates.compute(history: unavailable, inputs: inputs, now: .now)
        #expect(!failed.successfulKinds.contains(.vo2Max))
        #expect(!failed.successfulKinds.contains(.stress))
        #expect(failed.stressBaseline == nil)
        #expect(!failed.historyErrors.isEmpty)
        // Reusing a good baseline does not turn failed current-signal reads into success.
        var cached = inputs
        cached.stressBaseline = StressModel.Baseline(builtAt: .now, utcOffset: TimeZone.current.secondsFromGMT())
        let currentFailure = DerivedEstimates.compute(history: unavailable, inputs: cached, now: .now)
        #expect(!currentFailure.successfulKinds.contains(.stress))
        #expect(currentFailure.stressBaseline == nil)
    }

    @Test("A failed watch publication is unavailable and the next successful read recovers")
    func watchUnavailableAndRecovery() {
        let cache = WatchChartCache()
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(source)
        store.append(Reading(sourceID: source.id, kind: .heartRate, value: 72, start: .now.addingTimeInterval(-30)))
        let first = WatchSnapshotBuilder.make(store: store, cache: cache)
        #expect(first.availability == .ready)
        #expect(!first.metrics.isEmpty)
        let failed = WatchSnapshotBuilder.make(history: unavailable, cache: cache)
        #expect(failed.availability == .unavailable)
        #expect(failed.metrics.isEmpty)
        #expect(failed.complicationProjection.availability == .unavailable)
        let recovered = WatchSnapshotBuilder.make(store: store, cache: cache)
        #expect(recovered.availability == .ready)
        #expect(recovered.metrics.first?.readings.first?.value == 72)
    }

    @Test("Duplicate names retain distinct presentation labels across transports and models")
    func duplicateNames() {
        let a = DataSource(id: "a", displayName: "Ring", transport: .bluetooth, model: "Same")
        let b = DataSource(id: "b", displayName: "Ring", transport: .bluetooth, model: "Same")
        let c = DataSource(id: "c", displayName: "Ring", transport: .healthKit)
        let d = DataSource(id: "d", displayName: "Ring", transport: .oura)
        let labels = SourceLabels.make(for: [a, b, c, d])
        #expect(Set(labels.values).count == 4)
        #expect(SourceLabels.make(for: [d, c, b, a]) == labels)
        var longA = a
        var longB = b
        longA.displayName = String(repeating: "Long name ", count: 20)
        longB.displayName = longA.displayName
        let boundedA = SourceLabels.boundedName(for: a.id, in: [longA, longB])
        let boundedB = SourceLabels.boundedName(for: b.id, in: [longA, longB])
        #expect(boundedA.count <= 100)
        #expect(boundedA != boundedB)
        #expect(MetricDetailSnapshot.makeSeries(for: [a, b, c, d]).map(\.label) == [a, b, c, d].map { labels[$0.id]! })
    }
}
