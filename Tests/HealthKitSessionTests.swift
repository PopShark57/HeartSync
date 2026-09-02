import Foundation
import HealthKit
import Testing
@testable import HeartSyncChecker

@Suite("HealthKit session restore decision")
struct HealthKitSessionRestoreDecisionTests {

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

    @Test("A completed Connect flag restores without re-prompting")
    func completedFlagRestores() {
        #expect(
            HealthKitManager.sessionRestoreDecision(
                healthDataAvailable: true,
                didCompleteAuthorization: true,
                authorizationRequestUnnecessary: false
            ) == .restore
        )
    }

    @Test("HealthKit reporting the request is unnecessary restores upgrades without a flag")
    func requestStatusRestoresExistingUsers() {
        #expect(
            HealthKitManager.sessionRestoreDecision(
                healthDataAvailable: true,
                didCompleteAuthorization: false,
                authorizationRequestUnnecessary: true
            ) == .restore
        )
    }

    @Test("A fresh install stays notDetermined until the user connects")
    func freshInstallStaysNotDetermined() {
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

    @Test("Every share type must be sharingAuthorized")
    func allShareTypesRequired() {
        #expect(
            HealthKitManager.isWriteAuthorizationSatisfied(
                statuses: [.sharingAuthorized, .sharingAuthorized]
            )
        )
        #expect(
            !HealthKitManager.isWriteAuthorizationSatisfied(
                statuses: [.sharingAuthorized, .sharingDenied]
            )
        )
        #expect(
            !HealthKitManager.isWriteAuthorizationSatisfied(
                statuses: [.notDetermined, .notDetermined]
            )
        )
        #expect(!HealthKitManager.isWriteAuthorizationSatisfied(statuses: []))
    }
}
