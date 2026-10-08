import Foundation
import Security

/// A single Keychain item containing every secret owned by Vibe Bar.
///
/// Source builds are ad-hoc signed, so their Keychain ACL identity changes on
/// every rebuild. Keeping Vibe Bar-owned values inside one versioned vault
/// means the app performs one non-interactive Keychain lookup instead of one
/// lookup per cookie, provider, or account. External items (CLI credentials
/// and browser Safe Storage keys) are deliberately excluded.
public enum VibeBarCredentialVault {
    public static let keychainService = "com.astroqore.VibeBar.credential-vault"
    public static let keychainAccount = "vault-v1"

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

    /// The Keychain calls the vault makes. Injectable so tests can count them
    /// without touching the login keychain.
    struct Backend: Sendable {
        /// The vault item's bytes; throws `KeychainError.itemNotFound` when
        /// there is no vault yet.
        var readVault: @Sendable () throws -> Data
        var writeVault: @Sendable (Data) throws -> Void
        /// A historical per-secret item, read once to migrate it.
        var readLegacy: @Sendable (_ service: String, _ account: String) throws -> Data
        var deleteLegacy: @Sendable (_ service: String, _ account: String) -> Void
        /// Monotonic seconds, for the cache lifetime.
        var uptime: @Sendable () -> TimeInterval

        static let keychain = Backend(
            readVault: {
                try KeychainStore.readData(service: keychainService, account: keychainAccount)
            },
            writeVault: { data in
                try KeychainStore.writeData(service: keychainService, account: keychainAccount, data: data)
            },
            readLegacy: { service, account in
                try KeychainStore.readData(service: service, account: account, useDataProtectionKeychain: true)
            },
            deleteLegacy: { service, account in
                try? KeychainStore.deleteItem(service: service, account: account, useDataProtectionKeychain: true)
            },
            uptime: { ProcessInfo.processInfo.systemUptime }
        )
    }

    private struct CachedPayload {
        let payload: Payload
        let loadedAt: TimeInterval
    }

    /// How long a decoded vault answers reads without asking the Keychain
    /// again. Every read used to cost a preflight query, a data query and a
    /// JSON decode of the whole vault, and one account reload alone reads it
    /// for every misc cookie slot and every web cookie store. Five seconds
    /// covers one refresh burst — the reload and the quota refreshes it
    /// triggers — and still sees a change another process made by the next
    /// one. Writes from this process update the cache as they persist, and
    /// `invalidateCache()` drops it outright.
    static let cacheLifetime: TimeInterval = 5

    private static let lock = NSLock()
    // Everything below is guarded by `lock`.
    nonisolated(unsafe) private static var backend: Backend = .keychain
    nonisolated(unsafe) private static var cached: CachedPayload?
    /// `service \0 account` keys whose historical per-secret item was looked
    /// for and is not there. Nothing writes those items any more, so a miss
    /// stays a miss for the life of the process; remembering it saves two
    /// Keychain queries on every read of a secret the user never stored.
    nonisolated(unsafe) private static var legacyMisses: Set<String> = []
    nonisolated(unsafe) private static var payloadDecodeCount = 0

    /// Demo mode swallows Keychain writes and must keep reading nothing back;
    /// with the user's Keychain kill switch on, nothing may be served that the
    /// Keychain was not just asked for.
    private static var cachingEnabled: Bool {
        !DemoMode.isEnabled && !KeychainAccessGate.isDisabled
    }

    /// Drop the decoded vault so the next read asks the Keychain. An account
    /// reload calls this first: it is the path a login or a sign-out takes, so
    /// it must see the Keychain as it is now, and every read after it in the
    /// same pass is then served from that one decode.
    public static func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    public static func readData(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let data = try currentPayload().data(service: service, account: account) {
            return data
        }

        // Seamless transition for an already-authorized build: import the
        // historical per-secret item on first read. Queries stay non-
        // interactive, so a newly signed build never brings back the prompt
        // storm. Inaccessible stale items fail closed and can be re-imported
        // through their owning provider's settings.
        let legacyKey = service + "\u{0}" + account
        if legacyMisses.contains(legacyKey) {
            throw KeychainStore.KeychainError.itemNotFound
        }
        let legacy: Data
        do {
            legacy = try backend.readLegacy(service, account)
        } catch KeychainStore.KeychainError.itemNotFound {
            if cachingEnabled { legacyMisses.insert(legacyKey) }
            throw KeychainStore.KeychainError.itemNotFound
        }
        // Migrate into the vault as it is in the Keychain now, not into a
        // cached copy that another process may have moved on from.
        var payload = try loadFreshPayload() ?? Payload()
        payload.set(legacy, service: service, account: account)
        try persist(payload)
        backend.deleteLegacy(service, account)
        return legacy
    }

    public static func readString(service: String, account: String) throws -> String {
        let data = try readData(service: service, account: account)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStore.KeychainError.itemNotFound
        }
        return value
    }

    /// Writes read the vault fresh, never from the cache, so a change another
    /// process made is merged rather than overwritten.
    public static func writeData(service: String, account: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        var payload = try loadFreshPayload() ?? Payload()
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
        guard var payload = try loadFreshPayload(),
              payload.remove(service: service, account: account)
        else {
            throw KeychainStore.KeychainError.itemNotFound
        }
        try persist(payload)
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

    /// The decoded vault: the cached copy while it is fresh, otherwise one
    /// Keychain read and decode. Caller holds `lock`.
    private static func currentPayload() throws -> Payload {
        if cachingEnabled, let cached {
            let age = backend.uptime() - cached.loadedAt
            if age >= 0, age < cacheLifetime {
                return cached.payload
            }
        }
        return try loadFreshPayload() ?? Payload()
    }

    /// Reads and decodes the vault item, bypassing the cache, and makes the
    /// result the cache. `nil` when there is no vault item yet. Caller holds
    /// `lock`.
    private static func loadFreshPayload() throws -> Payload? {
        do {
            let data = try backend.readVault()
            let payload = try decodePayload(data)
            payloadDecodeCount += 1
            remember(payload)
            return payload
        } catch KeychainStore.KeychainError.itemNotFound {
            remember(Payload())
            return nil
        } catch {
            // Fail closed exactly as an uncached read did: the next read asks
            // the Keychain again rather than serving what was there before.
            cached = nil
            throw error
        }
    }

    private static func persist(_ payload: Payload) throws {
        let data = try encodePayload(payload)
        try backend.writeVault(data)
        remember(payload)
    }

    private static func remember(_ payload: Payload) {
        cached = cachingEnabled
            ? CachedPayload(payload: payload, loadedAt: backend.uptime())
            : nil
    }

    // MARK: - Testing

    /// Runs `body` against `backend` with an empty cache, then restores the
    /// Keychain backend. Tests only.
    static func withBackendForTesting<T>(_ backend: Backend, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = self.backend
        self.backend = backend
        cached = nil
        legacyMisses = []
        payloadDecodeCount = 0
        lock.unlock()
        defer {
            lock.lock()
            self.backend = previous
            cached = nil
            legacyMisses = []
            payloadDecodeCount = 0
            lock.unlock()
        }
        return try body()
    }

    /// How many times the vault item has been decoded since the test backend
    /// was installed.
    static var payloadDecodeCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return payloadDecodeCount
    }
}
