import Foundation
import HealthKit

extension HealthKitManager {

    /// Pure restore decision so cold-start session recovery can be unit-tested without a device.
    enum SessionRestoreDecision: Equatable, Sendable {
        case unavailable
        case restore
        case leaveNotDetermined
    }

    /// Outcome of asking for HealthKit share types when mirroring is turned on.
    enum WriteAuthorizationOutcome: Equatable, Sendable {
        case granted
        case denied
        case unavailable
    }

    /// UserDefaults key recording that the user finished HeartSync's Health connect flow.
    ///
    /// HealthKit does not restore a UI-facing "authorized" state across launches, so without
    /// this flag (paired with `statusForAuthorizationRequest`) every cold start would look
    /// like a first-time Connect even when the sheet was already completed.
    nonisolated static let didCompleteAuthorizationKey = "hk.didCompleteAuthorization"

    /// Decides whether a cold launch should restore `.authorized` without showing the sheet.
    ///
    /// `didCompleteAuthorization` is HeartSync's own record that Connect finished.
    /// `authorizationRequestUnnecessary` comes from HealthKit's
    /// `statusForAuthorizationRequest` for **read** types only (empty share set), so a user
    /// who connected without mirroring still restores, and turning mirroring on later can
    /// still prompt for write types.
    nonisolated static func sessionRestoreDecision(
        healthDataAvailable: Bool,
        didCompleteAuthorization: Bool,
        authorizationRequestUnnecessary: Bool
    ) -> SessionRestoreDecision {
        guard healthDataAvailable else { return .unavailable }
        if didCompleteAuthorization || authorizationRequestUnnecessary {
            return .restore
        }
        return .leaveNotDetermined
    }

    /// True when every share type HeartSync mirrors reports `.sharingAuthorized`.
    nonisolated static func isWriteAuthorizationSatisfied(
        statuses: [HKAuthorizationStatus]
    ) -> Bool {
        !statuses.isEmpty && statuses.allSatisfy { $0 == .sharingAuthorized }
    }

    private var didCompleteAuthorization: Bool {
        get { UserDefaults.standard.bool(forKey: Self.didCompleteAuthorizationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.didCompleteAuthorizationKey) }
    }

    func markAuthorizationCompleted() {
        didCompleteAuthorization = true
    }

    /// Restores a previously completed HealthKit session without re-prompting.
    ///
    /// `availability` starts as `.notDetermined` every cold launch. Without this restore,
    /// Devices offers "Connect Apple Health" again and `AppModel.start` skips `syncAll`
    /// even though the user already finished the sheet. Completing the sheet still does
    /// not mean every read type was granted \u{2014} that honesty stays in `Availability.title`.
    func restoreSessionIfNeeded() async {
        let healthAvailable = HKHealthStore.isHealthDataAvailable()
        var requestUnnecessary = false
        if healthAvailable {
            do {
                // Read types only: share types are requested separately when mirroring is
                // enabled, and must not block restoring a read-only Connect session.
                let status = try await healthStore.statusForAuthorizationRequest(
                    toShare: [],
                    read: Self.readTypes
                )
                requestUnnecessary = (status == .unnecessary)
            } catch {
                logger.debug(
                    "Authorization request status unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        switch Self.sessionRestoreDecision(
            healthDataAvailable: healthAvailable,
            didCompleteAuthorization: didCompleteAuthorization,
            authorizationRequestUnnecessary: requestUnnecessary
        ) {
        case .unavailable:
            availability = .unavailable
        case .leaveNotDetermined:
            break
        case .restore:
            availability = .authorized
            markAuthorizationCompleted()
            lastError = nil
            await startObserving()
        }
    }

    /// Requests HealthKit share types when the user turns on Bluetooth\u{2192}Health mirroring.
    ///
    /// Connect may have requested reads only. Share authorization is asked here so
    /// `write(_:)` does not fail quietly for types that were never prompted. Surfaces
    /// granted / denied / unavailable so Settings can show an alert instead of a no-op.
    func requestWriteAuthorization() async -> WriteAuthorizationOutcome {
        guard HKHealthStore.isHealthDataAvailable() else {
            availability = .unavailable
            return .unavailable
        }

        let currentStatuses = Self.shareTypes.map { healthStore.authorizationStatus(for: $0) }
        if Self.isWriteAuthorizationSatisfied(statuses: currentStatuses) {
            if availability != .authorized {
                availability = .authorized
                markAuthorizationCompleted()
                lastError = nil
                await startObserving()
                await syncAll()
            }
            return .granted
        }

        await requestAuthorization(allowWriting: true)
        guard availability != .unavailable else { return .unavailable }

        let afterStatuses = Self.shareTypes.map { healthStore.authorizationStatus(for: $0) }
        if Self.isWriteAuthorizationSatisfied(statuses: afterStatuses) {
            lastError = nil
            return .granted
        }

        lastError = String(
            localized: "healthKit.writeAuthorization.denied",
            defaultValue: "Health write access was not granted. Enable it in Settings \u{2192} Health \u{2192} Data Access & Devices.",
            comment: "Shown when mirroring is enabled but the user did not grant HealthKit share types"
        )
        return .denied
    }
}
