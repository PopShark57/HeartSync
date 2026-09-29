import Foundation
import Testing
@testable import HeartSyncChecker

/// Watch workout lifecycle regressions (improvement 25).
///
/// These exercise `WorkoutLifecycle`, the transition rules `WatchWorkoutManager` drives.
/// They are deterministic and hosted in the iOS bundle CI runs, because `WatchApp/Sources`
/// is compiled only into the watch app. They cover which taps and callbacks are honoured;
/// they do not and cannot prove that HealthKit saves a workout on real hardware. That
/// remains a physical-device check.
@Suite("Watch workout lifecycle")
struct WorkoutLifecycleTests {

    /// Drives a lifecycle to a collecting workout, returning it and its token.
    private func collecting() -> (WorkoutLifecycle, WorkoutSessionToken) {
        var lifecycle = WorkoutLifecycle()
        let token = lifecycle.beginStart()!
        lifecycle.markStarting(token)
        lifecycle.markCollecting(token, paused: false)
        return (lifecycle, token)
    }

    /// Drives a lifecycle to a reviewable workout.
    private func reviewing() -> (WorkoutLifecycle, WorkoutSessionToken) {
        var (lifecycle, token) = collecting()
        let result1 = lifecycle.beginStop()
        #expect(result1)
        let result2 = lifecycle.beginReview(token, at: .now, elapsed: 120)
        #expect(result2)
        lifecycle.completeReview(elapsed: 120, failure: nil)
        return (lifecycle, token)
    }

    // MARK: - Duplicate taps

    @Test("A second Start tap does not begin a second workout")
    func duplicateStartIsRejected() {
        var lifecycle = WorkoutLifecycle()
        let first = lifecycle.beginStart()
        #expect(first != nil)
        #expect(lifecycle.phase == .authorizing)

        let result3 = lifecycle.beginStart() == nil
        #expect(result3)
        #expect(lifecycle.phase == .authorizing)

        // Still rejected once the workout is actually collecting.
        lifecycle.markStarting(first!)
        lifecycle.markCollecting(first!, paused: false)
        let result4 = lifecycle.beginStart() == nil
        #expect(result4)
        #expect(lifecycle.phase == .running)
    }

    @Test("A second Stop tap does not stop the workout twice")
    func duplicateStopIsRejected() {
        var (lifecycle, _) = collecting()
        let result5 = lifecycle.beginStop()
        #expect(result5)
        #expect(lifecycle.phase == .stopping)
        let result6 = lifecycle.beginStop() == false
        #expect(result6)
        #expect(lifecycle.phase == .stopping)
    }

    @Test("Pause and resume alternate, and do nothing when not collecting")
    func pauseResumeAlternates() {
        var (lifecycle, token) = collecting()
        #expect(lifecycle.pauseAction() == .pause)
        let result7 = lifecycle.applyPaused(token)
        #expect(result7)
        #expect(lifecycle.phase == .paused)

        #expect(lifecycle.pauseAction() == .resume)
        let result8 = lifecycle.applyRunning(token)
        #expect(result8)
        #expect(lifecycle.phase == .running)

        // A repeated paused event for an already-paused workout changes nothing.
        let result9 = lifecycle.applyPaused(token)
        #expect(result9)
        let result10 = lifecycle.applyPaused(token) == false
        #expect(result10)
        #expect(lifecycle.phase == .paused)

        let (review, _) = reviewing()
        #expect(review.pauseAction() == .ignore)
    }

    // MARK: - Stale callbacks

    @Test("A callback from a discarded session cannot revive it")
    func lateCallbackAfterDiscardIsIgnored() {
        var (lifecycle, token) = reviewing()
        let result11 = lifecycle.beginDiscard()
        #expect(result11)
        #expect(lifecycle.phase == .idle)

        // Everything the old session might still deliver is refused.
        #expect(lifecycle.accepts(token) == false)
        let result12 = lifecycle.applyRunning(token) == false
        #expect(result12)
        let result13 = lifecycle.applyPaused(token) == false
        #expect(result13)
        let result14 = lifecycle.beginReview(token, at: .now, elapsed: 999) == false
        #expect(result14)
        let result15 = lifecycle.failStart(token, reason: "late") == false
        #expect(result15)
        #expect(lifecycle.phase == .idle)
    }

