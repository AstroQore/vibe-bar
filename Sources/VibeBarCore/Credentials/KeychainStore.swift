import Foundation
import Security

/// Generic-password Keychain wrapper used for existing CLI keychain entries
/// and Vibe Bar-owned secrets.
///
/// Two storage backends:
///
/// - **Legacy login keychain** (default). Used to read items written by
///   external CLIs we don't control — Codex CLI's keychain entry,
///   Claude CLI's `Claude Code-credentials`, etc. Vibe Bar-owned items
///   are also written here so source-built, ad-hoc-signed app bundles
///   keep the same persistence behaviour as Codex Bar.
/// - **Data-protection keychain** (legacy migration only). Older
///   builds attempted to put Vibe Bar-owned items there. Reads for
///   those callers still probe it if the login keychain has no item,
///   then copy the item back to the login keychain and remove the
///   legacy copy best-effort.
///
/// Adapters that read CLI-written items leave the parameter at its
/// default `false`. Adapters that own their own items pass `true` so
/// old data-protection items can be migrated, but writes still land in
/// the regular login keychain.
public enum KeychainStore {
    private static let missingEntitlementStatus: OSStatus = -34018

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
        do {
            return try readDataOnce(
                service: service,
                account: account,
                useDataProtectionKeychain: false
            )
        } catch KeychainError.itemNotFound where useDataProtectionKeychain {
            let migrated: Data
            do {
                migrated = try readDataOnce(
                    service: service,
                    account: account,
                    useDataProtectionKeychain: true
                )
            } catch KeychainError.unhandledStatus(let status) where status == missingEntitlementStatus {
                throw KeychainError.itemNotFound
            }
            if let account {
                try? writeDataOnce(
                    service: service,
                    account: account,
                    data: migrated,
                    useDataProtectionKeychain: false
                )
                try? deleteItemOnce(
                    service: service,
                    account: account,
                    useDataProtectionKeychain: true
                )
            }
            return migrated
        }
    }

    private static func readDataOnce(
        service: String,
        account: String?,
        useDataProtectionKeychain: Bool
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
        try writeDataOnce(
            service: service,
            account: account,
            data: data,
            useDataProtectionKeychain: false
        )
        if useDataProtectionKeychain {
            try? deleteItemOnce(
                service: service,
                account: account,
                useDataProtectionKeychain: true
            )
        }
    }

    private static func writeDataOnce(
        service: String,
        account: String,
        data: Data,
        useDataProtectionKeychain: Bool
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

        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
            if retryStatus != errSecSuccess {
                throw KeychainError.unhandledStatus(retryStatus)
            }
            return
        }
        if addStatus != errSecSuccess {
            throw KeychainError.unhandledStatus(addStatus)
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
        try deleteItemOnce(
            service: service,
            account: account,
            useDataProtectionKeychain: false
        )
        if useDataProtectionKeychain {
            try? deleteItemOnce(
                service: service,
                account: account,
                useDataProtectionKeychain: true
            )
        }
    }

    private static func deleteItemOnce(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool
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
