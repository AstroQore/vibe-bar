import Foundation
import Security

/// Generic-password Keychain wrapper used for existing CLI keychain entries
/// and Vibe Bar-owned secrets.
///
/// Two storage backends:
///
/// - **Legacy login keychain** (default). Used to read items written by
///   external CLIs we don't control — Codex CLI's keychain entry,
///   Claude CLI's `Claude Code-credentials`, etc.
/// - **Data-protection keychain** (opt-in via
///   `useDataProtectionKeychain: true`). Used for vibe-bar-owned
///   items. The legacy keychain ties access ACLs to the binary's
///   cdhash, which means every ad-hoc rebuild of `Vibe Bar.app`
///   produces a new "stranger" identity and macOS prompts the user
///   for the login password to grant access. The data-protection
///   keychain doesn't have those legacy ACL prompts — items are
///   scoped to the app's code-signing identity, and the prompt
///   loop disappears.
///
/// Adapters that read CLI-written items leave the parameter at its
/// default `false`. Adapters that own their own items
/// (`MiscCredentialStore`, `CookieHeaderCache`, `ClaudeWebCookieStore`,
/// the misc provider settings UI) pass `true`.
public enum KeychainStore {
    public enum KeychainError: Error, Equatable {
        case itemNotFound
        case interactionNotAllowed
        case ambiguousItem(Int)
        case unhandledStatus(OSStatus)
    }

    public static func readData(
        service: String,
        account: String? = nil,
        useDataProtectionKeychain: Bool = false
    ) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let account {
            query[kSecAttrAccount as String] = account
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        } else {
            query[kSecMatchLimit as String] = kSecMatchLimitAll
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            if account == nil {
                if let items = result as? [Data] {
                    guard items.count == 1 else {
                        throw items.isEmpty ? KeychainError.itemNotFound : KeychainError.ambiguousItem(items.count)
                    }
                    return items[0]
                }
                if let data = result as? Data {
                    return data
                }
                throw KeychainError.itemNotFound
            }
            guard let data = result as? Data else {
                throw KeychainError.itemNotFound
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    public static func readString(
        service: String,
        account: String? = nil,
        useDataProtectionKeychain: Bool = false
    ) throws -> String {
        let data = try readData(
            service: service,
            account: account,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        guard let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return s
    }

    public static func writeData(
        service: String,
        account: String,
        data: Data,
        useDataProtectionKeychain: Bool = false
    ) throws {
        var baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            baseQuery[kSecUseDataProtectionKeychain as String] = true
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess {
                throw KeychainError.unhandledStatus(updateStatus)
            }
            return
        }
        if status != errSecSuccess {
            throw KeychainError.unhandledStatus(status)
        }
    }

    public static func writeString(
        service: String,
        account: String,
        value: String,
        useDataProtectionKeychain: Bool = false
    ) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unhandledStatus(errSecParam)
        }
        try writeData(
            service: service,
            account: account,
            data: data,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
    }

    public static func deleteItem(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool = false
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }
}
