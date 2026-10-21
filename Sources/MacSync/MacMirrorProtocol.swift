import Foundation

/// The wire format between HeartSync on iPhone and its Mac mirror.
///
/// The iPhone holds the history and the Mac holds a copy. The phone connects to a paired
/// Mac it finds on the local network, says hello, learns how far the Mac has got, and sends
/// batches: the source list, rows as they now are, and the ids of rows that are gone. The
/// Mac applies each batch in one transaction and acknowledges it before the next is sent.
/// Nothing flows the other way except acknowledgements, so the Mac can never change the
/// phone's history.
///
/// Every message is one frame: a four-byte big-endian length, then a one-byte type, then the
/// body. JSON bodies are the small control messages; a batch has a binary body
/// (`MacMirrorBatchCodec`).
enum MacMirrorProtocol {
    /// Raised when a message or batch changes incompatibly. Both apps ship together, so a
    /// mismatch means one of them needs updating, and the Mac says which.
    static let version = 1
    /// Bonjour service a Mac advertises while it accepts mirror connections (TLS, pre-shared
    /// key). Listed in both apps' `NSBonjourServices`.
    static let syncService = "_heartsync._tcp"
    /// Bonjour service a Mac advertises only while its pairing window is open (plain TCP;
    /// the pairing exchange authenticates itself, see `MacMirrorPairing`).
    static let pairingService = "_heartsync-pair._tcp"
    /// TXT record key carrying a Mac's install id, so a phone knows which pairing's key to
    /// offer before connecting.
    static let macIDKey = "id"
    /// A batch body larger than this is refused. A batch is at most `batchSize` rows, so a
    /// legitimate one is a small fraction of it.
    static let maximumFrameLength = 32 * 1_024 * 1_024
    /// Rows per batch: small enough that applying one on the Mac's main actor is a short
    /// pause, large enough that a month of 1 Hz history is a few hundred round trips.
    static let batchSize = 2_000
}

enum MacMirrorFrameType: UInt8, Sendable {
    case hello = 1
    case state = 2
    case batch = 3
    case ack = 4
    case goodbye = 5
    case pairCommit = 10
    case pairKey = 11
    case pairReveal = 12
    case pairConfirm = 13
    case pairCancel = 14
}

struct MacMirrorFrame: Equatable, Sendable {
    var type: MacMirrorFrameType
    var body: Data

    static let headerLength = 5

    var encoded: Data {
        var data = Data(capacity: Self.headerLength + body.count)
        let length = UInt32(1 + body.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(type.rawValue)
        data.append(body)
        return data
    }

    /// The body length a header announces and its type, or why the header is unusable.
    static func parseHeader(_ header: Data) throws -> (type: MacMirrorFrameType, bodyLength: Int) {
        guard header.count == headerLength else { throw MacMirrorError.malformed("short frame header") }
        let bytes = [UInt8](header)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length >= 1, length - 1 <= MacMirrorProtocol.maximumFrameLength else {
            throw MacMirrorError.malformed("frame length \(length)")
        }
        guard let type = MacMirrorFrameType(rawValue: bytes[4]) else {
            throw MacMirrorError.malformed("unknown frame type \(bytes[4])")
        }
        return (type, length - 1)
    }

    static func json<T: Encodable>(_ type: MacMirrorFrameType, _ value: T) throws -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return Self(type: type, body: try encoder.encode(value))
    }

    func decode<T: Decodable>(_ expected: MacMirrorFrameType, as: T.Type) throws -> T {
        guard type == expected else {
            if type == .goodbye, let goodbye = try? decodeBody(MacMirrorGoodbye.self) {
                throw MacMirrorError.peerEnded(goodbye.reason)
            }
            throw MacMirrorError.malformed("expected \(expected), received \(type)")
        }
        return try decodeBody(T.self)
    }

    private func decodeBody<T: Decodable>(_: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: body) }
        catch { throw MacMirrorError.malformed("\(type) body: \(error.localizedDescription)") }
    }
}

// MARK: - Control messages

/// iPhone to Mac, first on every mirror connection.
struct MacMirrorHello: Codable, Equatable, Sendable {
    var protocolVersion: Int
    /// The pairing this connection was opened under (`MacMirrorPairing.Agreement.identity`).
    var pairingIdentity: String
    var phoneName: String
}

/// Mac to iPhone, in reply to hello: where the mirror stands. Nil epoch means the Mac has
/// no usable position and needs a snapshot.
struct MacMirrorState: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var epoch: String?
    var cursor: Int64?
}

/// Mac to iPhone after applying a batch.
struct MacMirrorAck: Codable, Equatable, Sendable {
    var cursor: Int64
}

/// Either side, before closing on purpose.
struct MacMirrorGoodbye: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// The other side's `MacMirrorProtocol.version` is different.
        case versionMismatch
        /// The Mac is paired with a different phone, or with none.
        case notPaired
        /// A batch could not be decoded or applied; the phone should reconnect and resume.
        case applyFailed
        /// The app is going to the background or quitting.
        case closing
    }
    var reason: Reason
    var detail: String?
}

enum MacMirrorError: Error, Equatable, LocalizedError {
    case malformed(String)
    case peerEnded(MacMirrorGoodbye.Reason)
    case connectionFailed(String)
    case closed
    case timedOut
    case pairing(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            String(localized: "macMirror.error.malformed", defaultValue: "The other device sent something this version of HeartSync cannot read (\(detail)).", comment: "Mac sync error: unreadable message; the detail is technical")
        case .peerEnded(.versionMismatch):
            String(localized: "macMirror.error.version", defaultValue: "HeartSync on the iPhone and on the Mac are different versions. Update both.", comment: "Mac sync error: protocol versions differ")
        case .peerEnded(.notPaired):
            String(localized: "macMirror.error.notPaired", defaultValue: "The Mac no longer recognises this pairing. Pair again.", comment: "Mac sync error: the Mac forgot the pairing")
        case .peerEnded(.applyFailed):
            String(localized: "macMirror.error.applyFailed", defaultValue: "The Mac could not save what was sent. It will try again.", comment: "Mac sync error: the Mac failed to store a batch")
        case .peerEnded(.closing):
            String(localized: "macMirror.error.closing", defaultValue: "The other device closed the connection.", comment: "Mac sync error: the other side closed on purpose")
        case .connectionFailed(let detail):
            String(localized: "macMirror.error.connection", defaultValue: "Could not connect (\(detail)).", comment: "Mac sync error: network failure; the detail is technical")
        case .timedOut:
            String(localized: "The other device did not respond in time. Keep HeartSync open on both devices and try again.")
        case .closed:
            String(localized: "macMirror.error.closed", defaultValue: "The connection closed.", comment: "Mac sync error: the connection ended")
        case .pairing(let detail):
            detail
        }
    }
}
