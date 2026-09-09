import Foundation
import Security

/// The bearer token lives in the Keychain, not UserDefaults.
///
/// It is a credential: it authenticates every upload as the your backend
/// account, and `UserDefaults` is a plist in the app container that is included
/// in unencrypted backups. `ThisDeviceOnly` keeps it off a restored backup on
/// someone else's phone.
enum TokenStore {
    private static let service = "com.example.flocksquawk"
    private static let account = "web-bearer-token"

    /// Returns whether the token actually reached the Keychain.
    ///
    /// Discarding `SecItemAdd`'s status makes a failed write look like a
    /// successful login: the caller carries on with a token in memory, and the
    /// user is silently signed out on next launch with nothing explaining why.
    /// A write can fail for real reasons -- a missing keychain-sharing
    /// entitlement, a device in an unusual protection state -- so the failure
    /// is reported rather than swallowed.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
