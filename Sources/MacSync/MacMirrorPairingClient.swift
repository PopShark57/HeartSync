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
        guard browser == nil else { return }
        phase = .searching
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: MacMirrorProtocol.pairingService, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> FoundMac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return FoundMac(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.found = macs.sorted { $0.name < $1.name } }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        answer(false)
        exchange?.cancel()
        exchange = nil
    }

    func pair(with mac: FoundMac) {
        guard exchange == nil else { return }
        phase = .connecting(mac.name)
        let identity = publisher.identity
        exchange = Task { [weak self] in
            let channel = MacMirrorChannel(connection: NWConnection(to: mac.endpoint, using: MacMirrorTransport.pairingParameters()))
            do {
                try await channel.open()
                let record = try await MacMirrorPairingExchange.runPhone(channel: channel, identity: identity) { code, peer in
                    await self?.ask(code: code, mac: peer.name) ?? false
                }
                channel.cancel()
                guard let self else { return }
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
                self?.phase = .failed(error.localizedDescription)
            }
            self?.exchange = nil
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
        exchange?.cancel()
        exchange = nil
        phase = .searching
    }

    private func ask(code: String, mac: String) async -> Bool {
        phase = .comparing(code: code, mac: mac)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(false) }
        }
    }
}
