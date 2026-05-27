import Foundation
import Security

/// One-shot migration from the legacy "Jellyamp" identifier to "Bolera".
/// Runs on every launch but no-ops once `bolera.migration.v1` is set.
public enum LegacyMigration {
    private static let migrationKey = "bolera.migration.v1"

    public static let userDefaultsKeyMap: [String: String] = [
        "jellyamp.shuffle":        "bolera.shuffle",
        "jellyamp.repeat":         "bolera.repeat",
        "jellyamp.crossfade":      "bolera.crossfade",
        "jellyamp.maxBitrate":     "bolera.maxBitrate",
        "jellyamp.deviceId":       "bolera.deviceId",
    ]

    public static let legacyKeychainService = "com.jellyamp.credentials"
    public static let currentKeychainService = "com.bolera.credentials"
    public static let keychainAccounts = ["server", "token", "userId", "userName"]

    public static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        for (old, new) in userDefaultsKeyMap {
            guard defaults.object(forKey: new) == nil,
                  let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
            defaults.removeObject(forKey: old)
        }

        for account in keychainAccounts {
            if let value = readKeychain(service: legacyKeychainService, account: account),
               readKeychain(service: currentKeychainService, account: account) == nil {
                writeKeychain(service: currentKeychainService, account: account, value: value)
                deleteKeychain(service: legacyKeychainService, account: account)
            }
        }

        defaults.set(true, forKey: migrationKey)
    }

    private static func readKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func writeKeychain(service: String, account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func deleteKeychain(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
