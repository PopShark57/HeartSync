import CryptoKit
import Foundation
import Network
import Security

/// Network parameters for the two kinds of connection.
enum MacMirrorTransport {
    /// TLS 1.2 with the pairing's pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`), the
    /// arrangement Apple's peer-to-peer Network.framework samples use between two devices
    /// that share a secret but no certificate. A handshake with any other key fails, so a
    /// connection that becomes ready is one from the paired device.
    static func syncParameters(key: SymmetricKey, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            keyData as __DispatchData,
            identityData as __DispatchData
        )
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: tcpOptions())
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Plain TCP for pairing, which authenticates itself (`MacMirrorPairing`).
    static func pairingParameters() -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: tcpOptions())
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.connectionTimeout = 10
        return tcp
    }
}

/// One connection carrying `MacMirrorFrame`s, with async send and receive.
///
/// Network.framework calls back on `queue`; each call here waits on one callback through a
/// checked continuation. One sender and one receiver at a time, which is how both sessions
/// use it: they alternate request and reply.
final class MacMirrorChannel: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "com.heartsync.mirror.channel")

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits until it is ready. A connection that waits (no route,
    /// refused) or fails, including a TLS handshake with the wrong key, throws.
    func open() async throws {
        let gate = MirrorResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume() }
                case .waiting(let error), .failed(let error):
                    gate.run { continuation.resume(throwing: MacMirrorError.connectionFailed(Self.describe(error))) }
                case .cancelled:
                    gate.run { continuation.resume(throwing: MacMirrorError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Adopts a connection a listener accepted and waits until it is ready.
    func accept() async throws {
        try await open()
    }

    func send(_ frame: MacMirrorFrame) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame.encoded, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MacMirrorError.connectionFailed(Self.describe(error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> MacMirrorFrame {
        let header = try await receive(exactly: MacMirrorFrame.headerLength)
        let (type, length) = try MacMirrorFrame.parseHeader(header)
        let body = length == 0 ? Data() : try await receive(exactly: length)
        return MacMirrorFrame(type: type, body: body)
    }

    /// Says goodbye, best effort, then closes.
    func close(_ reason: MacMirrorGoodbye.Reason? = nil, detail: String? = nil) async {
        if let reason, let frame = try? MacMirrorFrame.json(.goodbye, MacMirrorGoodbye(reason: reason, detail: detail)) {
            try? await send(frame)
        }
        cancel()
    }

    func cancel() {
        connection.cancel()
    }

    private func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MacMirrorError.connectionFailed(Self.describe(error)))
                } else if let content, content.count == count {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: MacMirrorError.closed)
                } else {
                    continuation.resume(throwing: MacMirrorError.malformed("short read"))
                }
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status):
            String(localized: "macMirror.error.tls", defaultValue: "the secure connection was refused (\(Int(status))); the pairing may have changed", comment: "Mac sync: TLS handshake failed, usually a stale pairing key")
        default:
            error.localizedDescription
        }
    }
}

/// Lets several callbacks race to resume one continuation; only the first runs.
private final class MirrorResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
