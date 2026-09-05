import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Watch companion payload")
struct WatchSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func fixture() -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, metrics: [
            WatchMetric(
                kind: .heartRate,
                readings: [WatchSourceReading(id: "strap", sourceName: "Chest strap", value: 72, timestamp: now.addingTimeInterval(-5), provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 1, outsideTolerancePairs: 0, lookback: 3_600)
            ),
        ])
    }

    @Test("Wire round-trip preserves units, provenance, timestamps and evidence")
    func roundTrip() throws {
        let snapshot = fixture()
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)
    }

    @Test("Future schemas and oversized messages are rejected before adoption")
    func incompatiblePayloads() throws {
        var snapshot = fixture()
        snapshot.version = 2
        let data = try JSONEncoder().encode(snapshot)
        #expect(throws: WatchSnapshot.PayloadError.self) { try WatchSnapshot.decode(data) }
        #expect(throws: WatchSnapshot.PayloadError.self) {
            try WatchSnapshot.decode(Data(repeating: 0, count: WatchSnapshot.maximumBytes + 1))
        }
    }

    @Test("Impossible values, duplicate identities and contradictory counts are rejected")
    func invalidPayloads() throws {
        var value = fixture()
        value.metrics[0].readings[0].value = 1_000
        #expect(throws: WatchSnapshot.PayloadError.self) { try value.encoded() }
        var duplicate = fixture()
        duplicate.metrics[0].readings.append(duplicate.metrics[0].readings[0])
        #expect(throws: WatchSnapshot.PayloadError.self) { try duplicate.encoded() }
        var evidence = fixture()
        evidence.metrics[0].comparison.outsideTolerancePairs = 1
        #expect(throws: WatchSnapshot.PayloadError.self) { try evidence.encoded() }
    }

    @Test("A reset clears the wrist, and a late old update cannot resurrect it")
    func lateDeliveryAfterReset() throws {
        var inbox = WatchSnapshotInbox()
        #expect(try inbox.receive(fixture().encoded()))
        let reset = WatchSnapshot(generatedAt: now.addingTimeInterval(10), metrics: [])
        #expect(try inbox.receive(reset.encoded()))
        #expect(try !inbox.receive(fixture().encoded()))
        #expect(inbox.snapshot?.metrics.isEmpty == true)
    }

    @Test("A corrupt update preserves the last readable snapshot")
    func corruptUpdate() throws {
        var inbox = WatchSnapshotInbox()
        try inbox.receive(fixture().encoded())
        #expect(throws: (any Error).self) { try inbox.receive(Data("corrupt".utf8)) }
        #expect(inbox.snapshot == fixture())
    }

    @Test("Partial or absent evidence never yields an all-pairs agreement claim")
    func evidenceGates() {
        #expect(!WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600).allPairsAgree)
        #expect(!WatchComparison(readyPairs: 1, incompletePairs: 1, outsideTolerancePairs: 0, lookback: 3_600).allPairsAgree)
        #expect(!WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 1, lookback: 3_600).allPairsAgree)
        #expect(WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600).allPairsAgree)
    }

    @Test("Cached values age by measurement time, not by snapshot refresh time")
    func staleValues() {
        let reading = fixture().metrics[0].readings[0]
        #expect(!reading.isStale(kind: .heartRate, now: now))
        #expect(reading.isStale(kind: .heartRate, now: now.addingTimeInterval(901)))
        #expect(!reading.isStale(kind: .restingHeartRate, now: now.addingTimeInterval(901)))
    }

    @Test("Live workout heart rate rejects invalid values and stops appearing current")
    func liveWorkoutFreshness() throws {
        #expect(WorkoutHeartRate.validated(value: .nan, timestamp: now, now: now) == nil)
        #expect(WorkoutHeartRate.validated(value: 500, timestamp: now, now: now) == nil)
        #expect(WorkoutHeartRate.validated(value: 72, timestamp: now.addingTimeInterval(61), now: now) == nil)
        let reading = try #require(WorkoutHeartRate.validated(value: 72, timestamp: now, now: now))
        #expect(reading.isCurrent(at: now.addingTimeInterval(15)))
        #expect(!reading.isCurrent(at: now.addingTimeInterval(16)))
    }
}
