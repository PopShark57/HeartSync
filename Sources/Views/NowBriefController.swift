import Foundation
import Observation

/// When one Now screen asks the on-device model for a brief, and what it last chose.
///
/// The screen reloads every second while a strap streams, and its facts change with it. A
/// request is therefore never tied to the view task that started it: the model call runs in
/// a task of its own, so a newer key cancels only the wait before a call, never the call, and
/// its selection is kept, because the text is rendered from the current facts when shown.
/// Tying the call to the view task let a 1 Hz strap cancel every call before the model
/// answered, and the throttle then held the next one back, so no brief ever appeared.
///
/// Requests are at most one every `interval`, unless the person asks (`requestRefresh`).
@MainActor @Observable
final class NowBriefController {
    /// What a screen keys its brief task on: the coarse facts, whether the model can be asked,
    /// a renewal period, and the person's explicit requests.
    struct Request: Hashable {
        var key: String?
        var unavailability: NowBriefGenerator.Unavailability?
        var renewal: Int
        var refreshToken: Int
    }

    /// Why there is no brief, when the screen should say so.
    enum Status: Hashable {
        case selecting
        case noBrief
        case turnedOff
        case notReady
    }

    /// The shortest time between two requests the person did not ask for.
    static let interval: TimeInterval = 180
    /// A selection whose facts stay the same is asked for again before
    /// `NowBriefDisplay.lifetime` ends it.
    static let renewalInterval: TimeInterval = 10 * 60

    private(set) var display: NowBriefDisplay?
    /// The last request's outcome, for the status line when there is no brief.
    private(set) var lastOutcome: NowBriefGenerator.Outcome?
    private(set) var isGenerating = false
    private(set) var refreshToken = 0

    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var inFlight: Task<NowBriefGenerator.Outcome, Never>?
    private let generate: @Sendable (NowBriefFacts) async -> NowBriefGenerator.Outcome
    private let clock: () -> Date

    init(
        generate: @escaping @Sendable (NowBriefFacts) async -> NowBriefGenerator.Outcome = { await NowBriefGenerator.generate($0) },
        clock: @escaping () -> Date = { .now }
    ) {
        self.generate = generate
        self.clock = clock
    }

    func request(facts: NowBriefFacts?, unavailability: NowBriefGenerator.Unavailability?, now: Date) -> Request {
        Request(
            key: facts?.key,
            unavailability: unavailability,
            renewal: Int(now.timeIntervalSince1970 / Self.renewalInterval),
            refreshToken: refreshToken
        )
    }

    /// Asks again as soon as the model is free, bypassing the throttle: pull to refresh,
    /// Refresh, and Regenerate.
    func requestRefresh() {
        lastAttempt = nil
        refreshToken &+= 1
    }

    /// Seconds before the next request may start.
    func delay(at now: Date) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, Self.interval - now.timeIntervalSince(lastAttempt))
    }

    /// Run from the screen's `.task(id: request(...))`.
    func refresh(_ facts: NowBriefFacts?, unavailability: NowBriefGenerator.Unavailability?) async {
        guard let facts, unavailability == nil else { return }
        // One model call at a time: a newer key waits for it rather than starting another.
        if let inFlight { _ = await inFlight.value }
        let wait = delay(at: clock())
        if wait > 0 {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        }
        guard !Task.isCancelled, inFlight == nil else { return }
        lastAttempt = clock()
        isGenerating = true
        let generate = self.generate
        let call = Task { await generate(facts) }
        inFlight = call
        // Awaiting the call's value does not pass this task's cancellation on to it.
        let outcome = await call.value
        inFlight = nil
        isGenerating = false
        lastOutcome = outcome
        if case .selected(let kinds) = outcome {
            display = NowBriefDisplay(kinds: kinds, generatedAt: clock())
        }
    }

    /// What to say when there is no brief to show; nil says nothing (no Apple Intelligence on
    /// this device or OS, or nothing asked yet).
    static func status(
        unavailability: NowBriefGenerator.Unavailability?,
        isGenerating: Bool,
        lastOutcome: NowBriefGenerator.Outcome?
    ) -> Status? {
        switch unavailability {
        case .turnedOff: return .turnedOff
        case .notReady: return .notReady
        case .notSupported: return nil
        case nil: break
        }
        if isGenerating { return .selecting }
        if lastOutcome == .noBrief { return .noBrief }
        return nil
    }
}
