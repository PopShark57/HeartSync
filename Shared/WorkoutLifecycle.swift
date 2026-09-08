import Foundation

/// Opaque identity for one attached workout session.
///
/// HealthKit delivers session and builder callbacks asynchronously, so a callback can
/// arrive after the workout it belongs to was discarded, replaced, or failed to start.
/// Every event carries the token it was issued with, and the lifecycle ignores any token
/// that is not the active one. Values are issued in sequence rather than randomly so a
/// transition trace is reproducible in a test.
struct WorkoutSessionToken: Hashable, Sendable {
    fileprivate let value: Int
}

/// The state a recovered session came back in.
enum RecoveredWorkoutState: Equatable, Sendable {
    case running
    case paused
    /// The system relaunched us after the workout had already stopped. It stays reviewable.
    case stopped(at: Date)
    /// Nothing usable came back.
    case unavailable
}

/// What the caller should do to the HealthKit session after a pause/resume request.
enum WorkoutPauseAction: Equatable, Sendable {
    case pause
    case resume
    /// The workout is not collecting, so the tap does nothing. Notably this is what a
    /// double-tap resolves to, rather than a second pause.
    case ignore
}

/// Pure lifecycle rules for a watch workout, with no HealthKit dependency.
///
/// `WatchWorkoutManager` owns the `HKWorkoutSession` and `HKLiveWorkoutBuilder`; this owns
/// the decisions about them — which taps are honoured, which callbacks are stale, when a
/// workout becomes reviewable, and when it may be saved. Splitting them this way is what
/// makes the lifecycle testable: `WatchApp/Sources` is compiled only into the watch app,
/// but `Shared` is compiled into the iPhone app too, so these rules are reachable from the
/// hosted test bundle that CI actually runs.
///
/// It deliberately stores no samples and performs no I/O. The recorded workout lives in
/// HealthKit; this is transient interaction state.
struct WorkoutLifecycle: Equatable, Sendable {
    private(set) var phase: WorkoutPhase = .idle
    private(set) var message: String?
    /// Builder elapsed time captured when collection ended. Excludes paused time, because
    /// that is what HealthKit's builder reports.
    private(set) var finalDuration: TimeInterval = 0
    private(set) var collectionEnded = false
    /// The session whose callbacks are currently authoritative. Nil when nothing is attached.
    private(set) var activeToken: WorkoutSessionToken?

    private var nextTokenValue = 1
    /// Guards re-entrancy while collection is being ended, so a delegate event arriving
    /// mid-teardown cannot start a second review.
    private var isEndingCollection = false

    init() {}

    /// True when `token` is the session this lifecycle is currently listening to.
    ///
    /// A nil token never matches: an event that predates attachment is not authoritative.
    func accepts(_ token: WorkoutSessionToken?) -> Bool {
        guard let token, let activeToken else { return false }
        return token == activeToken
    }

    // MARK: - Start

    /// Honours a Start tap, returning the token for the session about to be created.
    ///
    /// Returns nil when a workout is already starting or collecting, which is how a
    /// double-tap on Start is rejected without creating a second `HKWorkoutSession`.
    mutating func beginStart() -> WorkoutSessionToken? {
        guard phase.canStart, activeToken == nil else { return nil }
        let token = issueToken()
        // Claimed immediately, before any HealthKit object exists, so a failure during
        // authorization is still attributable to this attempt and a second Start tap is
        // rejected by the `activeToken == nil` guard above.
        activeToken = token
        phase = .authorizing
        message = nil
        finalDuration = 0
        collectionEnded = false
        isEndingCollection = false
        return token
    }

    /// Marks the session as created and its collection as begun.
    @discardableResult
    mutating func markCollecting(_ token: WorkoutSessionToken, paused: Bool) -> Bool {
        guard accepts(token), phase == .authorizing || phase == .starting else { return false }
        phase = paused ? .paused : .running
        return true
    }

    /// Moves from authorization into session creation.
    @discardableResult
    mutating func markStarting(_ token: WorkoutSessionToken) -> Bool {
        guard accepts(token), phase == .authorizing else { return false }
        phase = .starting
        return true
    }

    /// A start that never produced a reviewable workout.
    ///
    /// Detaches, so any callback still queued for the failed session is ignored.
    @discardableResult
    mutating func failStart(_ token: WorkoutSessionToken, reason: String) -> Bool {
        guard accepts(token) else { return false }
        activeToken = nil
        collectionEnded = false
        isEndingCollection = false
        finalDuration = 0
        phase = .failed
        message = reason
        return true
    }

    // MARK: - Pause, resume, stop

    func pauseAction() -> WorkoutPauseAction {
        switch phase {
        case .running: .pause
        case .paused:  .resume
        default:       .ignore
        }
    }

    /// Honours a Stop tap. Returns false for a repeat tap, so `stopActivity` is not sent
    /// twice for one workout.
    @discardableResult
    mutating func beginStop() -> Bool {
        guard phase.isCollecting, activeToken != nil else { return false }
        phase = .stopping
        return true
    }

    /// Applies a session state change reported by HealthKit.
    ///
    /// Returns true when the state was applied. A stale token returns false, which is what
    /// stops a paused/running event from a replaced session moving a live workout.
    @discardableResult
    mutating func applyRunning(_ token: WorkoutSessionToken) -> Bool {
        guard accepts(token), phase == .paused else { return false }
        phase = .running
        return true
    }

