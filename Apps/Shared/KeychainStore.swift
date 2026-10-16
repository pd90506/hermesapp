import Foundation
import Security

/// Tiny generic-password Keychain wrapper for the gateway secret.
enum KeychainStore {
    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not save the secret to the Keychain: \(message)"
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "hermesapp"

    /// Data-protection keychain first (iOS-style; on macOS it needs a signed
    /// build with an application-identifier entitlement and otherwise fails with
    /// errSecMissingEntitlement, -34018). On macOS, fall back to the legacy
    /// file-based keychain so unsigned local builds still persist the secret.
    private static var variants: [Bool] {
        #if os(macOS)
        [true, false]
        #else
        [true]
        #endif
    }

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    static func read(account: String) -> String? {
        for dataProtection in variants {
            var query = baseQuery(account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                let data = item as? Data, let value = String(data: data, encoding: .utf8)
            {
                return value
            }
        }
        return nil
    }

    /// Replaces (or with an empty value, deletes) the secret. An unchanged secret is left
    /// alone: every connect saves it, and re-creating the item each time is needless churn.
    static func write(_ value: String, account: String) throws {
        if !value.isEmpty, read(account: account) == value { return }
        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in variants {
            let query = baseQuery(account: account, dataProtection: dataProtection)
            SecItemDelete(query as CFDictionary)
            guard !value.isEmpty else { continue }
            var attributes = query
            attributes[kSecValueData as String] = Data(value.utf8)
            // Not migrated to other devices through backups.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            lastStatus = SecItemAdd(attributes as CFDictionary, nil)
            if lastStatus == errSecSuccess { return }
            if lastStatus != errSecMissingEntitlement { break }
        }
        if !value.isEmpty, lastStatus != errSecSuccess { throw Failure(status: lastStatus) }
    }
}
