import Foundation
import Network
import Observation
import OSLog

/// The phone's side of Mac sync: finds paired Macs on the local network and keeps each one's
/// mirror up to date while HeartSync is in the foreground.
///
/// Nothing runs, and the Local Network permission is never asked for, until a Mac has been
/// paired. While at least one is paired, the store records every reading change in its change
/// log (`HealthStore.setMirrorChangeLogging`); unpairing the last one switches the log off
/// and deletes it. Sessions stop when the app goes to the background and resume when it
/// returns, starting from wherever each Mac got to.
@MainActor
@Observable
final class MacMirrorPublisher {
    struct PeerStatus: Equatable, Sendable {
        var progress: MacMirrorProgress?
        /// Whether the Mac is advertising on this network right now.
        var isReachable = false
        var lastSyncedAt: Date?
        var issue: String?
    }

    private(set) var pairings: [MacMirrorPairingRecord] = []
    private(set) var status: [String: PeerStatus] = [:]
    /// Set when the Keychain could not be read, so the pairings are unknown, not absent.
    private(set) var pairingsUnavailable = false
    private(set) var discoveryIssue: String?
    @ObservationIgnored private var browseRetry: Task<Void, Never>?
    @ObservationIgnored private var browseAttempt = 0
    @ObservationIgnored private var browserGeneration = UUID()

