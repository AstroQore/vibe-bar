import Foundation

/// Keychain-backed storage for web session cookie headers owned by Vibe Bar.
///
/// Browser/WebView cookies are secrets. They must not be persisted in
/// `~/.vibebar`; that directory is only used for non-secret derived app state
/// and for one-time migration of older plaintext files.
public enum SecureCookieHeaderStore {
    public enum Provider: String, Sendable {
        case openAI = "openai"
        case claude
    }

    public enum Source: String, Sendable, CaseIterable {
        case browser
        case webView
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let cookieHeader: String
        public let storedAt: Date

        public init(cookieHeader: String, storedAt: Date = Date()) {
            self.cookieHeader = cookieHeader
            self.storedAt = storedAt
        }
    }

    public enum LoadResult: Sendable, Equatable {
        case found(String)
        case missing
        case temporarilyUnavailable
        case invalid
    }

    public static let keychainService = "com.astroqore.VibeBar.web-cookies"

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Entry?] = [:]
    private nonisolated(unsafe) static var unavailableUntilByAccount: [String: Date] = [:]
    private static let unavailableCooldown: TimeInterval = 60 * 60

    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: Data]?

    public static func account(provider: Provider, source: Source) -> String {
        "\(provider.rawValue).\(source.rawValue).cookie"
    }

    public static func load(provider: Provider, source: Source, now: Date = Date()) -> LoadResult {
        load(account: account(provider: provider, source: source), now: now)
    }

    public static func store(_ header: String, provider: Provider, source: Source, now: Date = Date()) throws {
        try store(Entry(cookieHeader: header, storedAt: now), account: account(provider: provider, source: source))
    }

    public static func delete(provider: Provider, source: Source) throws {
        try delete(account: account(provider: provider, source: source))
    }

    public static func deleteAll(provider: Provider) throws {
        for source in Source.allCases {
            try delete(provider: provider, source: source)
        }
    }

    public static func withInMemoryStoreForTesting<T>(_ operation: () throws -> T) throws -> T {
        testStoreLock.lock()
        let previous = testStore
        testStore = [:]
        testStoreLock.unlock()

        cacheLock.lock()
        let previousCache = cache
        let previousUnavailable = unavailableUntilByAccount
        cache = [:]
        unavailableUntilByAccount = [:]
        cacheLock.unlock()

        defer {
            testStoreLock.lock()
            testStore = previous
            testStoreLock.unlock()

            cacheLock.lock()
            cache = previousCache
            unavailableUntilByAccount = previousUnavailable
            cacheLock.unlock()
        }

        return try operation()
    }

    private static func load(account: String, now: Date) -> LoadResult {
        if let testResult = loadFromTestStore(account: account) {
            return testResult
        }

        cacheLock.lock()
        if let blockedUntil = unavailableUntilByAccount[account], blockedUntil > now {
            cacheLock.unlock()
            return .temporarilyUnavailable
        }
        let cached = cache[account]
        cacheLock.unlock()

        switch cached {
        case .some(.some(let entry)):
            return .found(entry.cookieHeader)
        case .some(.none):
            return .missing
        case .none:
            break
        }

        do {
            let data = try KeychainStore.readData(
                service: keychainService,
                account: account,
                useDataProtectionKeychain: true
            )
            let entry = try JSONDecoder().decode(Entry.self, from: data)
            cacheLock.lock()
            cache[account] = entry
            unavailableUntilByAccount.removeValue(forKey: account)
            cacheLock.unlock()
            return entry.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .invalid
                : .found(entry.cookieHeader)
        } catch KeychainStore.KeychainError.itemNotFound {
            cacheLock.lock()
            cache[account] = nil
            cacheLock.unlock()
            return .missing
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            cacheLock.lock()
            unavailableUntilByAccount[account] = now.addingTimeInterval(unavailableCooldown)
            cacheLock.unlock()
            return .temporarilyUnavailable
        } catch {
            return .invalid
        }
    }

    private static func store(_ entry: Entry, account: String) throws {
        let data = try JSONEncoder().encode(entry)
        if storeInTestStore(data, account: account) {
            return
        }
        try KeychainStore.writeData(
            service: keychainService,
            account: account,
            data: data,
            useDataProtectionKeychain: true
        )
        cacheLock.lock()
        cache[account] = entry
        unavailableUntilByAccount.removeValue(forKey: account)
        cacheLock.unlock()
    }

    private static func delete(account: String) throws {
        if deleteFromTestStore(account: account) {
            return
        }
        try KeychainStore.deleteItem(
            service: keychainService,
            account: account,
            useDataProtectionKeychain: true
        )
        cacheLock.lock()
        cache.removeValue(forKey: account)
        unavailableUntilByAccount.removeValue(forKey: account)
        cacheLock.unlock()
    }

    private static func loadFromTestStore(account: String) -> LoadResult? {
        testStoreLock.lock()
        guard let store = testStore else {
            testStoreLock.unlock()
            return nil
        }
        guard let data = store[account] else {
            testStoreLock.unlock()
            return .missing
        }
        testStoreLock.unlock()
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return .invalid
        }
        return .found(entry.cookieHeader)
    }

    private static func storeInTestStore(_ data: Data, account: String) -> Bool {
        testStoreLock.lock()
        defer { testStoreLock.unlock() }
        guard testStore != nil else { return false }
        testStore?[account] = data
        return true
    }

    private static func deleteFromTestStore(account: String) -> Bool {
        testStoreLock.lock()
        defer { testStoreLock.unlock() }
        guard testStore != nil else { return false }
        testStore?.removeValue(forKey: account)
        return true
    }
}
