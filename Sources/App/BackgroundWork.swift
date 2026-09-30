import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps a piece of work alive across the scene moving to the background.
///
/// Prune, compaction, and the write-ahead-log checkpoint are the work this exists for: a
/// process suspended halfway through leaves them undone until the next launch. iOS grants
/// only a short grace period, and the expiration handler ends the assertion so a task that
/// overruns is suspended rather than terminated. The stress index's background passes use it
/// too, so a pass started while the app is woken for a reading can finish and commit.
@MainActor
enum BackgroundWork {
    static func perform(named name: String, _ work: () async -> Void) async {
        #if canImport(UIKit) && !os(watchOS)
        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in assertion.end() }
        }
        await work()
        assertion.end()
        #else
        await work()
        #endif
    }

    /// Takes the assertion now, before `work` is scheduled, and runs `work` in a task that
    /// ends it.
    ///
    /// For work started from a callback that iOS may suspend the process after returning
    /// from, such as a Bluetooth notification or a HealthKit background update whose
    /// completion handler is about to be called: taken inside the task instead, the
    /// assertion could come too late.
    static func start(
        named name: String,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        #if canImport(UIKit) && !os(watchOS)
        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in assertion.end() }
        }
        return Task { @MainActor in
            await work()
            assertion.end()
        }
        #else
        return Task { @MainActor in await work() }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    private final class Assertion {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
    #endif
}
