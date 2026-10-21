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
    ///
    /// Session resumption is off. A resumed TLS 1.2 session skips the PSK exchange and
    /// reuses the master secret of an earlier connection to the same endpoint. In the macOS
    /// test run a connection offering a different key became ready after boringssl logged
    /// clearing its configured PSK, consistent with resuming the cached session instead of
    /// handshaking with the key it was given. Every connection must prove the current
    /// pairing's key; a session cached under a replaced pairing must not outlive it. One full
    /// handshake per foreground sync costs nothing measurable.
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
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
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
        try await perform(timeout: 15) { (finish: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .waiting(let error), .failed(let error):
                    finish(.failure(MacMirrorError.connectionFailed(Self.describe(error))))
                case .cancelled: finish(.failure(MacMirrorError.closed))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    /// Adopts a connection a listener accepted and waits until it is ready.
    func accept() async throws {
        try await open()
    }

    func send(_ frame: MacMirrorFrame) async throws {
        try await perform(timeout: 30) { (finish: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            self.connection.send(content: frame.encoded, completion: .contentProcessed { error in
                if let error { finish(.failure(MacMirrorError.connectionFailed(Self.describe(error)))) }
                else { finish(.success(())) }
            })
        }
    }

    func receive() async throws -> MacMirrorFrame {
        let header = try await receive(exactly: MacMirrorFrame.headerLength, timeout: nil)
        let (type, length) = try MacMirrorFrame.parseHeader(header)
        let body = length == 0 ? Data() : try await receive(exactly: length, timeout: 30)
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

    private func receive(exactly count: Int, timeout: TimeInterval?) async throws -> Data {
        try await perform(timeout: timeout) { finish in
            self.connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error { finish(.failure(MacMirrorError.connectionFailed(Self.describe(error)))) }
                else if let content, content.count == count { finish(.success(content)) }
                else if isComplete { finish(.failure(MacMirrorError.closed)) }
                else { finish(.failure(MacMirrorError.malformed("short read"))) }
            }
        }
    }

    /// Cancellation resumes the waiter itself, including cancellation before installation.
    /// The late Network callback and the deadline race through the same locked gate.
    private func perform<Value: Sendable>(
        timeout: TimeInterval?,
        _ begin: @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        let pending = MirrorPending<Value>()
        let deadline = DispatchWorkItem { [self] in
            if pending.finish(.failure(MacMirrorError.timedOut)) { connection.cancel() }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }
                if let timeout { queue.asyncAfter(deadline: .now() + timeout, execute: deadline) }
                begin { _ = pending.finish($0) }
            }
        } onCancel: { [self] in
            _ = pending.finish(.failure(CancellationError()))
            connection.cancel()
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

/// A result may arrive before the continuation; both installation orders are safe.
private final class MirrorPending<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let completed = lock.withLock { () -> Result<Value, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed); return false }
        return true
    }

    @discardableResult
    func finish(_ result: Result<Value, any Error>) -> Bool {
        let outcome = lock.withLock { () -> (Bool, CheckedContinuation<Value, any Error>?) in
            guard self.result == nil else { return (false, nil) }
            self.result = result
            defer { continuation = nil }
            return (true, continuation)
        }
        outcome.1?.resume(with: result)
        return outcome.0
    }
}
