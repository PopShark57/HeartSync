import Foundation
import Network
import Observation
import OSLog

/// The Mac's side of sync: the pairing window, and the listener the paired iPhone connects to.
///
/// A Mac mirrors one iPhone. While paired it advertises `_heartsync._tcp` with its install id
/// and accepts TLS connections made with the pairing's key; the phone connects whenever
/// HeartSync is open on it and both are on the same network. Pairing with a different
/// iPhone, or unpairing, deletes the mirrored history, because it belongs to the old phone.
@MainActor
@Observable
final class MacMirrorService {
    enum PairingPhase: Equatable {
        case closed
        /// Advertising `_heartsync-pair._tcp`, waiting for a phone to choose this Mac.
        case waiting
        case comparing(code: String, phone: String)
        case waitingForPhone(code: String, phone: String)
        case paired(String)
        case failed(String)
    }

    private(set) var pairing: MacMirrorPairingRecord?
    /// The Keychain could not be read, so whether this Mac is paired is unknown.
    private(set) var pairingUnavailable = false
    private(set) var pairingPhase: PairingPhase = .closed
    /// The phone's name while it is connected.
    private(set) var connectedPhone: String?
    private(set) var progress: MacMirrorProgress?
    private(set) var lastSyncedAt: Date?
    private(set) var issue: String?

