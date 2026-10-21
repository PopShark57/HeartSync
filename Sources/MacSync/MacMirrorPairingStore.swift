import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One completed pairing, as each side keeps it.
///
/// The phone keeps one per paired Mac; a Mac keeps at most one, for the phone it mirrors.
/// Stored in the device-only Keychain like the Oura credential, never in a file or defaults,
/// because the key is what lets a device send or receive the history.
struct MacMirrorPairingRecord: Codable, Equatable, Sendable, Identifiable {
    /// The TLS pre-shared key identity (`MacMirrorPairing.Agreement.identity`).
    var identity: String
    var key: Data
    /// The other device.
    var peer: MacMirrorPairing.Identity
    var pairedAt: Date

    var id: String { identity }
    var symmetricKey: SymmetricKey { SymmetricKey(data: key) }

    init(agreement: MacMirrorPairing.Agreement, role: MacMirrorPairing.Role, pairedAt: Date = .now) {
        self.init(
            identity: agreement.identity,
            key: agreement.key.withUnsafeBytes { Data($0) },
            peer: role == .phone ? agreement.mac : agreement.phone,
            pairedAt: pairedAt
        )
    }

    init(identity: String, key: Data, peer: MacMirrorPairing.Identity, pairedAt: Date) {
        self.identity = identity
        self.key = key
        self.peer = peer
        self.pairedAt = pairedAt
    }
}

/// The pairing records in the Keychain.
enum MacMirrorPairingStore {
    enum Outcome: Equatable, Sendable {
        case records([MacMirrorPairingRecord])
        /// The Keychain could not be read right now (a locked device). Not the same as none:
        /// treating it as none would unpair.
        case unavailable
    }

    static func load() -> Outcome {
        switch Keychain.lookup(.macMirrorPairings) {
        case .found(let text):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // An undecodable value is treated as none, as a corrupt Oura credential is.
            return .records((try? decoder.decode([MacMirrorPairingRecord].self, from: Data(text.utf8))) ?? [])
        case .notFound:
            return .records([])
        case .unavailable:
            return .unavailable
        }
    }

    @discardableResult
    static func save(_ records: [MacMirrorPairingRecord]) -> Bool {
        guard !records.isEmpty else { return Keychain.delete(.macMirrorPairings) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records), let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return Keychain.set(text, for: .macMirrorPairings)
    }
}

/// This install's id, which names it to the other device. Random, kept in defaults, and not
/// secret: it is shown in no interface and identifies nothing outside HeartSync.
enum MacMirrorDeviceIdentity {
    private static let key = "macMirror.deviceID"

    static func current(defaults: UserDefaults = .standard) -> UUID {
        if let text = defaults.string(forKey: key), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    /// The name the other device shows for this one. On iOS 16 and later this is the model
    /// ("iPhone"), not the name the person gave it, unless the app is entitled otherwise.
    @MainActor
    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}
