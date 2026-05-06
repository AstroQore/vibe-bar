import Foundation
import Security

/// Generic-password Keychain wrapper used for existing CLI keychain entries
/// and Vibe Bar-owned secrets.
public enum KeychainStore {
    public enum KeychainError: Error, Equatable {
        case itemNotFound
        case interactionNotAllowed
        case ambiguousItem(Int)
        case unhandledStatus(OSStatus)
    }

    public static func readData(service: String, account: String? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true
        ]
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

    public static func readString(service: String, account: String? = nil) throws -> String {
        let data = try readData(service: service, account: account)
        guard let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return s
    }

    public static func writeData(service: String, account: String, data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

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

    public static func writeString(service: String, account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unhandledStatus(errSecParam)
        }
        try writeData(service: service, account: account, data: data)
    }

    public static func deleteItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }
}
