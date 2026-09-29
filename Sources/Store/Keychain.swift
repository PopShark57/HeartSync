import Foundation
import Security

/// Minimal keychain wrapper for the Oura OAuth credential this app holds.
///
/// Stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so a background refresh
/// can read it while the phone is locked, but it never syncs to iCloud or migrates to a
/// restored backup on another device.
enum Keychain {

    enum Key: String {
        /// Kept only so upgrades can remove credentials saved by pre-OAuth releases.
        case ouraPersonalAccessToken = "oura.pat"
        case ouraOAuthCredentials = "oura.oauth.credentials"
    }

    private static let service = "com.heartsync.HeartSyncChecker"

    @discardableResult
    static func set(_ value: String?, for key: Key) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// What a Keychain read found. "Nothing there" and "could not look" are different facts:
    /// the second is transient (the device is locked, or Keychain is briefly unavailable), and
    /// treating it as the first signs a user out of an account they are still signed in to.
    enum Lookup: Equatable, Sendable {
        case found(String)
        case notFound
        /// The read failed with this `OSStatus`. The item may well exist.
        case unavailable(OSStatus)
    }

    static func lookup(_ key: Key) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                // Present but not text: corrupt, not merely unreadable right now.
                return .notFound
            }
            return .found(text)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    /// The stored value, or nil for every failure. Only for callers that cannot act on the
    /// difference; anything that clears state on nil must use `lookup`.
    static func get(_ key: Key) -> String? {
        if case .found(let value) = lookup(key) { return value }
        return nil
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ key: Key) -> Bool { get(key) != nil }
}
