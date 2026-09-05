import Foundation
import Observation
import WatchConnectivity

/// WatchConnectivity schedules the latest context for delivery even when the counterpart
/// is unreachable. Immediate messages are only a refresh request; health history is not
/// duplicated over this channel. Delegate callbacks extract Sendable values before hopping.
@MainActor
@Observable
final class CompanionSession: NSObject, WCSessionDelegate {
    private var inbox = WatchSnapshotInbox()
    var snapshot: WatchSnapshot? { inbox.snapshot }
    private(set) var isReachable = false
    private(set) var isInstalled = false
    private(set) var isRequesting = false
    private(set) var status = "Connecting to iPhone…"

    @ObservationIgnored var onRefresh: (@MainActor () -> Void)?
    @ObservationIgnored var onActivation: (@MainActor () -> Void)?
    @ObservationIgnored var onBackgroundReady: (@MainActor () -> Void)?
    @ObservationIgnored var onSnapshotReceived: (@MainActor (WatchSnapshot) -> Void)?
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var requestTimeout: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: Date?
    @ObservationIgnored private var contentObservation: NSKeyValueObservation?

    func start() {
        guard session == nil else {
            resume()
            return
        }
        guard WCSession.isSupported() else {
            status = "Companion sync is unavailable on this device."
            return
        }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        #if os(watchOS)
        contentObservation = session.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.completeBackgroundDeliveryIfReady() }
        }
        if let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data {
            receive(data)
        }
        #endif
        session.activate()
    }

    func resume() {
        if let session, session.activationState == .notActivated { session.activate() }
        updateConnection()
    }

    func updateConnection() {
        guard let session else { return }
        isReachable = session.activationState == .activated && session.isReachable
        #if os(iOS)
        isInstalled = session.isPaired && session.isWatchAppInstalled
        #else
        isInstalled = session.isCompanionAppInstalled
        #endif
        if !isInstalled {
            status = "Install HeartSync on the paired device."
        } else if isReachable {
            status = "iPhone available"
        } else {
            status = "Open HeartSync on iPhone to refresh."
        }
    }

    #if os(iOS)
    func publish(_ snapshot: WatchSnapshot) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext([WatchSnapshot.contextKey: try snapshot.encoded()])
        } catch {
            status = "Companion update could not be queued."
        }
    }
    #endif

    #if os(watchOS)
    func completeBackgroundDeliveryIfReady() {
        guard let session, session.activationState == .activated, !session.hasContentPending else { return }
        // Read the persisted context before releasing background time, even if a queued
        // MainActor delegate hop has not yet adopted this latest delivery.
        if let data = session.receivedApplicationContext[WatchSnapshot.contextKey] as? Data {
            receive(data)
        }
        onBackgroundReady?()
    }

    func requestRefresh() {
        updateConnection()
        guard let session, isReachable, !isRequesting else { return }
        isRequesting = true
        status = "Requesting iPhone update…"
        requestTimeout?.cancel()
        requestTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self else { return }
            self.isRequesting = false
            self.status = "No update yet. Open HeartSync on iPhone and try again."
        }
        session.sendMessage([WatchSnapshot.refreshKey: true], replyHandler: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestTimeout?.cancel()
                self?.isRequesting = false
                self?.status = "iPhone could not be reached. Try again when connected."
            }
        }
    }
    #endif

    private func receive(_ data: Data) {
        do {
            guard try inbox.receive(data), let incoming = inbox.snapshot else { return }
            // Persist the complication projection before completing background delivery.
            onSnapshotReceived?(incoming)
            isRequesting = false
            requestTimeout?.cancel()
            status = incoming.availability == .ready ? "Updated from iPhone" : "Unlock iPhone and open HeartSync."
        } catch {
            isRequesting = false
            requestTimeout?.cancel()
            status = "Update both HeartSync apps to sync. The last readable snapshot is shown."
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateConnection()
            if failed { self.status = "Companion connection failed. Reopen HeartSync to retry." }
            else { self.onActivation?() }
            #if os(watchOS)
            self.completeBackgroundDeliveryIfReady()
            #endif
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.updateConnection() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        #if os(watchOS)
        guard let data = context[WatchSnapshot.contextKey] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.receive(data)
            self?.completeBackgroundDeliveryIfReady()
        }
        #endif
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        #if os(iOS)
        guard message[WatchSnapshot.refreshKey] as? Bool == true else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Bound requests before any HealthKit or network work is started.
            guard self.lastRequest.map({ Date.now.timeIntervalSince($0) >= 15 }) ?? true else {
                self.onActivation?()
                return
            }
            self.lastRequest = .now
            self.onRefresh?()
        }
        #endif
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.updateConnection()
            self?.onActivation?()
        }
    }
    #endif

    #if DEBUG && os(watchOS)
    func installPreview(_ snapshot: WatchSnapshot) {
        if let data = try? snapshot.encoded() { _ = try? inbox.receive(data) }
        status = "Demo snapshot · no device connection"
    }
    #endif
}
