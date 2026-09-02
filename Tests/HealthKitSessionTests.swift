import Foundation
import HealthKit
import Testing
@testable import HeartSyncChecker

/// Pure decision helpers from `HealthKitManager+Session` — no device / HealthKit sheet required.
@Suite("HealthKit session restore")
struct HealthKitSessionRestoreTests {

    @Test("Unavailable hardware never restores")
    func unavailableHardware() {
        #expect(
            HealthKitManager.sessionRestoreDecision(
                healthDataAvailable: false,
                didCompleteAuthorization: true,
                authorizationRequestUnnecessary: true
            ) == .unavailable
        )
    }

    @Test("HeartSync's own completed-Connect flag restores without a HealthKit sheet")
    func completedFlagRestores() {
        #expect(
            HealthKitManager.sessionRestoreDecision(
                healthDataAvailable: true,
                didCompleteAuthorization: true,
                authorizationRequestUnnecessary: false
            ) == .restore
        )
    }

    @Test("HealthKit reporting the read request unnecessary also restores")
    func requestUnnecessaryRestores() {
        #expect(
            HealthKitManager.sessionRestoreDecision(
                healthDataAvailable: true,
                didCompleteAuthorization: false,
                authorizationRequestUnnecessary: true
            ) == .restore
        )
    }

    @Test("First launch with no prior Connect stays notDetermined")
    func firstLaunchLeavesNotDetermined() {
        #expect(
            HealthKitManager.sessionRestoreDecision(
                healthDataAvailable: true,
                didCompleteAuthorization: false,
                authorizationRequestUnnecessary: false
            ) == .leaveNotDetermined
        )
    }
}

@Suite("HealthKit write authorization satisfaction")
struct HealthKitWriteAuthorizationTests {

    @Test("Empty status list is never satisfied")
    func emptyIsUnsatisfied() {
        #expect(!HealthKitManager.isWriteAuthorizationSatisfied(statuses: []))
    }

    @Test("Every share type must be sharingAuthorized")
    func allMustBeAuthorized() {
        #expect(
            HealthKitManager.isWriteAuthorizationSatisfied(statuses: [
                .sharingAuthorized,
                .sharingAuthorized,
            ])
        )
        #expect(
            !HealthKitManager.isWriteAuthorizationSatisfied(statuses: [
                .sharingAuthorized,
                .sharingDenied,
            ])
        )
        #expect(
            !HealthKitManager.isWriteAuthorizationSatisfied(statuses: [
                .notDetermined,
            ])
        )
    }
}
