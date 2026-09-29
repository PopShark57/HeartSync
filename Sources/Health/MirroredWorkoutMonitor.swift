import Foundation
import HealthKit
import Observation
import OSLog

/// Receives a workout Apple Watch mirrors to iPhone and holds its latest heart rate for
/// display (improvement 72).
///
/// Display only, by construction: this type has no store, no ingest callback, and no
/// HealthKit write. Its value lives in memory for as long as the mirrored session does.
/// The workout's samples arrive later through the ordinary HealthKit import.
///
/// The mirroring handler is installed at launch (`AppModel.launch`), because HealthKit may
/// launch the app to hand the session over. Apple expects an app launched that way in the
/// background to start a Live Activity within ten seconds; HeartSync has no widget
/// extension and does not, so the card is only reliable while HeartSync is running.
@MainActor
@Observable
final class MirroredWorkoutMonitor: NSObject, HKWorkoutSessionDelegate {
    /// The latest payload from the watch, nil when no mirrored workout is running.
    private(set) var latest: MirroredWorkoutPayload?
    /// When the latest payload arrived.
    private(set) var receivedAt: Date?

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var installed = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "WorkoutMirror")

    var isActive: Bool { session != nil || latest != nil }

    /// Sets HealthKit's mirroring handler. Once per process.
    func install(on healthStore: HKHealthStore) {
        guard !installed, HKHealthStore.isHealthDataAvailable() else { return }
        installed = true
        healthStore.workoutSessionMirroringStartHandler = { [weak self] mirrored in
            // HealthKit's queue. The session is Sendable; it is adopted on the main actor.
            Task { @MainActor [weak self] in self?.adopt(mirrored) }
        }
    }

    private func adopt(_ mirrored: HKWorkoutSession) {
        session?.delegate = nil
        session = mirrored
        latest = nil
        receivedAt = nil
        mirrored.delegate = self
        logger.info("Adopted a mirrored workout session from Apple Watch")
    }

    /// Applies one message from the watch. Exposed for tests.
    func receive(_ messages: [Data], at now: Date = .now) {
        guard let payload = messages.compactMap({ MirroredWorkoutPayload.decoded($0, now: now) }).last else { return }
        latest = payload
        receivedAt = now
    }

    private func end() {
        session?.delegate = nil
        session = nil
        latest = nil
        receivedAt = nil
    }

    // MARK: HKWorkoutSessionDelegate

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended || toState == .stopped else { return }
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            self.end()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            self.end()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            self.receive(data)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            self.end()
        }
    }
}
