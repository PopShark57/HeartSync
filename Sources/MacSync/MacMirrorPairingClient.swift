import Foundation
import Network
import Observation

/// The phone's pairing sheet: lists Macs whose pairing window is open and pairs with one.
@MainActor
@Observable
final class MacMirrorPairingClient {
    struct FoundMac: Identifiable, Equatable {
        var name: String
        var endpoint: NWEndpoint
        var id: String { "\(endpoint)" }
    }

    enum Phase: Equatable {
        case searching
        case connecting(String)
        /// Both screens show `code`; waiting for this person to compare it.
        case comparing(code: String, mac: String)
        /// This person confirmed; waiting for the person at the Mac.
        case waitingForMac(code: String, mac: String)
        case paired(String)
        case failed(String)
    }

    enum Discovery: Equatable { case searching, noResults, unavailable(String) }
    private(set) var discovery: Discovery = .searching
    @ObservationIgnored private var discoveryTimer: Task<Void, Never>?
    @ObservationIgnored private var discoveryRetry: Task<Void, Never>?
    @ObservationIgnored private var browseAttempt = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var browserGeneration = UUID()
    private(set) var found: [FoundMac] = []
    private(set) var phase: Phase = .searching

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var exchange: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let publisher: MacMirrorPublisher

    init(publisher: MacMirrorPublisher) {
        self.publisher = publisher
    }

    func start() {
        isActive = true
        guard browser == nil else { return }
        phase = .searching
        discovery = .searching
        found = []
        let tag = UUID()
        browserGeneration = tag
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: MacMirrorProtocol.pairingService, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> FoundMac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return FoundMac(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                guard let self, self.browserGeneration == tag, self.browser != nil else { return }
                self.found = macs.sorted { $0.name < $1.name }
                self.discovery = self.found.isEmpty ? .noResults : .searching
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                let detail = error.localizedDescription
                Task { @MainActor in
                    guard let self, self.browserGeneration == tag else { return }
                    self.discovery = .unavailable(detail)
                    self.found = []
                    self.scheduleDiscoveryRetry()
                }
            case .ready:
                Task { @MainActor in
                    guard let self, self.browserGeneration == tag else { return }
                    self.browseAttempt = 0
                    if case .unavailable = self.discovery {
                        self.discovery = self.found.isEmpty ? .noResults : .searching
                    }
                    self.discoveryRetry?.cancel()
                    self.discoveryRetry = nil
                }
            default: break
            }
        }
        self.browser = browser
        discoveryTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.browserGeneration == tag, self.discovery == .searching, self.found.isEmpty else { return }
            self.discovery = .noResults
        }
        browser.start(queue: .main)
    }

    private func scheduleDiscoveryRetry() {
        guard isActive, phase == .searching, discoveryRetry == nil else { return }
        let delay = min(120, 5 * pow(2, Double(min(browseAttempt, 5))))
        browseAttempt += 1
        discoveryRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isActive, self.phase == .searching else { return }
            self.browserGeneration = UUID()
            self.browser?.cancel()
            self.browser = nil
            self.discoveryTimer?.cancel()
            self.discoveryRetry = nil
            self.start()
        }
    }

    func stop() {
        isActive = false
        browseAttempt = 0
        discoveryRetry?.cancel()
        discoveryRetry = nil
        generation = UUID()
        browserGeneration = UUID()
        discoveryTimer?.cancel()
        browser?.cancel()
        browser = nil
        answer(false)
        exchange?.cancel()
        exchange = nil
    }

    func pair(with mac: FoundMac) {
        guard exchange == nil else { return }
        let tag = UUID()
        generation = tag
        phase = .connecting(mac.name)
        let identity = publisher.identity
        exchange = Task { [weak self] in
            let channel = MacMirrorChannel(connection: NWConnection(to: mac.endpoint, using: MacMirrorTransport.pairingParameters()))
            do {
                try await channel.open()
                let record = try await MacMirrorPairingExchange.runPhone(channel: channel, identity: identity) { code, peer in
                    guard !Task.isCancelled, self?.generation == tag else { return false }
                    return await self?.ask(code: code, mac: peer.name, tag: tag) ?? false
                }
                channel.cancel()
                guard let self, !Task.isCancelled, self.generation == tag else { return }
                if self.publisher.add(record) {
                    self.phase = .paired(record.peer.name)
                } else {
                    self.phase = .failed(String(
                        localized: "macMirror.pairing.keychain",
                        defaultValue: "The pairing could not be saved to the Keychain. Unlock the iPhone and try again.",
                        comment: "Mac pairing: saving the key failed"
                    ))
                }
            } catch {
                channel.cancel()
                if !Task.isCancelled, self?.generation == tag { self?.phase = .failed(error.localizedDescription) }
            }
            if self?.generation == tag { self?.exchange = nil }
        }
    }

    /// This person's answer to "do the codes match?".
    func answer(_ matches: Bool) {
        if matches, case .comparing(let code, let mac) = phase {
            phase = .waitingForMac(code: code, mac: mac)
        }
        decision?.resume(returning: matches)
        decision = nil
    }

    func tryAgain() {
        stop()
        start()
    }

    private func ask(code: String, mac: String, tag: UUID) async -> Bool {
        guard !Task.isCancelled, generation == tag else { return false }
        phase = .comparing(code: code, mac: mac)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                decision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == tag else { return }
                self?.answer(false)
            }
        }
    }
}
