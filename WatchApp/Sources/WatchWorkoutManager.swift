import Foundation
import HealthKit
import Observation

enum WatchWorkoutActivity: String, CaseIterable, Identifiable {
    case other = "Other workout"
    case walking = "Walking"
    case running = "Running"
    case cycling = "Cycling"

    var id: String { rawValue }
    var healthKitType: HKWorkoutActivityType {
        switch self {
        case .other: .other
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        }
    }
}

/// A real, user-started HealthKit workout. Live values stay on the watch; saving lets
/// HealthKit synchronize sample UUIDs to the existing iPhone anchored-query import.
@MainActor
@Observable
final class WatchWorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    /// Every transition decision lives in `WorkoutLifecycle`, which is pure and compiled
    /// into the iPhone app as well, so the lifecycle this class drives is covered by the
    /// hosted test bundle CI runs. This class stays the HealthKit adapter: it owns the
    /// session and builder, and asks the lifecycle what is allowed to happen to them.
    private(set) var lifecycle = WorkoutLifecycle()
    private(set) var heartRate: WorkoutHeartRate?
    /// The last five minutes of heart rate for the workout screen's trend. In memory only.
    private(set) var heartRateTrend = WorkoutHeartRateTrend()
    private(set) var averageHeartRate: Double?
    private(set) var activityTitle = "Workout"

    var phase: WorkoutPhase { lifecycle.phase }
    var message: String? { lifecycle.message }
    var finalDuration: TimeInterval { lifecycle.finalDuration }

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var endDate: Date?
    /// Token of the session currently attached, matched against every delegate callback
    /// alongside the object-identity check.
    @ObservationIgnored private var token: WorkoutSessionToken?

    func start(activity: WatchWorkoutActivity, indoors: Bool) async {
        // A second Start tap while one is in flight returns nil here, so no second
        // HKWorkoutSession is ever created for one intent.
        guard let operation = lifecycle.beginStart(), session == nil else { return }
        self.token = operation
        heartRate = nil
        heartRateTrend.reset()
        averageHeartRate = nil
        guard HKHealthStore.isHealthDataAvailable() else {
            failStart(operation, "Health data is unavailable on this watch.")
            return
        }
        do {
            let heartRateType = HKQuantityType(.heartRate)
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType(), heartRateType],
                read: [heartRateType]
            )
            guard lifecycle.accepts(operation) else { return }
            // Sheet completion does not establish read permission. Sharing status does
            // tell us whether the user allows the workout we are about to create.
            guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                failStart(operation, "Allow HeartSync to save Workouts in Health permissions, then try again.")
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activity.healthKitType
            configuration.locationType = activity == .other ? .unknown : (indoors ? .indoor : .outdoor)
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            attach(session)
            activityTitle = activity.rawValue
            lifecycle.markStarting(operation)
            let date = Date.now
            session.startActivity(with: date)
            guard let builder else { return }
            try await builder.beginCollection(at: date)
            guard self.session === session else { return }
            lifecycle.markCollecting(operation, paused: session.state == .paused)
        } catch {
            guard lifecycle.accepts(operation) else { return }
            // A start failure has no reviewable workout. Detach before ending so queued
            // delegate events cannot revive this failed session.
            failStart(operation, "Could not start workout: \(error.localizedDescription)")
        }
    }

    func pauseOrResume() {
        switch lifecycle.pauseAction() {
        case .pause:  session?.pause()
        case .resume: session?.resume()
        case .ignore: break
        }
    }

    func stop() {
        // A repeat Stop tap is rejected here, so stopActivity is sent once per workout.
        guard let session, lifecycle.beginStop() else { return }
        session.stopActivity(with: .now)
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let builder, !lifecycle.collectionEnded else { return lifecycle.finalDuration }
        return max(0, builder.elapsedTime(at: date))
    }

    /// A save failure retains the builder for retry or an explicit discard. The UI may
    /// only claim success after HealthKit completes the save without an error. A nil
    /// workout with no error means success while the saved object is protected by lock.
    func save() async {
        // Returns nil unless we are in review, so a second Save tap (or a repeated event)
        // cannot write the same workout to HealthKit twice.
        guard lifecycle.beginSave() != nil, let builder else { return }
        do {
            if !lifecycle.collectionEnded {
                try await builder.endCollection(at: endDate ?? .now)
                lifecycle.markCollectionEnded(elapsed: builder.elapsedTime)
            }
            let savedWorkout = try await builder.finishWorkout()
            detachHealthKitObjects(discard: false)
            lifecycle.markSaved(protectedByLock: savedWorkout == nil)
        } catch {
            lifecycle.markSaveFailed(error.localizedDescription)
        }
    }

    func discard() {
        guard lifecycle.beginDiscard() else { return }
        detachHealthKitObjects(discard: true)
        heartRate = nil
        heartRateTrend.reset()
        averageHeartRate = nil
    }

    /// Invoked by WKApplicationDelegate after the system relaunches an active workout.
    func recover() async {
        guard session == nil, let operation = lifecycle.beginRecovery() else { return }
        self.token = operation
        do {
            guard let recovered = try await healthStore.recoverActiveWorkoutSession() else {
                failStart(operation, "The previous workout could not be recovered.")
                return
            }
            attach(recovered)
            activityTitle = WatchWorkoutActivity.allCases.first {
                $0.healthKitType == recovered.workoutConfiguration.activityType
            }?.rawValue ?? "Recovered workout"
            readStatistics()
            switch recovered.state {
            case .running:
                lifecycle.adoptRecovered(operation, state: .running)
            case .paused:
                lifecycle.adoptRecovered(operation, state: .paused)
            case .stopped, .ended:
                await prepareReview(operation, at: recovered.endDate ?? .now)
            default:
                lifecycle.adoptRecovered(operation, state: .unavailable)
                detachHealthKitObjects(discard: true)
            }
        } catch {
            failStart(operation, "Could not recover workout: \(error.localizedDescription)")
        }
    }

    private func attach(_ session: HKWorkoutSession) {
        self.session = session
        let builder = session.associatedWorkoutBuilder()
        self.builder = builder
        session.delegate = self
        builder.delegate = self
        let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: session.workoutConfiguration)
        // V1 requests only workouts and heart rate; no location, route, or calorie access.
        let heartRateType = HKQuantityType(.heartRate)
        for type in source.typesToCollect where type != heartRateType {
            source.disableCollection(for: type)
        }
        source.enableCollection(for: heartRateType, predicate: nil)
        builder.dataSource = source
        endDate = builder.endDate
        if builder.endDate != nil { lifecycle.markCollectionEnded() }
    }

    /// Turns a stopped workout into a reviewable one. Repeated stop/end callbacks for the
    /// same workout are rejected by the lifecycle, so collection is only ended once.
    private func prepareReview(_ operation: WorkoutSessionToken, at date: Date) async {
        guard let builder else { return }
        guard lifecycle.beginReview(operation, at: date, elapsed: builder.elapsedTime(at: date)) else { return }
        endDate = date
        var failure: String?
        if !lifecycle.collectionEnded {
            do { try await builder.endCollection(at: date) }
            catch { failure = error.localizedDescription }
        }
        lifecycle.completeReview(elapsed: failure == nil ? builder.elapsedTime : nil, failure: failure)
    }

    private func failStart(_ operation: WorkoutSessionToken, _ detail: String) {
        guard lifecycle.failStart(operation, reason: detail) else { return }
        detachHealthKitObjects(discard: true)
    }

    /// Releases the HealthKit objects. The lifecycle has already cleared its active token,
    /// so any callback still queued for them is ignored on arrival.
    private func detachHealthKitObjects(discard: Bool) {
        token = nil
        let previous = session
        previous?.delegate = nil
        builder?.delegate = nil
        if discard { builder?.discardWorkout() }
        session = nil
        builder = nil
        previous?.end()
    }

    private func readStatistics() {
        guard let builder else { return }
        apply(Self.statistics(from: builder))
    }

    private func apply(_ sample: StatisticsSnapshot) {
        if let latest = sample.latest {
            heartRate = latest
            heartRateTrend.append(latest)
        }
        averageHeartRate = sample.average
    }

    private struct StatisticsSnapshot: Sendable {
        var latest: WorkoutHeartRate?
        var average: Double?
    }

    nonisolated private static func statistics(from builder: HKLiveWorkoutBuilder) -> StatisticsSnapshot {
        guard let statistics = builder.statistics(for: HKQuantityType(.heartRate)) else {
            return StatisticsSnapshot()
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let latest = statistics.mostRecentQuantity().flatMap { quantity in
            statistics.mostRecentQuantityDateInterval().flatMap { interval in
                WorkoutHeartRate.validated(value: quantity.doubleValue(for: unit), timestamp: interval.end, now: .now)
            }
        }
        let average = statistics.averageQuantity()?.doubleValue(for: unit)
        return StatisticsSnapshot(
            latest: latest,
            average: average.flatMap { $0.isFinite && MetricKind.heartRate.plausibleRange.contains($0) ? $0 : nil }
        )
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            // Both guards matter: object identity catches a callback from a different
            // HealthKit object, and the token catches one from a session this manager has
            // already discarded or replaced.
            guard let operation = self.token, self.lifecycle.accepts(operation) else { return }
            switch toState {
            case .running:
                self.lifecycle.applyRunning(operation)
            case .paused:
                self.lifecycle.applyPaused(operation)
            case .stopped, .ended:
                await self.prepareReview(operation, at: date)
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let id = ObjectIdentifier(workoutSession)
        let detail = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            guard let operation = self.token, self.lifecycle.accepts(operation) else { return }
            if self.builder?.startDate != nil, let builder = self.builder {
                let now = Date.now
                // Collected data survives an interruption, so this becomes a reviewable
                // workout rather than a failed start the user can never save.
                if self.lifecycle.interrupt(
                    operation,
                    detail: detail,
                    at: now,
                    elapsed: builder.elapsedTime(at: now)
                ) {
                    var failure: String?
                    if !self.lifecycle.collectionEnded {
                        do { try await builder.endCollection(at: now) }
                        catch { failure = error.localizedDescription }
                    }
                    self.lifecycle.completeReview(
                        elapsed: failure == nil ? builder.elapsedTime : nil,
                        failure: failure
                    )
                }
            } else {
                self.failStart(operation, "Workout failed: \(detail)")
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let id = ObjectIdentifier(workoutBuilder)
        let sample = Self.statistics(from: workoutBuilder)
        Task { @MainActor [weak self] in
            guard let self, self.builder.map(ObjectIdentifier.init) == id else { return }
            self.apply(sample)
        }
    }

}
