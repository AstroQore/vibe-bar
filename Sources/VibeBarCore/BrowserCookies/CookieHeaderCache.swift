import Foundation

/// Per-provider cache for the resolved `Cookie:` header.
///
/// The header itself is the secret — it carries the user's session
/// JWT or auth-ticket — so this lives in Keychain (service
/// `com.astroqore.VibeBar.web-cookies`, account
/// `misc.<tool.rawValue>.cookie`) rather than `~/.vibebar/`.
///
/// Adapter flow:
/// 1. On refresh, call `load(for:)`. If a cached header exists, use
///    it directly and skip the SweetCookieKit import dance.
/// 2. If absent or stale, run the importer, then `store(...)` the
///    new header.
/// 3. On a 401 / "stale cookie" response, `clear(for:)` and let the
///    next refresh re-import.
///
/// Codexbar's version supports per-account "scopes" (multiple Codex
/// accounts in one user). Vibe Bar treats each `ToolType` as
/// single-account today; if multi-account ever lands for a misc
/// provider, add a scope key here.
public enum CookieHeaderCache {
    public struct Entry: Codable, Sendable, Equatable {
        public let cookieHeader: String
        public let storedAt: Date
        /// Human-readable label of where the header came from
        /// ("Chrome (Default)", "manual paste", etc.). Surfaced on
        /// the misc card.
        public let sourceLabel: String

        public init(cookieHeader: String, storedAt: Date, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.storedAt = storedAt
            self.sourceLabel = sourceLabel
        }
    }

    public static let keychainService = SecureCookieHeaderStore.keychainService
    private static let legacyKeychainService = "com.astroqore.VibeBar.misc"

    public static func keychainAccount(for tool: ToolType) -> String {
        precondition(tool.isMisc, "CookieHeaderCache requested for primary tool: \(tool)")
        return "misc.\(tool.rawValue).cookie"
    }

    private static func legacyKeychainAccount(for tool: ToolType) -> String {
        precondition(tool.isMisc, "CookieHeaderCache requested for primary tool: \(tool)")
        return "cookie.\(tool.rawValue)"
    }

    public static func load(for tool: ToolType) -> Entry? {
        guard tool.isMisc else { return nil }
        if let entry = loadEntry(
            tool: tool,
            service: keychainService,
            account: keychainAccount(for: tool),
            dataProtectionOnly: false
        ) {
            SafeLog.warn("diag CookieHeaderCache.load tool=\(tool.rawValue) → primary HIT headerLen=\(entry.cookieHeader.count) src=\(entry.sourceLabel)")
            return entry
        }
        let acct = keychainAccount(for: tool)
        SafeLog.warn("diag CookieHeaderCache.load tool=\(tool.rawValue) → primary MISS svc=\(keychainService) acct=\(acct)")

        guard let legacy = loadEntry(
            tool: tool,
            service: legacyKeychainService,
            account: legacyKeychainAccount(for: tool),
            dataProtectionOnly: true
        ) else {
            SafeLog.warn("diag CookieHeaderCache.load tool=\(tool.rawValue) → legacy MISS too, returning nil")
            return nil
        }
        SafeLog.warn("diag CookieHeaderCache.load tool=\(tool.rawValue) → legacy HIT, migrating")

        _ = store(
            for: tool,
            cookieHeader: legacy.cookieHeader,
            sourceLabel: legacy.sourceLabel,
            now: legacy.storedAt
        )
        try? KeychainStore.deleteItemFromDataProtectionKeychainOnly(
            service: legacyKeychainService,
            account: legacyKeychainAccount(for: tool)
        )
        return legacy
    }

    @discardableResult
    public static func store(
        for tool: ToolType,
        cookieHeader: String,
        sourceLabel: String,
        now: Date = Date()
    ) -> Bool {
        guard tool.isMisc else { return false }
        guard let normalized = CookieHeaderNormalizer.normalize(cookieHeader),
              !normalized.isEmpty else {
            SafeLog.warn("diag CookieHeaderCache.store tool=\(tool.rawValue) → normalize empty, clearing")
            clear(for: tool)
            return false
        }
        let entry = Entry(cookieHeader: normalized, storedAt: now, sourceLabel: sourceLabel)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entry)
            try KeychainStore.writeData(
                service: keychainService,
                account: keychainAccount(for: tool),
                data: data,
                useDataProtectionKeychain: true
            )
            let acct = keychainAccount(for: tool)
            SafeLog.warn("diag CookieHeaderCache.store tool=\(tool.rawValue) → WROTE svc=\(keychainService) acct=\(acct) headerLen=\(normalized.count) src=\(sourceLabel)")
            return true
        } catch {
            let errStr = String(describing: error)
            SafeLog.warn("diag CookieHeaderCache.store tool=\(tool.rawValue) → ERROR \(errStr)")
            SafeLog.error("Cookie cache store failed for \(tool.rawValue): \(error)")
            return false
        }
    }

    @discardableResult
    public static func clear(for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        do {
            try KeychainStore.deleteItem(
                service: keychainService,
                account: keychainAccount(for: tool),
                useDataProtectionKeychain: true
            )
            try? KeychainStore.deleteItemFromDataProtectionKeychainOnly(
                service: legacyKeychainService,
                account: legacyKeychainAccount(for: tool)
            )
            return true
        } catch KeychainStore.KeychainError.itemNotFound {
            try? KeychainStore.deleteItemFromDataProtectionKeychainOnly(
                service: legacyKeychainService,
                account: legacyKeychainAccount(for: tool)
            )
            return false
        } catch {
            SafeLog.warn("Cookie cache clear failed for \(tool.rawValue): \(error)")
            return false
        }
    }

    /// Wipe every misc provider's cached cookie header. Exposed for
    /// the Settings panel "Clear all browser cookies" action.
    @discardableResult
    public static func clearAll() -> Int {
        var cleared = 0
        for tool in ToolType.miscProviders where clear(for: tool) {
            cleared += 1
        }
        return cleared
    }

    private static func loadEntry(
        tool: ToolType,
        service: String,
        account: String,
        dataProtectionOnly: Bool
    ) -> Entry? {
        do {
            let data = dataProtectionOnly
                ? try KeychainStore.readDataFromDataProtectionKeychainOnly(
                    service: service,
                    account: account
                )
                : try KeychainStore.readData(
                    service: service,
                    account: account,
                    useDataProtectionKeychain: true
                )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Entry.self, from: data)
        } catch KeychainStore.KeychainError.itemNotFound {
            return nil
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            SafeLog.info("Cookie cache temporarily unavailable for \(tool.rawValue)")
            return nil
        } catch {
            SafeLog.warn("Cookie cache load failed for \(tool.rawValue): \(error)")
            return nil
        }
    }
}
