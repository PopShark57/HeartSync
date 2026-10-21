import CryptoKit
import Foundation

/// Pairing a phone with a Mac: an ephemeral X25519 exchange that the person authenticates by
/// comparing a six-digit code on both screens, as Bluetooth numeric comparison does.
///
/// Nothing secret crosses the network, so the pairing channel itself is plain TCP. What stops
/// a device in the middle is the code: it is derived from both public keys, and the phone
/// commits to its key (sends a hash of it) before it sees the Mac's. An attacker relaying the
/// exchange must pick its own keys before learning what the honest code will be, so it
/// matches the code on the other screen with probability one in a million, once per attempt,
/// and an attempt needs the person to confirm it.
///
/// Both sides then derive the same 256-bit key from the exchange. Every later connection uses
/// it as a TLS pre-shared key (`MacMirrorTransport.syncParameters`), so only this phone can
/// send to this Mac, and only this Mac can read what the phone sends.
///
/// The phone is the initiator:
///
/// 1. phone → Mac: `Commit` (identity, SHA-256 of its public key and nonce)
/// 2. Mac → phone: `KeyShare` (identity, public key, nonce)
/// 3. phone → Mac: `Reveal` (public key, nonce); both now show the code
/// 4. each side, once its person confirms the codes match: `Confirmation`
enum MacMirrorPairing {
    struct Identity: Codable, Equatable, Sendable {
        /// The device's install id (`MacMirrorDeviceIdentity`).
        var id: UUID
        var name: String
    }

    struct Commit: Codable, Equatable, Sendable {
        var protocolVersion: Int
        var phone: Identity
        var commitment: Data
    }

    struct KeyShare: Codable, Equatable, Sendable {
        var protocolVersion: Int
        var mac: Identity
        var publicKey: Data
        var nonce: Data
    }

    struct Reveal: Codable, Equatable, Sendable {
        var publicKey: Data
        var nonce: Data
    }

    struct Confirmation: Codable, Equatable, Sendable {
        var tag: Data
    }

    enum Role: UInt8, Sendable {
        case phone = 1
        case mac = 2
    }

    /// What both sides agree on once the exchange completes.
    struct Agreement: Sendable {
        let phone: Identity
        let mac: Identity
        /// The six digits each person compares, zero-padded.
        let code: String
        /// The TLS pre-shared key for every later connection.
        let key: SymmetricKey
        /// The TLS pre-shared key identity, which also names the pairing on both sides.
        let identity: String
        private let confirmationKey: SymmetricKey
        private let transcript: Data

        fileprivate init(shared: SharedSecret, transcript: Data, phone: Identity, mac: Identity) {
            self.phone = phone
            self.mac = mac
            self.transcript = transcript
            let derive = { (label: String, count: Int) in
                shared.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: transcript,
                    sharedInfo: Data(label.utf8),
                    outputByteCount: count
                )
            }
            let codeBytes = derive("heartsync-mirror-code", 4).withUnsafeBytes { Array($0) }
            let number = codeBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
            code = String(format: "%06u", number)
            key = derive("heartsync-mirror-psk", 32)
            confirmationKey = derive("heartsync-mirror-confirm", 32)
            identity = "hsm-" + transcript.prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        /// The code spaced for reading aloud: "123 456".
        var displayCode: String { "\(code.prefix(3)) \(code.suffix(3))" }

        /// Sent once this side's person has confirmed the codes match.
        func confirmation(from role: Role) -> Confirmation {
            Confirmation(tag: Data(HMAC<SHA256>.authenticationCode(
                for: Data([role.rawValue]) + transcript,
                using: confirmationKey
            )))
        }

        /// Whether `confirmation` came from the other side of this exchange.
        func verifies(_ confirmation: Confirmation, from role: Role) -> Bool {
            HMAC<SHA256>.isValidAuthenticationCode(
                confirmation.tag,
                authenticating: Data([role.rawValue]) + transcript,
                using: confirmationKey
            )
        }
    }

    // MARK: - Phone

    struct Initiator {
        let identity: Identity
        private let privateKey = Curve25519.KeyAgreement.PrivateKey()
        private let nonce = MacMirrorPairing.randomNonce()

        init(identity: Identity) {
            self.identity = identity
        }

