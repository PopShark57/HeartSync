import Foundation

/// How each transport's part of a wrist sync-all went, read from the state its manager
/// already publishes after a sync. Kept apart from the managers so the rules can be tested
/// without HealthKit or the network.
enum WatchSyncOutcomes {

    /// A drain that ended before `since` belongs to an earlier request; this one did not
    /// run (for example, a data reset was in progress), so it is reported as failed.
    static func healthKit(_ summary: HealthKitManager.HealthKitSyncSummary?, since: Date) -> WatchSyncReport.Outcome {
        guard let summary, summary.attemptedAt >= since else { return .failed }
        switch summary.outcome {
        case .complete: return .synced
        case .partial, .permissionUnknown, .budgetDeferred: return .partial
        case .failed: return .failed
        }
    }

    /// A cycle counts only if it committed at or after `since`. One that met a rate limit
    /// may still have committed what it fetched first, which is partial.
    static func oura(
        committedAt: Date?,
        issueCount: Int,
        rateLimitedUntil: Date?,
        since: Date,
        now: Date
    ) -> WatchSyncReport.Outcome {
        let limited = rateLimitedUntil.map { $0 > now } ?? false
        guard let committedAt, committedAt >= since else {
            return limited ? .rateLimited : .failed
        }
        return issueCount == 0 && !limited ? .synced : .partial
    }
}

/// The report a running sync-all fills in step by step, so a reply sent at the deadline
/// says which transports had finished.
@MainActor
final class WatchSyncProgress {
    var report: WatchSyncReport
    var isFinished = false

    init(_ report: WatchSyncReport) {
        self.report = report
    }
}

/// Resumes a wait exactly once, from whichever of several paths gets there first.
@MainActor
final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
