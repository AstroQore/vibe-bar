import Foundation

public enum QuotaCacheStore {
    struct StoredQuota: Codable {
        var tool: ToolType
        var buckets: [QuotaBucket]
        var plan: String?
        var queriedAt: Date

        init(_ quota: AccountQuota) {
            self.tool = quota.tool
            self.buckets = quota.buckets
            self.plan = quota.plan
            self.queriedAt = quota.queriedAt
        }

        func quota(accountId: String) -> AccountQuota {
            AccountQuota(
                accountId: accountId,
                tool: tool,
                buckets: buckets,
                plan: plan,
                email: nil,
                queriedAt: queriedAt,
                error: nil,
                providerExtras: nil
            )
        }
    }

    public static func loadAll(accountIds: [String]) -> [String: AccountQuota] {
        var out: [String: AccountQuota] = [:]
        for accountId in Set(accountIds) {
            guard let quota = load(accountId: accountId) else { continue }
            out[accountId] = quota
        }
        return out
    }

    public static func load(accountId: String) -> AccountQuota? {
        if let stored = try? VibeBarLocalStore.readJSON(StoredQuota.self, from: url(for: accountId)) {
            return stored.quota(accountId: accountId)
        }

        guard let legacy = try? VibeBarLocalStore.readJSON(AccountQuota.self, from: legacyURL(for: accountId)) else {
            return nil
        }
        let sanitized = AccountQuota(
            accountId: accountId,
            tool: legacy.tool,
            buckets: legacy.buckets,
            plan: legacy.plan,
            email: nil,
            queriedAt: legacy.queriedAt,
            error: nil,
            providerExtras: nil
        )
        try? save(sanitized)
        try? VibeBarLocalStore.deleteFile(at: legacyURL(for: accountId))
        return sanitized
    }

    static func cacheFileComponent(for accountId: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "quota-v1", rawValue: accountId)
    }

    public static func save(_ quota: AccountQuota) throws {
        try VibeBarLocalStore.writeJSON(StoredQuota(quota), to: url(for: quota.accountId))
        try? VibeBarLocalStore.deleteFile(at: legacyURL(for: quota.accountId))
    }

    public static func delete(accountId: String) throws {
        try VibeBarLocalStore.deleteFile(at: url(for: accountId))
        try VibeBarLocalStore.deleteFile(at: legacyURL(for: accountId))
    }

    private static func url(for accountId: String) -> URL {
        VibeBarLocalStore.quotaDirectory
            .appendingPathComponent(cacheFileComponent(for: accountId))
            .appendingPathExtension("json")
    }

    private static func legacyURL(for accountId: String) -> URL {
        VibeBarLocalStore.quotaDirectory
            .appendingPathComponent(VibeBarLocalStore.safeFileComponent(accountId))
            .appendingPathExtension("json")
    }
}