        var commit: Commit {
            Commit(
                protocolVersion: MacMirrorProtocol.version,
                phone: identity,
                commitment: MacMirrorPairing.commitment(publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
            )
        }

        /// The reveal to send and the agreement, once the Mac's key share arrives.
        func receive(_ share: KeyShare) throws -> (Reveal, Agreement) {
            guard share.protocolVersion == MacMirrorProtocol.version else {
                throw MacMirrorError.peerEnded(.versionMismatch)
            }
            let peerKey = try MacMirrorPairing.publicKey(share.publicKey)
            try MacMirrorPairing.checkNonce(share.nonce)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
            let transcript = MacMirrorPairing.transcript(
                phone: identity,
                mac: share.mac,
                phoneKey: privateKey.publicKey.rawRepresentation,
                macKey: share.publicKey,
                phoneNonce: nonce,
                macNonce: share.nonce
            )
            return (
                Reveal(publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce),
                Agreement(shared: shared, transcript: transcript, phone: identity, mac: share.mac)
            )
        }
    }

    // MARK: - Mac

    struct Responder {
        let identity: Identity
        private let privateKey = Curve25519.KeyAgreement.PrivateKey()
        private let nonce = MacMirrorPairing.randomNonce()
        private var commit: Commit?

        init(identity: Identity) {
            self.identity = identity
        }

        /// The key share to send in reply to a phone's commitment.
        mutating func receive(_ commit: Commit) throws -> KeyShare {
            guard commit.protocolVersion == MacMirrorProtocol.version else {
                throw MacMirrorError.peerEnded(.versionMismatch)
            }
            guard commit.commitment.count == SHA256.byteCount else {
                throw MacMirrorError.malformed("commitment length")
            }
            self.commit = commit
            return KeyShare(
                protocolVersion: MacMirrorProtocol.version,
                mac: identity,
                publicKey: privateKey.publicKey.rawRepresentation,
                nonce: nonce
            )
        }

        /// The agreement, once the phone reveals the key it committed to.
        func receive(_ reveal: Reveal) throws -> Agreement {
            guard let commit else { throw MacMirrorError.malformed("reveal before commitment") }
            guard MacMirrorPairing.commitment(publicKey: reveal.publicKey, nonce: reveal.nonce) == commit.commitment else {
                throw MacMirrorError.pairing(String(
                    localized: "macMirror.pairing.commitmentMismatch",
                    defaultValue: "The iPhone's key did not match the one it promised. Pairing was stopped.",
                    comment: "Mac pairing failed: the commitment check failed, which suggests interference"
                ))
            }
            let peerKey = try MacMirrorPairing.publicKey(reveal.publicKey)
            try MacMirrorPairing.checkNonce(reveal.nonce)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
            let transcript = MacMirrorPairing.transcript(
                phone: commit.phone,
                mac: identity,
                phoneKey: reveal.publicKey,
                macKey: privateKey.publicKey.rawRepresentation,
                phoneNonce: reveal.nonce,
                macNonce: nonce
            )
            return Agreement(shared: shared, transcript: transcript, phone: commit.phone, mac: identity)
        }
    }

    // MARK: - Shared steps

    static let nonceLength = 32

    private static func randomNonce() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    private static func checkNonce(_ nonce: Data) throws {
        guard nonce.count == nonceLength else { throw MacMirrorError.malformed("nonce length") }
    }

    private static func publicKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) }
        catch { throw MacMirrorError.malformed("public key") }
    }

    static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("heartsync-mirror-commit".utf8) + publicKey + nonce))
    }

    /// Everything both sides saw, each field length-prefixed so no two different exchanges
    /// can produce the same bytes.
    private static func transcript(
        phone: Identity,
        mac: Identity,
        phoneKey: Data,
        macKey: Data,
        phoneNonce: Data,
        macNonce: Data
    ) -> Data {
        var data = Data("heartsync-mirror-pairing-v\(MacMirrorProtocol.version)".utf8)
        for field in [
            Data(phone.id.uuidString.utf8), Data(phone.name.utf8),
            Data(mac.id.uuidString.utf8), Data(mac.name.utf8),
            phoneKey, macKey, phoneNonce, macNonce,
        ] {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(field)
        }
        return Data(SHA256.hash(data: data))
    }
}