    @Test("A callback from a replaced session cannot move the current one")
    func lateCallbackFromReplacedSessionIsIgnored() {
        var (lifecycle, old) = reviewing()
        let result16 = lifecycle.beginDiscard()
        #expect(result16)

        let new = lifecycle.beginStart()!
        lifecycle.markStarting(new)
        lifecycle.markCollecting(new, paused: false)
        #expect(lifecycle.phase == .running)

        // The old session's stop arrives after a new workout has started.
        let result17 = lifecycle.beginReview(old, at: .now, elapsed: 5) == false
        #expect(result17)
        let result18 = lifecycle.applyPaused(old) == false
        #expect(result18)
        #expect(lifecycle.phase == .running)
        // The new session still works.
        let result19 = lifecycle.applyPaused(new)
        #expect(result19)
        #expect(lifecycle.phase == .paused)
    }

    @Test("Events delivered out of order cannot move a reviewed workout back")
    func outOfOrderEventsAreRefused() {
        // WatchWorkoutManager applies delegate events one at a time, in the order HealthKit
        // called them. If one still arrived late, the lifecycle refuses to be dragged back.
        var (lifecycle, token) = collecting()
        let paused = lifecycle.applyPaused(token)
        let stopped = lifecycle.beginStop()
        let reviewing = lifecycle.beginReview(token, at: .now, elapsed: 60)
        #expect(paused)
        #expect(stopped)
        #expect(reviewing)
        lifecycle.completeReview(elapsed: 60, failure: nil)
        #expect(lifecycle.phase == .review)

        // A resume that HealthKit sent before the stop, applied after it.
        let lateResume = lifecycle.applyRunning(token)
        // A pause that arrives after the workout ended.
        let latePause = lifecycle.applyPaused(token)
        // A second "ended" for the same workout.
        let secondEnd = lifecycle.beginReview(token, at: .now, elapsed: 9_999)
        #expect(!lateResume)
        #expect(!latePause)
        #expect(!secondEnd)
        #expect(lifecycle.phase == .review)
        #expect(lifecycle.finalDuration == 60)
    }

    @Test("A resume applied before its pause changes nothing, and the pause still lands")
    func resumeBeforePauseIsHarmless() {
        var (lifecycle, token) = collecting()
        // Delivered as resume, then pause: the resume has nothing to resume.
        let earlyResume = lifecycle.applyRunning(token)
        #expect(!earlyResume)
        #expect(lifecycle.phase == .running)
        let pause = lifecycle.applyPaused(token)
        #expect(pause)
        #expect(lifecycle.phase == .paused)
    }

    @Test("A callback from a failed start cannot resurrect the workout")
    func lateCallbackAfterFailedStartIsIgnored() {
        var lifecycle = WorkoutLifecycle()
        let token = lifecycle.beginStart()!
        let result20 = lifecycle.failStart(token, reason: "Denied")
        #expect(result20)
        #expect(lifecycle.phase == .failed)
        #expect(lifecycle.message == "Denied")

        let result21 = lifecycle.markCollecting(token, paused: false) == false
        #expect(result21)
        let result22 = lifecycle.beginReview(token, at: .now, elapsed: 10) == false
        #expect(result22)
        #expect(lifecycle.phase == .failed)
        // A failed start is a state the user can start again from.
        #expect(lifecycle.phase.canStart)
        let result23 = lifecycle.beginStart() != nil
        #expect(result23)
    }

    // MARK: - Review

    @Test("A stopped workout stays reviewable and repeated end events do not re-end it")
    func stoppedWorkoutStaysReviewable() {
        var (lifecycle, token) = collecting()
        let result24 = lifecycle.beginStop()
        #expect(result24)
        let result25 = lifecycle.beginReview(token, at: .now, elapsed: 90)
        #expect(result25)
        lifecycle.completeReview(elapsed: 90, failure: nil)

        #expect(lifecycle.phase == .review)
        #expect(lifecycle.finalDuration == 90)
        #expect(lifecycle.collectionEnded)

        // A duplicate stopped/ended callback must not restart the teardown.
        let result26 = lifecycle.beginReview(token, at: .now, elapsed: 4_000) == false
        #expect(result26)
        #expect(lifecycle.phase == .review)
        #expect(lifecycle.finalDuration == 90)
    }

    @Test("Interrupted collection becomes a reviewable workout, not a failed start")
    func interruptionLeavesAReviewableWorkout() {
        var (lifecycle, token) = collecting()
        let result27 = lifecycle.interrupt(token, detail: "Another app started a workout.", at: .now, elapsed: 45)
        #expect(result27)
        lifecycle.completeReview(elapsed: 45, failure: nil)

        #expect(lifecycle.phase == .review)
        #expect(lifecycle.finalDuration == 45)
        #expect(lifecycle.message?.contains("interrupted") == true)
        // The collected workout is still saveable.
        let result28 = lifecycle.beginSave() != nil
        #expect(result28)
    }

