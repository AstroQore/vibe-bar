import Foundation

public enum ServiceStatusCacheStore {
    private static var cacheURL: URL {
        VibeBarLocalStore.baseDirectory.appendingPathComponent("service_status.json")
    }

    public static func loadAll() -> [ToolType: ServiceStatusSnapshot] {
        guard let snapshots = try? VibeBarLocalStore.readJSON([ToolType: ServiceStatusSnapshot].self, from: cacheURL) else {
            return [:]
        }
        return snapshots
    }

    /// Compact, not pretty-printed: this is a Vibe Bar-owned cache that
    /// nobody reads by hand, and the pretty form was ~330 KB of indentation
    /// re-encoded and rewritten on every five-minute status refresh.
    public static func save(_ snapshots: [ToolType: ServiceStatusSnapshot]) throws {
        try VibeBarLocalStore.writeCompactJSON(snapshots, to: cacheURL)
    }
}
