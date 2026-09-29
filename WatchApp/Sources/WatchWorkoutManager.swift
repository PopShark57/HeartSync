import Foundation
import HealthKit
import Observation

enum WatchWorkoutActivity: String, CaseIterable, Identifiable {
    case other = "Other workout"
    case walking = "Walking"
    case running = "Running"
    case cycling = "Cycling"

    var id: String { rawValue }

    /// What is shown. The raw value stays the stable identity.
    var title: String {
        switch self {
        case .other: String(localized: "workout.activity.other", defaultValue: "Other workout", comment: "Watch workout type")
        case .walking: String(localized: "workout.activity.walking", defaultValue: "Walking", comment: "Watch workout type")
        case .running: String(localized: "workout.activity.running", defaultValue: "Running", comment: "Watch workout type")
        case .cycling: String(localized: "workout.activity.cycling", defaultValue: "Cycling", comment: "Watch workout type")
        }
    }

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
    private(set) var activityTitle = String(localized: "workout.activity.default", defaultValue: "Workout", comment: "Watch workout type before one is chosen")

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

    /// What HealthKit reported, reduced to values that can cross out of its callback queue.
    private enum SessionEvent: Sendable {
        case stateChanged(session: ObjectIdentifier, to: HKWorkoutSessionState, date: Date)
        case failed(session: ObjectIdentifier, detail: String)
        case collected(builder: ObjectIdentifier, sample: StatisticsSnapshot)
    }

    /// Every delegate and builder callback is yielded here, in the order HealthKit called it,
    /// and one main-actor task applies them one at a time.
    ///
    /// Each callback used to start its own unstructured `Task`, and separate tasks carry no
    /// ordering guarantee, so running, paused, and stopped could apply out of order. The token
    /// check rejects events from an old session, not reordered events of the current one. The
    /// consumer also finishes handling one event, including an `await` such as ending
    /// collection, before it looks at the next.
    @ObservationIgnored private let events: AsyncStream<SessionEvent>.Continuation
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    override init() {
        var continuation: AsyncStream<SessionEvent>.Continuation!
        let stream = AsyncStream<SessionEvent>(bufferingPolicy: .unbounded) { continuation = $0 }
        events = continuation
        super.init()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    deinit {
        events.finish()
        eventTask?.cancel()
    }

    /// Whether the running workout is mirrored to iPhone for its live display.
    private(set) var isMirroring = false

    func start(activity: WatchWorkoutActivity, indoors: Bool, mirrorToPhone: Bool = false) async {
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
            activityTitle = activity.title
            lifecycle.markStarting(operation)
            let date = Date.now
            session.startActivity(with: date)
            guard let builder else { return }
            try await builder.beginCollection(at: date)
            guard self.session === session else { return }
            lifecycle.markCollecting(operation, paused: session.state == .paused)
            if mirrorToPhone { await startMirroring(session) }
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
            }?.title ?? String(localized: "workout.activity.recovered", defaultValue: "Recovered workout", comment: "Watch workout type shown for a workout the system restarted the app into")
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

    /// Mirrors the session to the paired iPhone, which shows its heart rate beside other
    /// devices while the workout runs (improvement 72). A failure leaves the workout itself
    /// untouched: mirroring is a display, not part of recording.
    private func startMirroring(_ session: HKWorkoutSession) async {
        do {
            try await session.startMirroringToCompanionDevice()
            guard self.session === session else { return }
            isMirroring = true
            sendMirrorUpdate()
        } catch {
            isMirroring = false
        }
    }

    /// Sends the latest heart rate to the mirrored session on iPhone. Display only there;
    /// the samples themselves reach iPhone through Health after the workout.
    private func sendMirrorUpdate() {
        guard isMirroring, let session else { return }
        let payload = MirroredWorkoutPayload(
            heartRate: heartRate?.value,
            measuredAt: heartRate?.timestamp,
            isPaused: phase == .paused,
            activityTitle: activityTitle
        )
        guard let data = try? payload.encoded() else { return }
        Task { try? await session.sendToRemoteWorkoutSession(data: data) }
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
        isMirroring = false
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
        sendMirrorUpdate()
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

    private func handle(_ event: SessionEvent) async {
        switch event {
        case let .stateChanged(id, toState, date):
            guard session.map(ObjectIdentifier.init) == id else { return }
            // Both guards matter: object identity catches a callback from a different
            // HealthKit object, and the token catches one from a session this manager has
            // already discarded or replaced.
            guard let operation = token, lifecycle.accepts(operation) else { return }
            switch toState {
            case .running:
                lifecycle.applyRunning(operation)
                sendMirrorUpdate()
            case .paused:
                lifecycle.applyPaused(operation)
                sendMirrorUpdate()
            case .stopped, .ended:
                await prepareReview(operation, at: date)
            default: break
            }

        case let .failed(id, detail):
            guard session.map(ObjectIdentifier.init) == id else { return }
            guard let operation = token, lifecycle.accepts(operation) else { return }
            if builder?.startDate != nil, let builder {
                let now = Date.now
                // Collected data survives an interruption, so this becomes a reviewable
                // workout rather than a failed start the user can never save.
                if lifecycle.interrupt(
                    operation,
                    detail: detail,
                    at: now,
                    elapsed: builder.elapsedTime(at: now)
                ) {
                    var failure: String?
                    if !lifecycle.collectionEnded {
                        do { try await builder.endCollection(at: now) }
                        catch { failure = error.localizedDescription }
                    }
                    lifecycle.completeReview(
                        elapsed: failure == nil ? builder.elapsedTime : nil,
                        failure: failure
                    )
                }
            } else {
                failStart(operation, "Workout failed: \(detail)")
            }

        case let .collected(id, sample):
            guard builder.map(ObjectIdentifier.init) == id else { return }
            apply(sample)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        events.yield(.stateChanged(session: ObjectIdentifier(workoutSession), to: toState, date: date))
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        events.yield(.failed(session: ObjectIdentifier(workoutSession), detail: error.localizedDescription))
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        events.yield(.collected(builder: ObjectIdentifier(workoutBuilder), sample: Self.statistics(from: workoutBuilder)))
    }
}
