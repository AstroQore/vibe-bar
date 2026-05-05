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

    public static func save(_ snapshots: [ToolType: ServiceStatusSnapshot]) throws {
        try VibeBarLocalStore.writeJSON(snapshots, to: cacheURL)
    }
}
