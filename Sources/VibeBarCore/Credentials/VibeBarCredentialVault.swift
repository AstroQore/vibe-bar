import Foundation
import Security

/// A single Keychain item containing every secret owned by Vibe Bar.
///
/// Source builds are ad-hoc signed, so their Keychain ACL identity changes on
/// every rebuild. Keeping Vibe Bar-owned values inside one versioned vault
/// means a rebuild has one item to repair instead of one prompt per cookie,
/// provider, or account. External items (CLI credentials and browser Safe
/// Storage keys) are deliberately excluded.
public enum VibeBarCredentialVault {
    public static let keychainService = "com.astroqore.VibeBar.credential-vault"
    public static let keychainAccount = "vault-v1"
    public static let stagingKeychainAccountPrefix = "vault-v1.migration-staging"

    public struct Entry: Codable, Sendable, Equatable {
        public let service: String
        public let account: String
        public var data: Data

        public init(service: String, account: String, data: Data) {
            self.service = service
            self.account = account
            self.data = data
        }
    }

    public struct Payload: Codable, Sendable, Equatable {
        public var version: Int
        public var entries: [Entry]

        public init(version: Int = 1, entries: [Entry] = []) {
            self.version = version
            self.entries = Self.normalized(entries)
        }

        public func data(service: String, account: String) -> Data? {
            entries.first { $0.service == service && $0.account == account }?.data
        }

        public mutating func set(_ data: Data, service: String, account: String) {
            entries.removeAll { $0.service == service && $0.account == account }
            entries.append(Entry(service: service, account: account, data: data))
            entries = Self.normalized(entries)
        }

        @discardableResult
        public mutating func remove(service: String, account: String) -> Bool {
            let originalCount = entries.count
            entries.removeAll { $0.service == service && $0.account == account }
            return entries.count != originalCount
        }

        private static func normalized(_ entries: [Entry]) -> [Entry] {
            var unique: [String: Entry] = [:]
            for entry in entries {
                unique[entry.service + "\u{0}" + entry.account] = entry
            }
            return unique.values.sorted {
                $0.service == $1.service ? $0.account < $1.account : $0.service < $1.service
            }
        }
    }

    private static let lock = NSLock()

    public static func readData(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var payload = try loadPayloadOrEmpty()
        if let data = payload.data(service: service, account: account) {
            return data
        }

        // Seamless transition for an already-authorized build: import the
        // historical per-secret item on first read. Queries stay non-
        // interactive, so a newly signed build never brings back the prompt
        // storm; Settings → Keychain Access handles inaccessible old items.
        let legacy = try KeychainStore.readData(
            service: service,
            account: account,
            useDataProtectionKeychain: true
        )
        payload.set(legacy, service: service, account: account)
        try persist(payload)
        try? KeychainStore.deleteItem(
            service: service,
            account: account,
            useDataProtectionKeychain: true
        )
        return legacy
    }

    public static func readString(service: String, account: String) throws -> String {
        let data = try readData(service: service, account: account)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStore.KeychainError.itemNotFound
        }
        return value
    }

    public static func writeData(service: String, account: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        var payload = try loadPayloadOrEmpty()
        payload.set(data, service: service, account: account)
        try persist(payload)
    }

    public static func writeString(service: String, account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStore.KeychainError.unhandledStatus(errSecParam)
        }
        try writeData(service: service, account: account, data: data)
    }

    public static func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var payload = try loadPayload()
        guard payload.remove(service: service, account: account) else {
            throw KeychainStore.KeychainError.itemNotFound
        }
        try persist(payload)
    }

    /// Replaces the complete payload after the explicit password-assisted
    /// migration in Settings. This is intentionally public so the authorizer
    /// can make migration transactional: old items are deleted only after
    /// this write succeeds.
    public static func replacePayload(_ payload: Payload) throws {
        lock.lock()
        defer { lock.unlock() }
        try persist(Payload(version: payload.version, entries: payload.entries))
    }

    public static func decodePayload(_ data: Data) throws -> Payload {
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard decoded.version == 1 else {
            throw KeychainStore.KeychainError.unhandledStatus(errSecDecode)
        }
        return Payload(version: decoded.version, entries: decoded.entries)
    }

    public static func encodePayload(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func loadPayload() throws -> Payload {
        let data = try KeychainStore.readData(
            service: keychainService,
            account: keychainAccount
        )
        return try decodePayload(data)
    }

    private static func loadPayloadOrEmpty() throws -> Payload {
        do {
            return try loadPayload()
        } catch KeychainStore.KeychainError.itemNotFound {
            return Payload()
        }
    }

    private static func persist(_ payload: Payload) throws {
        let data = try encodePayload(payload)
        try KeychainStore.writeData(
            service: keychainService,
            account: keychainAccount,
            data: data
        )
    }
}
