import Foundation
import HealthKit

/// Background delivery through `HKObserverQuery` (improvement 53).
///
/// `enableBackgroundDelivery` wakes the app for new samples only if an observer query is
/// registered at launch, and HealthKit stops waking it after the app fails to call an
/// update's completion handler three times. The anchored queries HeartSync streams with in
/// the foreground have no completion handler, so they could never satisfy that contract.
/// These queries exist for the wake-up; the anchored drain does the reading.
extension HealthKitManager {

    /// Longest a background update waits for startup (history loaded, Health session
    /// restored) before it answers HealthKit without draining. The next update, or the next
    /// foreground sync, resumes from the committed anchor, so nothing is lost by giving up.
    nonisolated static let backgroundStartupWait: TimeInterval = 20

    /// Registers one observer query per type, at launch. Only once the user has finished
    /// Connect before: an observer query for types never authorised has nothing to deliver.
    func registerBackgroundObservers() {
        guard HKHealthStore.isHealthDataAvailable(),
              backgroundObserverQueries.isEmpty,
              UserDefaults.standard.bool(forKey: Self.didCompleteAuthorizationKey)
        else { return }
        for mapping in Self.mappings {
            guard let type = mapping.quantityType else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                // HealthKit's own queue. The completion handler must be called exactly once,
                // whatever happens, so it is handed to the main actor as an opaque value.
                nonisolated(unsafe) let complete = completion
                guard error == nil else {
                    complete()
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.handleBackgroundUpdate()
                    complete()
                }
            }
            backgroundObserverQueries.append(query)
            healthStore.execute(query)
        }
    }

    /// Drains new samples for a background wake-up, then returns so the caller can call
    /// HealthKit's completion handler.
    ///
    /// While the anchored observer queries are installed they already deliver every change,
    /// and a second drain would only race their anchors, so there is nothing to do. Otherwise
    /// (a background relaunch, before startup has restored the session) this waits for
    /// startup and runs the same finite drain a foreground sync does, which joins one already
    /// running rather than starting another.
    func handleBackgroundUpdate() async {
        guard !isObservingInForeground else { return }
        let deadline = Date.now.addingTimeInterval(Self.backgroundStartupWait)
        while !isReadyForBackgroundDrain {
            guard Date.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !isObservingInForeground else { return }
        await syncAll()
    }
}