    let macName: String
    @ObservationIgnored private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "MacMirror")
    @ObservationIgnored private weak var store: HealthStore?
    @ObservationIgnored private var syncListener: NWListener?
    @ObservationIgnored private var session: (tag: UUID, task: Task<Void, Never>, channel: MacMirrorChannel)?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var exchange: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let lastSyncedKey = "macMirror.lastSyncedAt"

    init(macName: String, defaults: UserDefaults = .standard) {
        self.macName = macName
        self.defaults = defaults
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedKey) as? Date
    }

    var identity: MacMirrorPairing.Identity {
        MacMirrorPairing.Identity(id: MacMirrorDeviceIdentity.current(defaults: defaults), name: macName)
    }

    /// Whether the mirror has finished a first copy and holds a position in the phone's log.
    var hasMirror: Bool { store?.mirrorPosition != nil }

    func start(store: HealthStore) {
        self.store = store
        reloadPairing()
    }

    func retryKeychain() {
        reloadPairing()
    }

    // MARK: - Pairing window

    func openPairingWindow() {
        guard pairingListener == nil else { return }
        do {
            let listener = try NWListener(using: MacMirrorTransport.pairingParameters())
            listener.service = NWListener.Service(type: MacMirrorProtocol.pairingService)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptPairing(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                let detail = error.localizedDescription
                Task { @MainActor in self?.pairingFailed(detail) }
            }
            pairingListener = listener
            listener.start(queue: .main)
            pairingPhase = .waiting
        } catch {
            pairingPhase = .failed(error.localizedDescription)
        }
    }

    func closePairingWindow() {
        pairingListener?.cancel()
        pairingListener = nil
        answer(false)
        exchange?.cancel()
        exchange = nil
        pairingPhase = .closed
    }

    /// This person's answer to "do the codes match?".
    func answer(_ matches: Bool) {
        if matches, case .comparing(let code, let phone) = pairingPhase {
            pairingPhase = .waitingForPhone(code: code, phone: phone)
        }
        decision?.resume(returning: matches)
        decision = nil
    }

    private func pairingFailed(_ detail: String) {
        pairingListener?.cancel()
        pairingListener = nil
        pairingPhase = .failed(detail)
    }

    private func acceptPairing(_ connection: NWConnection) {
        // One exchange at a time; a second phone waits for the first to finish or fail.
        guard exchange == nil, pairingPhase == .waiting else {
            connection.cancel()
            return
        }
        let identity = identity
        let channel = MacMirrorChannel(connection: connection)
        exchange = Task { [weak self] in
            do {
                try await channel.accept()
                let record = try await MacMirrorPairingExchange.runMac(channel: channel, identity: identity) { code, peer in
                    await self?.ask(code: code, phone: peer.name) ?? false
                }
                channel.cancel()
                self?.finishPairing(record)
            } catch {
                channel.cancel()
                guard let self, !Task.isCancelled else { return }
                // Back to waiting, so a mistyped choice on the phone can simply be retried.
                self.pairingPhase = .failed(error.localizedDescription)
            }
            self?.exchange = nil
        }
    }

    private func ask(code: String, phone: String) async -> Bool {
        pairingPhase = .comparing(code: code, phone: phone)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(false) }
        }
    }

    private func finishPairing(_ record: MacMirrorPairingRecord) {
        let previous = pairing
        guard MacMirrorPairingStore.save([record]) else {
            pairingPhase = .failed(String(
                localized: "mac.pairing.keychain",
                defaultValue: "The pairing could not be saved to the Keychain.",
                comment: "Mac pairing: saving the key failed"
            ))
            return
        }
        // A different phone's history must not be merged into the old one's.
        if let previous, previous.peer.id != record.peer.id {
            store?.clearMirror()
            defaults.removeObject(forKey: Self.lastSyncedKey)
            lastSyncedAt = nil
        }
        pairing = record
        pairingListener?.cancel()
        pairingListener = nil
        pairingPhase = .paired(record.peer.name)
        startSyncListener()
    }

    /// Forgets the phone and deletes the mirrored history.
    func unpair() -> Bool {
        guard MacMirrorPairingStore.save([]) else { return false }
        stopSyncListener()
        pairing = nil
        store?.clearMirror()
        defaults.removeObject(forKey: Self.lastSyncedKey)
        lastSyncedAt = nil
        progress = nil
        issue = nil
        pairingPhase = .closed
        return true
    }

    // MARK: - Sync listener

    private func reloadPairing() {
        switch MacMirrorPairingStore.load() {
        case .records(let records):
            pairingUnavailable = false
            pairing = records.first
            if pairing != nil { startSyncListener() }
        case .unavailable:
            pairingUnavailable = true
        }
    }

    private func startSyncListener() {
        stopSyncListener()
        guard let pairing else { return }
        do {
            let listener = try NWListener(
                using: MacMirrorTransport.syncParameters(key: pairing.symmetricKey, identity: pairing.identity)
            )
            listener.service = NWListener.Service(
                type: MacMirrorProtocol.syncService,
                txtRecord: NWTXTRecord([MacMirrorProtocol.macIDKey: identity.id.uuidString])
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptSync(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    let detail = error.localizedDescription
                    Task { @MainActor in self?.syncListenerFailed(detail) }
                case .ready:
                    Task { @MainActor in self?.issue = nil }
                default:
                    break
                }
            }
            syncListener = listener
            listener.start(queue: .main)
        } catch {
            issue = error.localizedDescription
        }
    }

    private func stopSyncListener() {
        syncListener?.cancel()
        syncListener = nil
        session?.task.cancel()
        session?.channel.cancel()
        session = nil
        connectedPhone = nil
    }

    private func syncListenerFailed(_ detail: String) {
        logger.error("Mac sync listener failed: \(detail, privacy: .public)")
        issue = detail
        syncListener?.cancel()
        syncListener = nil
        // A network change can fail the listener; start it again shortly.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.syncListener == nil, self.pairing != nil else { return }
            self.startSyncListener()
        }
    }

    /// A newer connection replaces the current one: a phone that changed networks reconnects
    /// before the old connection has timed out, and two sessions must never apply at once.
    private func acceptSync(_ connection: NWConnection) {
        guard let pairing, let store else {
            connection.cancel()
            return
        }
        session?.task.cancel()
        session?.channel.cancel()
        let channel = MacMirrorChannel(connection: connection)
        let tag = UUID()
        let task = Task { [weak self] in
            do {
                try await channel.accept()
                try await MacMirrorReceiver(store: store).run(
                    channel: channel,
                    pairing: pairing,
                    onPhone: { [weak self] name in self?.connectedPhone = name },
                    onProgress: { [weak self] progress in self?.received(progress) }
                )
            } catch {
                if !Task.isCancelled {
                    self?.logger.error("Mac sync session ended: \(error.localizedDescription, privacy: .public)")
                    self?.issue = error.localizedDescription
                }
            }
            channel.cancel()
            guard let self, self.session?.tag == tag else { return }
            self.session = nil
            self.connectedPhone = nil
            if case .upToDate = self.progress {} else { self.progress = nil }
        }
        session = (tag, task, channel)
    }

    private func received(_ progress: MacMirrorProgress) {
        self.progress = progress
        if case .upToDate(let date) = progress {
            issue = nil
            lastSyncedAt = date
            defaults.set(date, forKey: Self.lastSyncedKey)
        }
    }
}
