import Foundation
import Security

/// Secret storage for API keys.
///
/// Deliberately avoids the *legacy* file keychain, whose access control is an
/// ACL bound to the app's exact code signature. Two things made that a bad
/// fit here:
///
///  * Each secret was its own item, and every item raises its **own**
///    "enter your login password" dialog — three keys meant three prompts.
///  * The bundle is ad-hoc signed, so every rebuild changes the code hash and
///    invalidates whatever "Always Allow" the user just granted. The prompt
///    came back forever.
///
/// Instead we use the **data-protection keychain** (`kSecUseDataProtectionKeychain`),
/// which gates access on the code signature directly and never shows an ACL
/// dialog: a mismatch is a silent `errSecItemNotFound`. All keys live in a
/// single JSON item, so there is at most one keychain operation per launch.
/// If the platform refuses that keychain (it needs entitlements the ad-hoc
/// build may lack), we fall back to a `0600` file in Application Support —
/// the same posture as `~/.aws/credentials` or `~/.claude.json`.
enum Keychain {
    private static let service = "dev.usta.Usta"
    /// One item holds every secret, keyed by account name.
    private static let bundleAccount = "usta.secrets"

    nonisolated(unsafe) private static var cache: [String: String]?
    private static let lock = NSLock()

    // MARK: public API

    static func get(account: String) -> String? {
        let v = all()[account]
        return (v?.isEmpty ?? true) ? nil : v
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        var map = all()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: account) } else { map[account] = trimmed }
        return writeAll(map)
    }

    @discardableResult
    static func delete(account: String) -> Bool { set("", account: account) }

    /// Every stored secret. Read once per process; the keychain/file is only
    /// touched on the first call.
    static func all() -> [String: String] {
        lock.lock()
        if let c = cache { lock.unlock(); return c }
        lock.unlock()
        let loaded = readBundle() ?? readFile() ?? [:]
        lock.lock(); cache = loaded; lock.unlock()
        return loaded
    }

    // MARK: legacy migration

    /// Do pre-bundle, per-key items still exist? Checked with
    /// `kSecReturnData: false` — asking only for attributes never decrypts a
    /// secret, so this does NOT raise the password dialog.
    static func hasLegacyItems() -> Bool {
        for acct in legacyAccounts {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess { return true }
        }
        return false
    }

    /// Pull the old per-key items into the single bundle. This *does* prompt
    /// (it decrypts), which is why it's user-initiated from Settings rather
    /// than run at launch — one prompt, once, on purpose.
    @discardableResult
    static func migrateLegacyItems() -> Int {
        var map = all()
        var moved = 0
        for acct in legacyAccounts {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let d = item as? Data,
                  let s = String(data: d, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty
            else { continue }
            map[acct] = s
            moved += 1
            // Drop the old item so the prompt can never come back for it.
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
            ] as CFDictionary)
        }
        if moved > 0 { _ = writeAll(map) }
        return moved
    }

    private static let legacyAccounts = ["usta.anthropicKey", "usta.geminiKey", "usta.openaiKey"]

    // MARK: data-protection keychain

    private static func bundleQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bundleAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func readBundle() -> [String: String]? {
        var q = bundleQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return map
    }

    @discardableResult
    private static func writeAll(_ map: [String: String]) -> Bool {
        lock.lock(); cache = map; lock.unlock()
        guard let data = try? JSONEncoder().encode(map) else { return false }

        let q = bundleQuery()
        let upd = SecItemUpdate(q as CFDictionary,
                                [kSecValueData as String: data] as CFDictionary)
        if upd == errSecSuccess { return true }
        if upd == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
        }
        // Keychain unavailable (ad-hoc build without the needed entitlement,
        // locked keychain, …) — never lose the user's keys over it.
        return writeFile(map)
    }

    // MARK: file fallback

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("usta", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("secrets.json")
    }

    private static func readFile() -> [String: String]? {
        guard let d = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: d)
        else { return nil }
        return map
    }

    @discardableResult
    private static func writeFile(_ map: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(map) else { return false }
        let url = fileURL
        do {
            try data.write(to: url, options: [.atomic])
            // Owner-only: the file sits in the user's own Library, and this
            // keeps it off-limits to other accounts on the machine.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
