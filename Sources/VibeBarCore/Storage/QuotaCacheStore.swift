import Foundation

public enum QuotaCacheStore {
    public static func loadAll() -> [String: AccountQuota] {
        let fm = FileManager.default
        let dir = VibeBarLocalStore.quotaDirectory
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var out: [String: AccountQuota] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let quota = try? VibeBarLocalStore.readJSON(AccountQuota.self, from: url) else {
                continue
            }
            out[quota.accountId] = quota
        }
        return out
    }

    public static func save(_ quota: AccountQuota) throws {
        try VibeBarLocalStore.writeJSON(quota, to: url(for: quota.accountId))
    }

    public static func delete(accountId: String) throws {
        try VibeBarLocalStore.deleteFile(at: url(for: accountId))
    }

    private static func url(for accountId: String) -> URL {
        VibeBarLocalStore.quotaDirectory
            .appendingPathComponent(VibeBarLocalStore.safeFileComponent(accountId))
            .appendingPathExtension("json")
    }
}