    @ObservationIgnored private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "MacMirror")
    @ObservationIgnored private weak var store: HealthStore?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    /// One running session per pairing, tagged so a session that ends late cannot remove the
    /// entry of one started after it.
    @ObservationIgnored private var sessions: [String: (tag: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private let defaults: UserDefaults
    let phoneName: String

    init(phoneName: String, defaults: UserDefaults = .standard) {
        self.phoneName = phoneName
        self.defaults = defaults
    }

    var identity: MacMirrorPairing.Identity {
        MacMirrorPairing.Identity(id: MacMirrorDeviceIdentity.current(defaults: defaults), name: phoneName)
    }

    /// Reads the pairings and switches the change log to match. Called once the history has
    /// loaded; does nothing for a phone that has never paired a Mac.
    func configure(store: HealthStore) {
        self.store = store
        reloadPairings()
        lastSyncedFromDefaults()
    }

    /// Foreground: browse for paired Macs and connect to each one found.
    func resume() {
        isActive = true
        startBrowsingIfNeeded()
    }

    /// Background: end every session and stop browsing. Each Mac keeps its position.
    func suspend() {
        isActive = false
        browserGeneration = UUID()
        browseRetry?.cancel()
        browseRetry = nil
        browser?.cancel()
        browser = nil
        endpoints.removeAll()
        for session in sessions.values { session.task.cancel() }
        sessions.removeAll()
        for key in status.keys {
            status[key]?.isReachable = false
            status[key]?.progress = nil
        }
    }

    /// Keeps a pairing the user has just confirmed and starts mirroring to it.
    func add(_ record: MacMirrorPairingRecord) -> Bool {
        var updated = pairings.filter { $0.peer.id != record.peer.id }
        updated.append(record)
        guard MacMirrorPairingStore.save(updated) else { return false }
        for old in pairings where old.peer.id == record.peer.id {
            sessions[old.identity]?.task.cancel()
            sessions[old.identity] = nil
            status[old.identity] = nil
            defaults.removeObject(forKey: Self.ackKey(old.identity))
            defaults.removeObject(forKey: Self.syncedKey(old.identity))
        }
        pairings = updated
        status[record.identity] = PeerStatus()
        applyChangeLogging()
        if isActive { startBrowsingIfNeeded() }
        return true
    }

    /// Forgets a Mac. Its mirror is not touched; it stops receiving anything.
    func forget(_ record: MacMirrorPairingRecord) -> Bool {
        let updated = pairings.filter { $0.identity != record.identity }
        guard MacMirrorPairingStore.save(updated) else { return false }
        pairings = updated
        sessions[record.identity]?.task.cancel()
        sessions[record.identity] = nil
        status[record.identity] = nil
        defaults.removeObject(forKey: Self.ackKey(record.identity))
        defaults.removeObject(forKey: Self.syncedKey(record.identity))
        applyChangeLogging()
        if pairings.isEmpty {
            browserGeneration = UUID()
            browseRetry?.cancel()
            browseRetry = nil
            browser?.cancel()
            browser = nil
        }
        return true
    }

    /// Runs after a reset or retention change has rewritten the store, so trimming catches up.
    func trimLog() {
        guard !pairings.isEmpty else { return }
        let acknowledged = pairings.map { defaults.object(forKey: Self.ackKey($0.identity)) as? Int64 }
        let lowest: Int64? = acknowledged.contains(where: { $0 == nil }) ? nil : acknowledged.compactMap { $0 }.min()
        store?.trimMirrorChangeLog(acknowledgedThrough: lowest)
    }

    // MARK: - Pairings

    private func reloadPairings() {
        switch MacMirrorPairingStore.load() {
        case .records(let records):
            pairings = records
            pairingsUnavailable = false
            applyChangeLogging()
        case .unavailable:
            // Unknown is not none: leave the log as it is rather than deleting it.
            pairingsUnavailable = true
        }
    }

    private func applyChangeLogging() {
        guard let store, store.loadState == .loaded else { return }
        if !store.setMirrorChangeLogging(!pairings.isEmpty) {
            logger.error("Could not switch the Mac sync change log")
        }
    }

    // MARK: - Discovery

    private func startBrowsingIfNeeded() {
        if pairingsUnavailable { reloadPairings() }
        guard isActive, browser == nil, !pairings.isEmpty else { return }
        let tag = UUID()
        browserGeneration = tag
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MacMirrorProtocol.syncService, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> (String, NWEndpoint)? in
                guard case .bonjour(let record) = result.metadata,
                      let macID = record[MacMirrorProtocol.macIDKey]
                else { return nil }
                return (macID, result.endpoint)
            }
            Task { @MainActor in
                guard self?.browserGeneration == tag else { return }
                self?.update(found)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                let detail = error.localizedDescription
                Task { @MainActor in
                    guard self?.browserGeneration == tag else { return }
                    self?.browserFailed(detail)
                }
            case .ready:
                Task { @MainActor in
                    guard self?.browserGeneration == tag else { return }
                    self?.discoveryIssue = nil
                    self?.browseAttempt = 0
                }
            default: break
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func browserFailed(_ detail: String) {
        discoveryIssue = detail
        browserGeneration = UUID()
        logger.error("Mac sync browsing failed: \(detail, privacy: .public)")
        browser?.cancel()
        browser = nil
        for record in pairings {
            status[record.identity, default: PeerStatus()].issue = detail
            status[record.identity]?.isReachable = false
        }
        endpoints.removeAll()
        browseRetry?.cancel()
        let delay = min(120, 5 * pow(2, Double(min(browseAttempt, 5))))
        browseAttempt += 1
        browseRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isActive else { return }
            self.browseRetry = nil
            self.startBrowsingIfNeeded()
        }
    }

    func retryDiscovery() {
        browseRetry?.cancel()
        browseRetry = nil
        browserGeneration = UUID()
        browser?.cancel()
        browser = nil
        browseAttempt = 0
        startBrowsingIfNeeded()
    }

    private func update(_ found: [(String, NWEndpoint)]) {
        guard isActive else { return }
        var reachable: [String: NWEndpoint] = [:]
        for (macID, endpoint) in found {
            guard let record = pairings.first(where: { $0.peer.id.uuidString == macID }) else { continue }
            reachable[record.identity] = endpoint
        }
        endpoints = reachable
        for record in pairings {
            status[record.identity, default: PeerStatus()].isReachable = reachable[record.identity] != nil
            if reachable[record.identity] != nil, sessions[record.identity] == nil {
                startSession(record)
            }
        }
    }

    // MARK: - Sessions

    private func startSession(_ record: MacMirrorPairingRecord) {
        guard let store else { return }
        let tag = UUID()
        let task = Task { [weak self] in
            var delay: Duration = .seconds(5)
            while !Task.isCancelled {
                guard let self, let endpoint = self.endpoints[record.identity] else { break }
                let channel = MacMirrorChannel(connection: NWConnection(
                    to: endpoint,
                    using: MacMirrorTransport.syncParameters(key: record.symmetricKey, identity: record.identity)
                ))
                do {
                    try await channel.open()
                    self.status[record.identity, default: PeerStatus()].issue = nil
                    delay = .seconds(5)
                    try await MacMirrorSender(store: store).run(
                        channel: channel,
                        pairing: record,
                        phoneName: self.phoneName,
                        onProgress: { [weak self] progress in
                            guard self?.sessions[record.identity]?.tag == tag, !Task.isCancelled else { return }
                            self?.status[record.identity, default: PeerStatus()].progress = progress
                        },
                        onAcknowledged: { [weak self] cursor in
                            guard self?.sessions[record.identity]?.tag == tag, !Task.isCancelled else { return }
                            self?.acknowledged(cursor, for: record)
                        },
                        waitForChange: { [weak self] in await self?.waitForChange() ?? false }
                    )
                    await channel.close(.closing)
                } catch {
                    channel.cancel()
                    if Task.isCancelled { break }
                    self.logger.error("Mac sync session ended: \(error.localizedDescription, privacy: .public)")
                    self.status[record.identity, default: PeerStatus()].issue = error.localizedDescription
                    self.status[record.identity, default: PeerStatus()].progress = nil
                }
                do { try await Task.sleep(for: delay) } catch { break }
                delay = min(delay * 3, .seconds(120))
            }
            if self?.sessions[record.identity]?.tag == tag { self?.sessions[record.identity] = nil }
        }
        sessions[record.identity] = (tag, task)
    }

    private func acknowledged(_ cursor: Int64, for record: MacMirrorPairingRecord) {
        let now = Date.now
        defaults.set(cursor, forKey: Self.ackKey(record.identity))
        defaults.set(now, forKey: Self.syncedKey(record.identity))
        status[record.identity, default: PeerStatus()].lastSyncedAt = now
        trimLog()
    }

    /// Returns once the store has changed and two quiet seconds have passed, so a 1 Hz
    /// stream goes out in batches rather than a frame a second. False when cancelled.
    private func waitForChange() async -> Bool {
        guard let store else { return false }
        let waiter = ChangeWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter.install(continuation)
                withObservationTracking {
                    _ = store.changeToken
                    _ = store.sources
                } onChange: {
                    Task { @MainActor in waiter.fire() }
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.fire() }
        }
        guard !Task.isCancelled else { return false }
        do { try await Task.sleep(for: .seconds(2)) } catch { return false }
        return true
    }

    private func lastSyncedFromDefaults() {
        for record in pairings {
            status[record.identity, default: PeerStatus()].lastSyncedAt = defaults.object(forKey: Self.syncedKey(record.identity)) as? Date
        }
    }

    private static func ackKey(_ identity: String) -> String { "macMirror.ack.\(identity)" }
    private static func syncedKey(_ identity: String) -> String { "macMirror.synced.\(identity)" }
}

/// One wait for a store change, resumed by the change or by cancellation, whichever is first.
@MainActor
private final class ChangeWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        if fired { continuation.resume() } else { self.continuation = continuation }
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
