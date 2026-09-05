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
    private(set) var phase: WorkoutPhase = .idle
    private(set) var heartRate: WorkoutHeartRate?
    private(set) var averageHeartRate: Double?
    private(set) var message: String?
    private(set) var activityTitle = "Workout"
    private(set) var finalDuration: TimeInterval = 0

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var endDate: Date?
    @ObservationIgnored private var collectionEnded = false
    @ObservationIgnored private var isEndingCollection = false
    @ObservationIgnored private var generation = UUID()

    func start(activity: WatchWorkoutActivity, indoors: Bool) async {
        guard phase.canStart, session == nil else { return }
        let operation = UUID()
        generation = operation
        phase = .authorizing
        message = nil
        heartRate = nil
        averageHeartRate = nil
        finalDuration = 0
        guard HKHealthStore.isHealthDataAvailable() else {
            failStart("Health data is unavailable on this watch.")
            return
        }
        do {
            let heartRateType = HKQuantityType(.heartRate)
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType(), heartRateType],
                read: [heartRateType]
            )
            guard generation == operation else { return }
            // Sheet completion does not establish read permission. Sharing status does
            // tell us whether the user allows the workout we are about to create.
            guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                failStart("Allow HeartSync to save Workouts in Health permissions, then try again.")
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activity.healthKitType
            configuration.locationType = activity == .other ? .unknown : (indoors ? .indoor : .outdoor)
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            attach(session)
            activityTitle = activity.rawValue
            phase = .starting
            let date = Date.now
            session.startActivity(with: date)
            guard let builder else { return }
            try await builder.beginCollection(at: date)
            guard self.session === session, phase == .starting else { return }
            phase = session.state == .paused ? .paused : .running
        } catch {
            guard generation == operation else { return }
            // A start failure has no reviewable workout. Detach before ending so queued
            // delegate events cannot revive this failed session.
            failStart("Could not start workout: \(error.localizedDescription)")
        }
    }

    func pauseOrResume() {
        if phase == .running { session?.pause() }
        else if phase == .paused { session?.resume() }
    }

    func stop() {
        guard phase.isCollecting, let session else { return }
        phase = .stopping
        session.stopActivity(with: .now)
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let builder, !collectionEnded else { return finalDuration }
        return max(0, builder.elapsedTime(at: date))
    }

    /// A save failure retains the builder for retry or an explicit discard. The UI may
    /// only claim success after HealthKit completes the save without an error. A nil
    /// workout with no error means success while the saved object is protected by lock.
    func save() async {
        guard phase == .review, let builder else { return }
        phase = .saving
        message = nil
        do {
            if !collectionEnded {
                try await builder.endCollection(at: endDate ?? .now)
                collectionEnded = true
                finalDuration = builder.elapsedTime
            }
            let savedWorkout = try await builder.finishWorkout()
            detachSession(discard: false)
            phase = .saved
            message = savedWorkout == nil
                ? "Saved to Apple Health. Unlock your watch to view the workout. Readings reach iPhone after Health syncs."
                : "Saved to Apple Health. Readings appear on iPhone after Health syncs and HeartSync refreshes."
        } catch {
            phase = .review
            message = "Not saved: \(error.localizedDescription) Try Save again, or discard this workout."
        }
    }

    func discard() {
        guard phase == .review else { return }
        detachSession(discard: true)
        phase = .idle
        heartRate = nil
        averageHeartRate = nil
        finalDuration = 0
        message = "Workout discarded. HealthKit may retain sensor samples Apple Watch collected independently."
    }

    /// Invoked by WKApplicationDelegate after the system relaunches an active workout.
    func recover() async {
        guard session == nil, phase.canStart else { return }
        phase = .starting
        do {
            guard let recovered = try await healthStore.recoverActiveWorkoutSession() else {
                failStart("The previous workout could not be recovered.")
                return
            }
            attach(recovered)
            activityTitle = WatchWorkoutActivity.allCases.first {
                $0.healthKitType == recovered.workoutConfiguration.activityType
            }?.rawValue ?? "Recovered workout"
            readStatistics()
            switch recovered.state {
            case .running: phase = .running
            case .paused: phase = .paused
            case .stopped, .ended: await prepareReview(at: recovered.endDate ?? .now)
            default: failStart("The previous workout is no longer active.")
            }
        } catch {
            failStart("Could not recover workout: \(error.localizedDescription)")
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
        collectionEnded = builder.endDate != nil
        isEndingCollection = false
    }

    private func prepareReview(at date: Date) async {
        guard let builder, !isEndingCollection, phase != .review, phase != .saving, phase != .saved else { return }
        isEndingCollection = true
        phase = .stopping
        endDate = date
        finalDuration = max(0, builder.elapsedTime(at: date))
        do {
            if !collectionEnded { try await builder.endCollection(at: date) }
            collectionEnded = true
            finalDuration = max(0, builder.elapsedTime)
        } catch {
            message = "Could not finish collecting: \(error.localizedDescription) Save will retry."
        }
        isEndingCollection = false
        phase = .review
    }

    private func failStart(_ detail: String) {
        detachSession(discard: true)
        phase = .failed
        message = detail
    }

    private func detachSession(discard: Bool) {
        generation = UUID()
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
        if let latest = sample.latest { heartRate = latest }
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
            switch toState {
            case .running:
                if self.phase == .paused { self.phase = .running }
            case .paused:
                if self.phase == .running { self.phase = .paused }
            case .stopped, .ended:
                await self.prepareReview(at: date)
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let id = ObjectIdentifier(workoutSession)
        let detail = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.session.map(ObjectIdentifier.init) == id else { return }
            if self.builder?.startDate != nil {
                self.message = "Workout interrupted: \(detail) Review the collected workout before saving."
                await self.prepareReview(at: .now)
            } else {
                self.failStart("Workout failed: \(detail)")
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
