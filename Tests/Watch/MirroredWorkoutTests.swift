import Foundation
import Testing
@testable import HeartSyncChecker

/// The live watch-workout display on iPhone (improvement 72): the payload the watch sends,
/// its validation, freshness, and the rule that it is display only.
@Suite("Mirrored workout display")
struct MirroredWorkoutTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func payload(_ heartRate: Double?, secondsAgo: TimeInterval = 2, paused: Bool = false) -> MirroredWorkoutPayload {
        MirroredWorkoutPayload(
            heartRate: heartRate,
            measuredAt: heartRate == nil ? nil : now.addingTimeInterval(-secondsAgo),
            isPaused: paused,
            activityTitle: "Running"
        )
    }

    @Test("A payload round-trips and stays within its size cap")
    func roundTrip() throws {
        let data = try payload(142).encoded()
        #expect(data.count <= MirroredWorkoutPayload.maximumBytes)
        #expect(MirroredWorkoutPayload.decoded(data, now: now) == payload(142))
    }

    @Test("An implausible or far-off heart rate is dropped, the rest of the payload kept")
    func validation() throws {
        let absurd = try #require(MirroredWorkoutPayload.decoded(try payload(900).encoded(), now: now))
        #expect(absurd.heartRate == nil && absurd.measuredAt == nil)
        #expect(absurd.activityTitle == "Running")
        let stale = try #require(MirroredWorkoutPayload.decoded(try payload(120, secondsAgo: 7_200).encoded(), now: now))
        #expect(stale.heartRate == nil)
    }

    @Test("A newer version, garbage, or an oversized message is refused")
    func refusals() throws {
        var newer = payload(120)
        newer.version = MirroredWorkoutPayload.currentVersion + 1
        #expect(MirroredWorkoutPayload.decoded(try JSONEncoder().encode(newer), now: now) == nil)
        #expect(MirroredWorkoutPayload.decoded(Data("not json".utf8), now: now) == nil)
        #expect(MirroredWorkoutPayload.decoded(Data(repeating: 0x20, count: 4_096), now: now) == nil)
    }

    @Test("Live means measured in the last fifteen seconds and not paused")
    func liveness() {
        #expect(payload(120, secondsAgo: 5).isLive(at: now))
        #expect(!payload(120, secondsAgo: 20).isLive(at: now))
        #expect(!payload(120, secondsAgo: 5, paused: true).isLive(at: now))
        #expect(!payload(nil).isLive(at: now))
    }

    @MainActor
    @Test("A received value is shown and never reaches the store")
    func displayOnly() throws {
        let model = AppModel(
            store: HealthStore(persistenceEnabled: false),
            settings: AppSettings(persistenceEnabled: false),
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: .inert
        )
        model.workoutMirror.receive([try payload(150).encoded()], at: now)
        #expect(model.workoutMirror.latest?.heartRate == 150)
        #expect(model.store.readings.isEmpty)
        #expect(model.store.sources.isEmpty)
    }
}
