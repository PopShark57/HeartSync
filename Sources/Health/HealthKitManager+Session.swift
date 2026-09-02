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
    ///
    /// Note: `.unnecessary` means the user already answered the sheet (grant or deny). That
    /// matches HeartSync's `.authorized` meaning — sheet completed — not "every read granted".
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

    private static var didCompleteAuthorizationFlag: Bool {
        get { UserDefaults.standard.bool(forKey: didCompleteAuthorizationKey) }
        set { UserDefaults.standard.set(newValue, forKey: didCompleteAuthorizationKey) }
    }

    /// Restores a previously completed HealthKit session without re-prompting.
    ///
    /// `availability` starts as `.notDetermined` every cold launch. Without this restore,
    /// Devices offers "Connect Apple Health" again and `AppModel.start` skips `syncAll`
    /// even though the user already finished the sheet. Completing the sheet still does
    /// not mean every read type was granted \u{2014} that honesty stays in `Availability.title`.
    ///
    /// Implementation reuses `requestAuthorization(allowWriting: false)`, which (when the
    /// read request is already determined) does not present the sheet again, and already
    /// owns setting `.authorized`, installing observers, and syncing.
    func restoreSessionIfNeeded() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        var requestUnnecessary = false
        do {
            // Local store: avoids needing access to the manager's private `healthStore`.
            // Read types only so a prior read-only Connect still restores; share types are
            // requested separately when mirroring is enabled.
            let status = try await HKHealthStore().statusForAuthorizationRequest(
                toShare: [],
                read: Self.readTypes
            )
            requestUnnecessary = (status == .unnecessary)
        } catch {
            // Status probe failed; fall back to the persisted Connect flag alone.
        }

        let decision = Self.sessionRestoreDecision(
            healthDataAvailable: true,
            didCompleteAuthorization: Self.didCompleteAuthorizationFlag,
            authorizationRequestUnnecessary: requestUnnecessary
        )
        guard decision == .restore else { return }

        await requestAuthorization(allowWriting: false)
        Self.didCompleteAuthorizationFlag = true
    }

    /// Requests HealthKit share types when the user turns on Bluetooth\u{2192}Health mirroring.
    ///
    /// Connect may have requested reads only. Share authorization is asked here so
    /// `write(_:)` does not fail quietly for types that were never prompted. Surfaces
    /// granted / denied / unavailable so Settings can show an alert instead of a no-op.
    func requestWriteAuthorization() async -> WriteAuthorizationOutcome {
        guard HKHealthStore.isHealthDataAvailable() else {
            return .unavailable
        }

        let probe = HKHealthStore()
        let currentStatuses = Self.shareTypes.map { probe.authorizationStatus(for: $0) }
        if Self.isWriteAuthorizationSatisfied(statuses: currentStatuses) {
            if availability != .authorized {
                await requestAuthorization(allowWriting: true)
            }
            Self.didCompleteAuthorizationFlag = true
            return .granted
        }

        await requestAuthorization(allowWriting: true)

        let afterStatuses = Self.shareTypes.map { probe.authorizationStatus(for: $0) }
        if Self.isWriteAuthorizationSatisfied(statuses: afterStatuses) {
            Self.didCompleteAuthorizationFlag = true
            return .granted
        }
        return .denied
    }
}
