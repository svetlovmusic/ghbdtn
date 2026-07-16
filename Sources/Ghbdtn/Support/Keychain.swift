import Foundation
import Security

/// Minimal Keychain helper for storing the optional cloud-AI API key.
///
/// The key is never written to `UserDefaults` or any plist — only to the
/// login keychain, so it stays out of settings backups and screen shares.
enum Keychain {
    private static let service = "com.ghbdtn.app"

    static func set(_ value: String?, account: String) {
        // Delete any existing item first for a clean upsert.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            return
        }
        var add = base
        add[kSecValueData as String] = data
        // WhenUnlocked + ThisDeviceOnly: the key is unreadable while the Mac is
        // locked, and never leaves this device (no iCloud Keychain sync, not in
        // backups) — the right posture for a credential a background agent holds.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("Keychain set failed for \(account): \(status)")
        }
    }

    /// One-time upgrade of existing items to the stronger accessibility class:
    /// read each present value and re-store it, so `set` re-applies
    /// WhenUnlockedThisDeviceOnly to keys written by an older build.
    static func upgradeAccessibility(accounts: [String]) {
        for account in accounts {
            if let value = get(account: account), !value.isEmpty {
                set(value, account: account)
            }
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
