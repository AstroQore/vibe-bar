import Foundation

/// Persists daily cost samples with **max-merge** semantics so old data isn't
/// lost when Codex/Claude rotate their JSONL session logs.
///
/// Rule: for each (tool, day), the stored value is `max(saved, freshly-scanned)`
/// — both for cost USD and total tokens. This means:
///   - If Codex log rotation drops a session that occurred 28 days ago, the
///     saved value stays.
///   - If a fresh scan finds a higher cost (because the user added new sessions
///     that day), we replace with the higher number.
///   - If a scan returns a lower number (rotation removed entries), we keep
///     the saved one.
///
/// File: `~/.vibebar/cost_history.json` (mode 0600). Retains ~3 years.
public actor CostHistoryStore {
    public static let shared = CostHistoryStore()

    private struct Entry: Codable {
        let tool: String
        let date: String      // YYYY-MM-DD
        var costUSD: Double
        var totalTokens: Int
    }
    private struct Storage: Codable {
        var entries: [Entry]
    }

    private let fileURL: URL
    private let dateFormatter: DateFormatter

    /// 3 years — covers any "All time" lookback. Storage at one entry per
    /// (tool, day) stays small (<200 KB).
    private static let retentionDays = 365 * 3

    init(fileURL: URL = CostHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = f
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.costHistoryURL
    }

    /// Bulk merge a series of daily samples for one tool. Each sample is
    /// max-merged with what's saved for the same (tool, date) key.
    public func mergeSeries(_ series: [DailyCostPoint], tool: ToolType) {
        var storage = load()
        let toolKey = tool.rawValue
        for point in series {
            let key = dateFormatter.string(from: point.date)
            if let idx = storage.entries.firstIndex(where: { $0.tool == toolKey && $0.date == key }) {
                storage.entries[idx].costUSD = max(storage.entries[idx].costUSD, point.costUSD)
                storage.entries[idx].totalTokens = max(storage.entries[idx].totalTokens, point.totalTokens)
            } else if point.costUSD > 0 || point.totalTokens > 0 {
                storage.entries.append(Entry(tool: toolKey, date: key, costUSD: point.costUSD, totalTokens: point.totalTokens))
            }
        }
        prune(&storage)
        save(storage)
    }

    /// Merge a CostSnapshot's daily history with stored data and return a fresh
    /// snapshot whose totals reflect the max-merged daily series.
    public func mergeAndAugment(_ snapshot: CostSnapshot) -> CostSnapshot {
        mergeSeries(snapshot.dailyHistory, tool: snapshot.tool)
        let storage = load()
        let toolKey = snapshot.tool.rawValue
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: snapshot.updatedAt)
        let weekCutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthCutoff = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        var todayCost = 0.0, todayTokens = 0
        var weekCost = 0.0, weekTokens = 0
        var monthCost = 0.0, monthTokens = 0
        var allCost = 0.0, allTokens = 0
        var dailyPoints: [DailyCostPoint] = []
        for entry in storage.entries where entry.tool == toolKey {
            guard let day = dateFormatter.date(from: entry.date) else { continue }
            let normalizedDay = calendar.startOfDay(for: day)
            dailyPoints.append(DailyCostPoint(date: normalizedDay, costUSD: entry.costUSD, totalTokens: entry.totalTokens))
            allCost += entry.costUSD
            allTokens += entry.totalTokens
            if normalizedDay >= today {
                todayCost += entry.costUSD
                todayTokens += entry.totalTokens
            }
            if normalizedDay >= weekCutoff {
                weekCost += entry.costUSD
                weekTokens += entry.totalTokens
            }
            if normalizedDay >= monthCutoff {
                monthCost += entry.costUSD
                monthTokens += entry.totalTokens
            }
        }
        dailyPoints.sort { $0.date < $1.date }

        // Use the max of (stored series total, fresh-scan total). Fresh scan
        // already saw all data on disk; stored series may include older days
        // that disk lost.
        let mergedToday   = max(todayCost,   snapshot.todayCostUSD)
        let mergedWeek    = max(weekCost,    snapshot.last7DaysCostUSD)
        let mergedMonth   = max(monthCost,   snapshot.last30DaysCostUSD)
        let mergedAll     = max(allCost,     snapshot.allTimeCostUSD)
        let mergedTodayTk = max(todayTokens, snapshot.todayTokens)
        let mergedWeekTk  = max(weekTokens,  snapshot.last7DaysTokens)
        let mergedMonthTk = max(monthTokens, snapshot.last30DaysTokens)
        let mergedAllTk   = max(allTokens,   snapshot.allTimeTokens)

        return CostSnapshot(
            tool: snapshot.tool,
            todayCostUSD: mergedToday,
            last7DaysCostUSD: mergedWeek,
            last30DaysCostUSD: mergedMonth,
            allTimeCostUSD: mergedAll,
            todayTokens: mergedTodayTk,
            last7DaysTokens: mergedWeekTk,
            last30DaysTokens: mergedMonthTk,
            allTimeTokens: mergedAllTk,
            dailyHistory: dailyPoints,
            heatmap: snapshot.heatmap,
            modelBreakdowns: snapshot.modelBreakdowns,
            last7DaysModelBreakdowns: snapshot.last7DaysModelBreakdowns,
            // Per-day model breakdown is in-memory only; preserve whatever
            // the live scan produced. Persisted historical days won't have it.
            dailyModelBreakdown: snapshot.dailyModelBreakdown,
            jsonlFilesFound: snapshot.jsonlFilesFound,
            updatedAt: snapshot.updatedAt
        )
    }

    public func history(for tool: ToolType, days dayCount: Int? = nil, now: Date = Date()) -> CostHistory {
        let storage = load()
        let toolKey = tool.rawValue
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var byDate: [String: Entry] = [:]
        for entry in storage.entries where entry.tool == toolKey {
            byDate[entry.date] = entry
        }

        let count = dayCount ?? Self.retentionDays
        var points: [DailyCostPoint] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = dateFormatter.string(from: day)
            if let entry = byDate[key] {
                points.append(DailyCostPoint(date: day, costUSD: entry.costUSD, totalTokens: entry.totalTokens))
            } else if dayCount != nil {
                points.append(DailyCostPoint(date: day, costUSD: 0, totalTokens: 0))
            }
        }
        return CostHistory(tool: tool, days: points, updatedAt: now)
    }

    public func eraseAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() -> Storage {
        guard let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage(entries: [])
        }
        return storage
    }

    private func save(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func prune(_ storage: inout Storage) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) else { return }
        let cutoffKey = dateFormatter.string(from: cutoff)
        storage.entries.removeAll { $0.date < cutoffKey }
    }
}
