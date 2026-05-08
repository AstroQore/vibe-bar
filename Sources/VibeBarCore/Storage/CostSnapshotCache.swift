import Foundation

/// Persists the most recent `CostSnapshot` per tool to disk so the popover
/// shows real numbers immediately on launch, before the next scan finishes.
///
/// Files: `~/.vibebar/cost_snapshots/{tool}.json` (mode 0600).
///
/// The full snapshot — heatmap, model breakdowns, daily history, totals —
/// fits in well under 1 MB even for heavy users, so we just write the whole
/// blob each time. CostHistoryStore still owns the canonical max-merged
/// per-day series; this cache is a snapshot of derived view data.
public actor CostSnapshotCache {
    public static let shared = CostSnapshotCache()

    private let directory: URL
    private struct StoredSnapshot: Codable {
        let retentionDays: Int
        let calculationVersion: Int?
        let snapshot: CostSnapshot
    }

    init(directory: URL = CostSnapshotCache.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        VibeBarLocalStore.costSnapshotDirectory
    }

    private func fileURL(for tool: ToolType) -> URL {
        directory.appendingPathComponent("\(tool.rawValue).json")
    }

    public func save(
        _ snapshot: CostSnapshot,
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        let url = fileURL(for: snapshot.tool)
        do {
            let stored = StoredSnapshot(
                retentionDays: CostDataSettings.normalizedRetentionDays(retentionDays),
                calculationVersion: CostUsagePricing.calculationVersion,
                snapshot: snapshot
            )
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            SafeLog.warn("Saving cost snapshot failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }

    public func load(
        tool: ToolType,
        retentionDays: Int = CostDataSettings.defaultRetentionDays,
        now: Date = Date()
    ) -> CostSnapshot? {
        let normalizedRetentionDays = CostDataSettings.normalizedRetentionDays(retentionDays)
        let url = fileURL(for: tool)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let stored = try? JSONDecoder().decode(StoredSnapshot.self, from: data) {
            guard stored.retentionDays == normalizedRetentionDays else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            guard stored.calculationVersion == CostUsagePricing.calculationVersion else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return stored.snapshot.rebasedForCurrentDay(now: now)
        }
        if (try? JSONDecoder().decode(CostSnapshot.self, from: data)) != nil {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    public func loadAll(
        retentionDays: Int = CostDataSettings.defaultRetentionDays,
        now: Date = Date()
    ) -> [ToolType: CostSnapshot] {
        var out: [ToolType: CostSnapshot] = [:]
        for tool in ToolType.allCases where tool.supportsTokenCost {
            if let snap = load(tool: tool, retentionDays: retentionDays, now: now) {
                out[tool] = snap
            }
        }
        return out
    }

    public func eraseAll() {
        for tool in ToolType.allCases {
            try? FileManager.default.removeItem(at: fileURL(for: tool))
        }
    }
}
