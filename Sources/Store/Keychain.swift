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

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
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