    @discardableResult
    mutating func applyPaused(_ token: WorkoutSessionToken) -> Bool {
        guard accepts(token), phase == .running else { return false }
        phase = .paused
        return true
    }

    // MARK: - Review

    /// Begins turning a stopped workout into a reviewable one.
    ///
    /// Returns false when review is already under way or already reached, so repeated
    /// stop/end callbacks for one workout cannot end collection twice.
    @discardableResult
    mutating func beginReview(_ token: WorkoutSessionToken, at date: Date, elapsed: TimeInterval) -> Bool {
        guard accepts(token), !isEndingCollection else { return false }
        guard phase != .review, phase != .saving, phase != .saved else { return false }
        isEndingCollection = true
        phase = .stopping
        finalDuration = max(0, elapsed)
        return true
    }

    /// Records that HealthKit has stopped collecting, without choosing a phase.
    ///
    /// Collection ends on two different paths — on the way into review, and during a save
    /// that had to finish it first — and only the caller knows which one it is on.
    mutating func markCollectionEnded(elapsed: TimeInterval? = nil) {
        collectionEnded = true
        if let elapsed { finalDuration = max(0, elapsed) }
    }

    /// Completes the review transition. `failure` records a collection error without
    /// blocking review: the workout is still saveable and Save will retry ending collection.
    mutating func completeReview(elapsed: TimeInterval?, failure: String?) {
        if let elapsed { finalDuration = max(0, elapsed) }
        if let failure {
            message = "Could not finish collecting: \(failure) Save will retry."
        } else {
            collectionEnded = true
        }
        isEndingCollection = false
        phase = .review
    }

    /// An interruption (another workout app, a session error) that still leaves data worth
    /// reviewing rather than a failed start.
    @discardableResult
    mutating func interrupt(_ token: WorkoutSessionToken, detail: String, at date: Date, elapsed: TimeInterval) -> Bool {
        guard accepts(token) else { return false }
        guard beginReview(token, at: date, elapsed: elapsed) else { return false }
        message = "Workout interrupted: \(detail) Review the collected workout before saving."
        return true
    }

    // MARK: - Save and discard

    /// Honours a Save tap. Returns nil while saving, after saving, or outside review — which
    /// is what prevents one workout being written to HealthKit twice.
    mutating func beginSave() -> WorkoutSessionToken? {
        guard phase == .review, let activeToken else { return nil }
        phase = .saving
        message = nil
        return activeToken
    }

    /// A completed save. Detaches: the workout now belongs to HealthKit.
    ///
    /// - Parameter protectedByLock: HealthKit returned no workout object and no error,
    ///   meaning the save succeeded but the result is unreadable until the watch is unlocked.
    mutating func markSaved(protectedByLock: Bool) {
        activeToken = nil
        isEndingCollection = false
        phase = .saved
        message = protectedByLock
            ? "Saved to Apple Health. Unlock your watch to view the workout. Readings reach iPhone after Health syncs."
            : "Saved to Apple Health. Readings appear on iPhone after Health syncs and HeartSync refreshes."
    }

    /// A failed save returns to review so the user can retry or discard. The session stays
    /// attached deliberately: the collected workout is still there to save.
    mutating func markSaveFailed(_ reason: String) {
        guard phase == .saving else { return }
        phase = .review
        message = "Not saved: \(reason) Try Save again, or discard this workout."
    }

    /// Honours a Discard tap. Returns false outside review.
    @discardableResult
    mutating func beginDiscard() -> Bool {
        guard phase == .review else { return false }
        activeToken = nil
        collectionEnded = false
        isEndingCollection = false
        finalDuration = 0
        phase = .idle
        message = "Workout discarded. HealthKit may retain sensor samples Apple Watch collected independently."
        return true
    }

    // MARK: - Recovery

    /// Honours a system relaunch of an active workout. Returns nil when a workout is
    /// already attached, so recovery cannot displace a live session.
    mutating func beginRecovery() -> WorkoutSessionToken? {
        guard activeToken == nil, phase.canStart else { return nil }
        let token = issueToken()
        activeToken = token
        phase = .starting
        message = nil
        finalDuration = 0
        collectionEnded = false
        isEndingCollection = false
        return token
    }

    /// Adopts the recovered session's state.
    mutating func adoptRecovered(
        _ token: WorkoutSessionToken,
        state: RecoveredWorkoutState,
        elapsed: TimeInterval = 0
    ) {
        guard accepts(token) else { return }
        switch state {
        case .running:
            phase = .running
        case .paused:
            phase = .paused
        case .stopped(let date):
            // A workout the system already stopped must still be reviewable, not discarded.
            if beginReview(token, at: date, elapsed: elapsed) {
                completeReview(elapsed: elapsed, failure: nil)
            }
        case .unavailable:
            failStart(token, reason: "The previous workout is no longer active.")
        }
    }

    // MARK: - Helpers

    private mutating func issueToken() -> WorkoutSessionToken {
        let token = WorkoutSessionToken(value: nextTokenValue)
        nextTokenValue += 1
        return token
    }
}
