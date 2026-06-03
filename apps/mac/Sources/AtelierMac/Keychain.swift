import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing API keys at rest instead
/// of plaintext UserDefaults. Generic-password items, scoped by a fixed
/// service + per-key account name.
enum Keychain {
    private static let service = "dev.atelier.Atelier"

    /// Store (or overwrite) a secret for `account`. Empty value deletes it.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        if value.isEmpty { return delete(account: account) }
        let data = Data(value.utf8)
        // Try update first.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updStatus == errSecSuccess { return true }
        if updStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Read a secret. Returns nil if absent.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
