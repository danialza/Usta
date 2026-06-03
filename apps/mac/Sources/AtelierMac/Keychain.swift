import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing API keys at rest instead
/// of plaintext UserDefaults. Generic-password items, scoped by a fixed
/// service + per-key account name.
enum Keychain {
    private static let service = "dev.atelier.Atelier"
    /// In-process cache so repeated reads of the same account don't re-hit
    /// SecItem (each call can pop a password prompt for unsigned binaries).
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// Store (or overwrite) a secret for `account`. Empty value deletes it.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        cacheLock.lock(); cache[account] = value.isEmpty ? nil : value; cacheLock.unlock()
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

    /// Read a secret. Returns nil if absent. Cached after first hit so
    /// repeated reads don't re-prompt the keychain on each call.
    static func get(account: String) -> String? {
        cacheLock.lock()
        if let v = cache[account] { cacheLock.unlock(); return v }
        cacheLock.unlock()
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
        let s = String(data: data, encoding: .utf8)
        if let s {
            cacheLock.lock(); cache[account] = s; cacheLock.unlock()
        }
        return s
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        cacheLock.lock(); cache.removeValue(forKey: account); cacheLock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
