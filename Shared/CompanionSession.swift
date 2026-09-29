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
    /// A wrist sync-all is waiting for the iPhone's reply.
    private(set) var isSyncingAll = false
    /// The iPhone's reply to the last sync-all, or nil before the first.
    private(set) var lastSyncReport: WatchSyncReport?
    private(set) var status = String(localized: "companion.status.connecting", defaultValue: "Connecting to iPhone\u{2026}", comment: "Watch connection status")

    @ObservationIgnored var onRefresh: (@MainActor () -> Void)?
    /// Runs a sync-all on iPhone and returns its report by the reply deadline.
    @ObservationIgnored var onSyncAll: (@MainActor () async -> WatchSyncReport)?
    @ObservationIgnored var onActivation: (@MainActor () -> Void)?
    @ObservationIgnored var onBackgroundReady: (@MainActor () -> Void)?
    @ObservationIgnored var onSnapshotReceived: (@MainActor (WatchSnapshot) -> Void)?
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var requestTimeout: Task<Void, Never>?
    @ObservationIgnored private var syncAllTimeout: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: Date?
    @ObservationIgnored private var contentObservation: NSKeyValueObservation?

    func start() {
        guard session == nil else {
            resume()
            return
        }
        guard WCSession.isSupported() else {
            status = String(localized: "companion.status.unsupported", defaultValue: "Companion sync is unavailable on this device.", comment: "Watch connection status")
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
            status = String(localized: "companion.status.notInstalled", defaultValue: "Install HeartSync on the paired device.", comment: "Watch connection status")
        } else if isReachable {
            status = String(localized: "companion.status.available", defaultValue: "iPhone available", comment: "Watch connection status: the iPhone can be reached")
        } else {
            status = String(localized: "companion.status.unreachable", defaultValue: "Open HeartSync on iPhone to refresh.", comment: "Watch connection status")
        }
    }

    #if os(iOS)
    func publish(_ snapshot: WatchSnapshot) {
        guard let data = try? snapshot.encoded() else {
            status = String(localized: "companion.status.publishFailed", defaultValue: "Companion update could not be queued.", comment: "Watch connection status")
            return
        }
        publish(encoded: data)
    }

    /// Publishes a snapshot already encoded by `WatchSnapshot.encoded()`, which validated it
    /// and checked its size, so the main actor does not encode it a second time.
    func publish(encoded data: Data) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext([WatchSnapshot.contextKey: data])
        } catch {
            status = String(localized: "companion.status.publishFailed", defaultValue: "Companion update could not be queued.", comment: "Watch connection status")
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
        status = String(localized: "companion.status.requesting", defaultValue: "Requesting iPhone update\u{2026}", comment: "Watch connection status")
        requestTimeout?.cancel()
        requestTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self else { return }
            self.isRequesting = false
            self.status = String(localized: "companion.status.noUpdate", defaultValue: "No update yet. Open HeartSync on iPhone and try again.", comment: "Watch connection status")
        }
        session.sendMessage([WatchSnapshot.refreshKey: true], replyHandler: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestTimeout?.cancel()
                self?.isRequesting = false
                self?.status = String(localized: "companion.status.sendFailed", defaultValue: "iPhone could not be reached. Try again when connected.", comment: "Watch connection status")
            }
        }
    }

    /// Asks the iPhone to sync every source, as its Devices tab does one at a time, and
    /// shows the report it replies with. New readings arrive in a later snapshot.
    func requestSyncAll() {
        updateConnection()
        guard let session, isReachable, !isSyncingAll else { return }
        isSyncingAll = true
        status = String(localized: "companion.status.syncingAll", defaultValue: "Syncing all sources on iPhone\u{2026}", comment: "Watch connection status while the iPhone syncs every source")
        syncAllTimeout?.cancel()
        // Longer than the iPhone's own reply deadline, so a slow reply is not cut short.
        syncAllTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(WatchSyncReport.replyDeadline + 20)) } catch { return }
            guard let self, self.isSyncingAll else { return }
            self.isSyncingAll = false
            self.status = String(localized: "companion.status.syncNoReply", defaultValue: "No reply from iPhone. Open HeartSync on iPhone and try again.", comment: "Watch connection status: a sync-all request got no reply")
        }
        session.sendMessage(
            [WatchSyncReport.requestKey: true],
            // Called on a WatchConnectivity queue, so nothing here may assume the main actor.
            replyHandler: { @Sendable [weak self] reply in
                let report = (reply[WatchSyncReport.replyKey] as? Data).flatMap { try? WatchSyncReport.decode($0) }
                Task { @MainActor [weak self] in self?.finishSyncAll(report) }
            },
            errorHandler: { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.syncAllTimeout?.cancel()
                    self.isSyncingAll = false
                    self.status = String(localized: "companion.status.sendFailed", defaultValue: "iPhone could not be reached. Try again when connected.", comment: "Watch connection status")
                }
            }
        )
    }

    private func finishSyncAll(_ report: WatchSyncReport?) {
        syncAllTimeout?.cancel()
        isSyncingAll = false
        guard let report else {
            status = String(localized: "companion.status.incompatible", defaultValue: "Update both HeartSync apps to sync. The last readable snapshot is shown.", comment: "Watch connection status")
            return
        }
        lastSyncReport = report
        status = report.status == .completed
            ? String(localized: "companion.status.syncedAll", defaultValue: "iPhone synced your sources", comment: "Watch connection status after a sync-all finished")
            : String(localized: "companion.status.syncAllReplied", defaultValue: "iPhone replied", comment: "Watch connection status after a sync-all reply that did not finish every source")
    }
    #endif

    private func receive(_ data: Data) {
        do {
            guard try inbox.receive(data), let incoming = inbox.snapshot else { return }
            // Persist the complication projection before completing background delivery.
            onSnapshotReceived?(incoming)
            isRequesting = false
            requestTimeout?.cancel()
            status = incoming.availability == .ready
                ? String(localized: "companion.status.updated", defaultValue: "Updated from iPhone", comment: "Watch connection status: a snapshot arrived")
                : String(localized: "companion.status.locked", defaultValue: "Unlock iPhone and open HeartSync.", comment: "Watch connection status: the iPhone could not build a snapshot")
        } catch {
            isRequesting = false
            requestTimeout?.cancel()
            status = String(localized: "companion.status.incompatible", defaultValue: "Update both HeartSync apps to sync. The last readable snapshot is shown.", comment: "Watch connection status")
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

    /// A wrist sync-all. The reply goes back exactly once, by the iPhone's deadline.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(iOS)
        let reply = ReplyOnce(replyHandler)
        guard message[WatchSyncReport.requestKey] as? Bool == true else {
            reply.send([:])
            return
        }
        Task { @MainActor [weak self] in
            let report = await self?.onSyncAll?() ?? .unavailable()
            reply.send((try? report.encoded()).map { [WatchSyncReport.replyKey: $0] } ?? [:])
        }
        #else
        replyHandler([:])
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

/// WatchConnectivity's reply block, called at most once from whichever path finishes first.
/// It is thread-safe to call, but not declared `Sendable`, hence the lock and the unchecked
/// conformance.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (([String: Any]) -> Void)?

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func send(_ message: [String: Any]) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(message)
    }
}