    @Test("A failure while ending collection still reaches review and says Save will retry")
    func endCollectionFailureStillReachesReview() {
        var (lifecycle, token) = collecting()
        let result29 = lifecycle.beginReview(token, at: .now, elapsed: 30)
        #expect(result29)
        lifecycle.completeReview(elapsed: nil, failure: "disk busy")

        #expect(lifecycle.phase == .review)
        // Collection did NOT end, so save must retry it rather than assume it is done.
        #expect(lifecycle.collectionEnded == false)
        #expect(lifecycle.message?.contains("Save will retry") == true)
    }

    // MARK: - Save and discard

    @Test("Save failure returns to review, keeps the session, and a retry can succeed")
    func saveFailureAllowsRetry() {
        var (lifecycle, _) = reviewing()

        let result30 = lifecycle.beginSave() != nil
        #expect(result30)
        #expect(lifecycle.phase == .saving)
        lifecycle.markSaveFailed("Health is busy.")

        #expect(lifecycle.phase == .review)
        #expect(lifecycle.message?.contains("Try Save again") == true)
        // The workout is still attached, so it can still be saved.
        #expect(lifecycle.activeToken != nil)

        let result31 = lifecycle.beginSave() != nil
        #expect(result31)
        lifecycle.markSaved(protectedByLock: false)
        #expect(lifecycle.phase == .saved)
    }

    @Test("One workout cannot be saved twice")
    func repeatedSaveCannotWriteTwice() {
        var (lifecycle, _) = reviewing()

        let result32 = lifecycle.beginSave() != nil
        #expect(result32)
        // A second tap while the first save is in flight is refused.
        let result33 = lifecycle.beginSave() == nil
        #expect(result33)

        lifecycle.markSaved(protectedByLock: false)
        // And after it completes, there is nothing left to save.
        let result34 = lifecycle.beginSave() == nil
        #expect(result34)
        #expect(lifecycle.phase == .saved)
        #expect(lifecycle.activeToken == nil)
    }

    @Test("A locked watch reports a successful save honestly")
    func lockedSaveIsStillASuccess() {
        var (lifecycle, _) = reviewing()
        let result35 = lifecycle.beginSave() != nil
        #expect(result35)
        lifecycle.markSaved(protectedByLock: true)

        #expect(lifecycle.phase == .saved)
        #expect(lifecycle.message?.contains("Unlock your watch") == true)
    }

    @Test("Discard only works from review, and says what it does not promise")
    func discardOnlyFromReview() {
        var (collectingLifecycle, _) = collecting()
        let result36 = collectingLifecycle.beginDiscard() == false
        #expect(result36)
        #expect(collectingLifecycle.phase == .running)

        var (lifecycle, _) = reviewing()
        let result37 = lifecycle.beginDiscard()
        #expect(result37)
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.finalDuration == 0)
        // Discarding our workout does not delete what Apple Watch collected on its own.
        #expect(lifecycle.message?.contains("may retain sensor samples") == true)
    }

    // MARK: - Recovery

    @Test("A recovered running or paused session resumes in that state")
    func recoveryAdoptsRunningAndPaused() {
        for state in [RecoveredWorkoutState.running, .paused] {
            var lifecycle = WorkoutLifecycle()
            let token = lifecycle.beginRecovery()!
            #expect(lifecycle.phase == .starting)
            lifecycle.adoptRecovered(token, state: state)
            #expect(lifecycle.phase == (state == .running ? .running : .paused))
        }
    }

    @Test("A session recovered after it stopped is reviewable, not discarded")
    func recoveredStoppedSessionIsReviewable() {
        var lifecycle = WorkoutLifecycle()
        let token = lifecycle.beginRecovery()!
        lifecycle.adoptRecovered(token, state: .stopped(at: .now), elapsed: 300)

        #expect(lifecycle.phase == .review)
        #expect(lifecycle.finalDuration == 300)
        let result38 = lifecycle.beginSave() != nil
        #expect(result38)
    }

    @Test("Recovery cannot displace a workout that is already running")
    func recoveryDoesNotDisplaceALiveWorkout() {
        var (lifecycle, _) = collecting()
        let result39 = lifecycle.beginRecovery() == nil
        #expect(result39)
        #expect(lifecycle.phase == .running)
    }

    @Test("An unavailable recovery fails cleanly and can be started again")
    func unavailableRecoveryFailsCleanly() {
        var lifecycle = WorkoutLifecycle()
        let token = lifecycle.beginRecovery()!
        lifecycle.adoptRecovered(token, state: .unavailable)

        #expect(lifecycle.phase == .failed)
        #expect(lifecycle.activeToken == nil)
        let result40 = lifecycle.beginStart() != nil
        #expect(result40)
    }
}
