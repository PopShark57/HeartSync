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
    private(set) var cleanupPending = false
    private(set) var isChangingPairing = false

    @MainActor
    struct Actions {
        var load: @MainActor () -> MacMirrorPairingStore.State? = { MacMirrorPairingStore.loadState() }
        var save: @MainActor (MacMirrorPairingStore.State) -> Bool = { MacMirrorPairingStore.saveState($0) }
        var clear: @MainActor (HealthStore) -> Bool = { $0.clearMirror() }
        var listen = true
        var makeListener: @MainActor (NWParameters) throws -> NWListener = { try NWListener(using: $0) }
    }
    @ObservationIgnored private let actions: Actions
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pairingGeneration = UUID()
    @ObservationIgnored private var syncListenerGeneration = UUID()
    @ObservationIgnored private var pairingListenerGeneration = UUID()
    @ObservationIgnored private var listenerRetry: Task<Void, Never>?

    let macName: String
    @ObservationIgnored private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "MacMirror")
    @ObservationIgnored private weak var store: HealthStore?
    @ObservationIgnored private var syncListener: NWListener?
    @ObservationIgnored private var session: (tag: UUID, task: Task<Void, Never>, channel: MacMirrorChannel)?
    @ObservationIgnored private var retiredReceiver: Task<Void, Never>?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var exchange: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let lastSyncedKey = "macMirror.lastSyncedAt"

    init(macName: String, defaults: UserDefaults = .standard, actions: Actions = Actions()) {
        self.actions = actions
        self.macName = macName
        self.defaults = defaults
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedKey) as? Date
    }

    var identity: MacMirrorPairing.Identity {
        MacMirrorPairing.Identity(id: MacMirrorDeviceIdentity.current(defaults: defaults), name: macName)
    }

    /// Whether the mirror has finished a first copy and holds a position in the phone's log.
    var hasMirror: Bool { store?.mirrorPosition != nil }

    func start(store: HealthStore) async {
        self.store = store
        await reloadPairing()
    }

    func retryKeychain() {
        Task { await reloadPairing() }
    }

    // MARK: - Pairing window

    func openPairingWindow() {
        guard pairingListener == nil, !cleanupPending, !isChangingPairing, !pairingUnavailable else { return }
        let listenerTag = UUID()
        pairingListenerGeneration = listenerTag
        do {
            let listener = try actions.makeListener(MacMirrorTransport.pairingParameters())
            listener.service = NWListener.Service(type: MacMirrorProtocol.pairingService)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard self?.pairingListenerGeneration == listenerTag else { connection.cancel(); return }
                    self?.acceptPairing(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                let detail: String
                switch state {
                case .waiting(let error), .failed(let error): detail = error.localizedDescription
                default: return
                }
                Task { @MainActor in
                    guard self?.pairingListenerGeneration == listenerTag else { return }
                    self?.pairingFailed(detail)
                }
            }
            pairingListener = listener
            listener.start(queue: .main)
            pairingPhase = .waiting
        } catch {
            pairingPhase = .failed(error.localizedDescription)
        }
    }

    func closePairingWindow() {
        pairingGeneration = UUID()
        pairingListenerGeneration = UUID()
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
        closePairingWindow()
        pairingPhase = .failed(detail)
    }

    private func acceptPairing(_ connection: NWConnection) {
        // One exchange at a time; a second phone waits for the first to finish or fail.
        guard exchange == nil, pairingPhase == .waiting else {
            connection.cancel()
            return
        }
        let identity = identity
        let tag = UUID()
        pairingGeneration = tag
        let channel = MacMirrorChannel(connection: connection)
        exchange = Task { [weak self] in
            do {
                try await channel.accept()
                let record = try await MacMirrorPairingExchange.runMac(channel: channel, identity: identity) { code, peer in
                    guard !Task.isCancelled, self?.pairingGeneration == tag else { return false }
                    return await self?.ask(code: code, phone: peer.name, tag: tag) ?? false
                }
                channel.cancel()
                guard !Task.isCancelled, self?.pairingGeneration == tag else { return }
                _ = await self?.replacePairing(record)
            } catch {
                channel.cancel()
                guard let self, !Task.isCancelled, self.pairingGeneration == tag else { return }
                // Back to waiting, so a mistyped choice on the phone can simply be retried.
                self.pairingPhase = .failed(error.localizedDescription)
            }
            if self?.pairingGeneration == tag { self?.exchange = nil }
        }
    }

    private func ask(code: String, phone: String, tag: UUID) async -> Bool {
        guard !Task.isCancelled, pairingGeneration == tag else { return false }
        pairingPhase = .comparing(code: code, phone: phone)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                decision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pairingGeneration == tag else { return }
                self?.answer(false)
            }
        }
    }

    /// Journals first, drains obsolete work, clears SQLite, then publishes the new key.
    /// A restart repeats an unfinished erase before it starts any receiver.
    @discardableResult
    func replacePairing(_ record: MacMirrorPairingRecord) async -> Bool {
        await changePairing(to: record)
    }

    func unpair() async -> Bool { await changePairing(to: nil) }

    private func changePairing(to replacement: MacMirrorPairingRecord?) async -> Bool {
        guard !isChangingPairing else { return false }
        isChangingPairing = true
        defer { isChangingPairing = false }
        let old = stopSyncListener()
        closePairingWindow()
        await old?.value
        guard let current = actions.load() else {
            pairingUnavailable = true
            issue = String(localized: "The pairing could not be read. Unlock the Mac and retry before changing it.")
            return false
        }
        // Finish an earlier operation before accepting any different intent.
        if current.pending != nil { return finishPending(current) }
        var pending = current
        pending.pending = .init(replacement: replacement)
        guard actions.save(pending) else {
            issue = String(localized: "The pairing change could not be recorded in the Keychain. Try again.")
            return false
        }
        return finishPending(pending)
    }

    private func finishPending(_ state: MacMirrorPairingStore.State) -> Bool {
        guard let pending = state.pending, let store else { return false }
        cleanupPending = true
        pairing = nil
        guard actions.clear(store) else {
            issue = String(localized: "The mirrored history could not be deleted. Sync is stopped. Retry deletion to finish the pairing change.")
            return false
        }
        defaults.removeObject(forKey: Self.lastSyncedKey)
        lastSyncedAt = nil
        progress = nil
        let records = pending.replacement.map { [$0] } ?? []
        guard actions.save(.init(records: records)) else {
            issue = String(localized: "The copy was deleted, but the pairing change could not finish. Sync is stopped. Try again.")
            return false
        }
        cleanupPending = false
        pairingUnavailable = false
        pairing = records.first
        issue = nil
        if let pairing { pairingPhase = .paired(pairing.peer.name); startSyncListener() }
        else { pairingPhase = .closed }
        return true
    }

    func retryPendingChange() async { await reloadPairing() }

    // MARK: - Sync listener

    private func reloadPairing() async {
        guard !isChangingPairing else { return }
        isChangingPairing = true
        defer { isChangingPairing = false }
        let old = stopSyncListener()
        await old?.value
        guard let state = actions.load() else { pairingUnavailable = true; return }
        pairingUnavailable = false
        if state.pending != nil { _ = finishPending(state); return }
        cleanupPending = false
        pairing = state.records.first
        if pairing != nil { startSyncListener() }
    }

    private func startSyncListener() {
        stopSyncListener()
        guard let pairing, !cleanupPending, actions.listen else { return }
        let listenerTag = UUID()
        syncListenerGeneration = listenerTag
        do {
            let listener = try actions.makeListener(MacMirrorTransport.syncParameters(key: pairing.symmetricKey, identity: pairing.identity))
            listener.service = NWListener.Service(
                type: MacMirrorProtocol.syncService,
                txtRecord: NWTXTRecord([MacMirrorProtocol.macIDKey: identity.id.uuidString])
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard self?.syncListenerGeneration == listenerTag else { connection.cancel(); return }
                    self?.acceptSync(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(let error), .failed(let error):
                    let detail = error.localizedDescription
                    Task { @MainActor in
                        guard self?.syncListenerGeneration == listenerTag else { return }
                        self?.syncListenerFailed(detail)
                    }
                case .ready:
                    Task { @MainActor in
                        guard self?.syncListenerGeneration == listenerTag else { return }
                        self?.issue = nil
                    }
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

    @discardableResult
    private func stopSyncListener() -> Task<Void, Never>? {
        syncListenerGeneration = UUID()
        listenerRetry?.cancel()
        listenerRetry = nil
        syncListener?.cancel()
        syncListener = nil
        return stopSyncSession()
    }

    private func syncListenerFailed(_ detail: String) {
        logger.error("Mac sync listener failed: \(detail, privacy: .public)")
        issue = detail
        syncListener?.cancel()
        syncListener = nil
        // A network change can fail the listener; start it again shortly.
        let tag = syncListenerGeneration
        listenerRetry?.cancel()
        listenerRetry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.syncListenerGeneration == tag, self.syncListener == nil, self.pairing != nil,
                  !self.cleanupPending, !self.isChangingPairing else { return }
            self.startSyncListener()
        }
    }

    /// A newer connection replaces the current one: a phone that changed networks reconnects
    /// before the old connection has timed out, and two sessions must never apply at once.
    private func acceptSync(_ connection: NWConnection) {
        guard let pairing, let store, !cleanupPending, !isChangingPairing, !pairingUnavailable else {
            connection.cancel()
            return
        }
        let old = stopSyncSession()
        let channel = MacMirrorChannel(connection: connection)
        let tag = UUID()
        generation = tag
        let task = Task { [weak self] in
            await old?.value
            guard !Task.isCancelled, self?.generation == tag else { channel.cancel(); return }
            do {
                try await channel.accept()
                try await MacMirrorReceiver(store: store).run(
                    channel: channel,
                    pairing: pairing,
                    onPhone: { [weak self] name in
                        guard self?.generation == tag else { return }
                        self?.connectedPhone = name
                    },
                    onProgress: { [weak self] progress in
                        guard self?.generation == tag else { return }
                        self?.received(progress)
                    },
                    isCurrent: { [weak self] in self?.generation == tag && self?.cleanupPending == false }
                )
            } catch {
                if !Task.isCancelled, self?.generation == tag {
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

    private func stopSyncSession() -> Task<Void, Never>? {
        generation = UUID()
        let old = session?.task
        old?.cancel()
        session?.channel.cancel()
        session = nil
        connectedPhone = nil
        if let old {
            let previous = retiredReceiver
            retiredReceiver = Task {
                await previous?.value
                await old.value
            }
        }
        return retiredReceiver
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
