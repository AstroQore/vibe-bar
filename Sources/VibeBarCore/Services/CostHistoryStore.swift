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
/// File: `~/.vibebar/cost_history.json` (mode 0600). Retention is controlled
/// by `AppSettings.costData.retentionDays`.
public actor CostHistoryStore {
    public static let shared = CostHistoryStore()

    private struct Entry: Codable {
        let tool: String
        let date: String      // YYYY-MM-DD
        var costUSD: Double
        var totalTokens: Int
    }
    private struct Storage: Codable {
        var schemaVersion: Int
        var entries: [Entry]

        init(schemaVersion: Int = CostHistoryStore.storageSchemaVersion, entries: [Entry]) {
            self.schemaVersion = schemaVersion
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, entries
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            self.entries = try c.decode([Entry].self, forKey: .entries)
        }
    }

    private let fileURL: URL
    private let dateFormatter: DateFormatter
    private let legacyUTCDateFormatter: DateFormatter
    private let calendar: Calendar

    /// In-memory copy of the last loaded/saved storage. Refresh paths can
    /// merge against this without re-reading the file every time.
    private var cachedStorage: Storage?
    /// When we last persisted to disk. Used to throttle write-back so a
    /// burst of `mergeSeries` calls (one per tool, one per refresh) doesn't
    /// re-encode and rewrite ~200 KB of JSON for every call.
    private var lastSavedAt: Date?
    /// Coalesce throttled writes — pending edits are flushed via this task.
    private var pendingFlushTask: Task<Void, Never>?
    /// Pending edits to flush. Set whenever `save(_:)` is called inside the
    /// throttle window.
    private var pendingStorage: Storage?

    /// Flush the cache to disk at most once per this interval. Refresh runs
    /// fire roughly every 10 minutes (default `refreshIntervalSeconds`); 30
    /// seconds is fast enough to recover unsaved data after a crash but slow
    /// enough that a typical refresh round writes the file at most once.
    private static let saveThrottleInterval: TimeInterval = 30
    private static let storageSchemaVersion = 2

    init(fileURL: URL = CostHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone.current
        self.calendar = cal
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = f
        let legacy = DateFormatter()
        legacy.dateFormat = "yyyy-MM-dd"
        legacy.calendar = Calendar(identifier: .gregorian)
        legacy.timeZone = TimeZone(identifier: "UTC")
        legacy.locale = Locale(identifier: "en_US_POSIX")
        self.legacyUTCDateFormatter = legacy
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.costHistoryURL
    }

    /// Bulk merge a series of daily samples for one tool. Each sample is
    /// max-merged with what's saved for the same (tool, date) key.
    public func mergeSeries(
        _ series: [DailyCostPoint],
        tool: ToolType,
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        var storage = load()
        let toolKey = tool.rawValue
        let cutoffKey = retentionCutoffKey(retentionDays: retentionDays)
        for point in series {
            let key = dateFormatter.string(from: point.date)
            if let cutoffKey, key < cutoffKey { continue }
            if let idx = storage.entries.firstIndex(where: { $0.tool == toolKey && $0.date == key }) {
                storage.entries[idx].costUSD = max(storage.entries[idx].costUSD, point.costUSD)
                storage.entries[idx].totalTokens = max(storage.entries[idx].totalTokens, point.totalTokens)
            } else if point.costUSD > 0 || point.totalTokens > 0 {
                storage.entries.append(Entry(tool: toolKey, date: key, costUSD: point.costUSD, totalTokens: point.totalTokens))
            }
        }
        prune(&storage, retentionDays: retentionDays)
        save(storage)
    }

    /// Merge a CostSnapshot's daily history with stored data and return a fresh
    /// snapshot whose totals reflect the max-merged daily series.
    public func mergeAndAugment(
        _ snapshot: CostSnapshot,
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) -> CostSnapshot {
        mergeSeries(snapshot.dailyHistory, tool: snapshot.tool, retentionDays: retentionDays)
        let storage = load()
        let toolKey = snapshot.tool.rawValue
        let today = calendar.startOfDay(for: snapshot.updatedAt)
        let weekCutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthCutoff = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        var todayCost = 0.0, todayTokens = 0
        var weekCost = 0.0, weekTokens = 0
        var monthCost = 0.0, monthTokens = 0
        var allCost = 0.0, allTokens = 0
        var dailyPoints: [DailyCostPoint] = []
        let cutoffKey = retentionCutoffKey(now: snapshot.updatedAt, retentionDays: retentionDays)
        for entry in storage.entries where entry.tool == toolKey {
            if let cutoffKey, entry.date < cutoffKey { continue }
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

        return CostSnapshot(
            tool: snapshot.tool,
            todayCostUSD: todayCost,
            last7DaysCostUSD: weekCost,
            last30DaysCostUSD: monthCost,
            allTimeCostUSD: allCost,
            todayTokens: todayTokens,
            last7DaysTokens: weekTokens,
            last30DaysTokens: monthTokens,
            allTimeTokens: allTokens,
            dailyHistory: dailyPoints,
            todayHourlyHistory: snapshot.todayHourlyHistory,
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

    public func history(
        for tool: ToolType,
        days dayCount: Int? = nil,
        now: Date = Date(),
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) -> CostHistory {
        let storage = load()
        let toolKey = tool.rawValue
        let today = calendar.startOfDay(for: now)
        var byDate: [String: Entry] = [:]
        for entry in storage.entries where entry.tool == toolKey {
            byDate[entry.date] = entry
        }

        if dayCount == nil, CostDataSettings.isUnlimitedRetention(retentionDays) {
            let points = storage.entries
                .filter { $0.tool == toolKey }
                .compactMap { entry -> DailyCostPoint? in
                    guard let day = dateFormatter.date(from: entry.date) else { return nil }
                    return DailyCostPoint(
                        date: calendar.startOfDay(for: day),
                        costUSD: entry.costUSD,
                        totalTokens: entry.totalTokens
                    )
                }
                .sorted { $0.date < $1.date }
            return CostHistory(tool: tool, days: points, updatedAt: now)
        }

        let count = dayCount ?? CostDataSettings.normalizedRetentionDays(retentionDays)
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

    public func prune(retentionDays: Int) {
        var storage = load()
        prune(&storage, retentionDays: retentionDays)
        save(storage)
    }

    public func eraseAll() {
        cachedStorage = Storage(entries: [])
        pendingStorage = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        lastSavedAt = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Block until any pending throttled writes have flushed. Useful from
    /// shutdown paths or tests.
    public func flushPendingWrites() async {
        if let storage = pendingStorage {
            persist(storage)
            pendingStorage = nil
            lastSavedAt = Date()
        }
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
    }

    private static let maxFileBytes = 16 * 1024 * 1024  // 16 MB safety cap; real file is < 200 KB

    private func load() -> Storage {
        if let cached = cachedStorage { return cached }
        // Defensive size check: an empty or pathological file should not OOM
        // the JSONDecoder. The legitimate file is well under 1 MB even at
        // 3-year retention.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = (attrs[.size] as? NSNumber)?.intValue,
           size > Self.maxFileBytes {
            let empty = Storage(entries: [])
            cachedStorage = empty
            return empty
        }
        guard let data = try? Data(contentsOf: fileURL),
              var storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            let empty = Storage(entries: [])
            cachedStorage = empty
            return empty
        }
        if migrateLegacyStorageIfNeeded(&storage) {
            persist(storage)
        }
        cachedStorage = storage
        return storage
    }

    private func save(_ storage: Storage) {
        cachedStorage = storage
        let now = Date()
        if let last = lastSavedAt, now.timeIntervalSince(last) < Self.saveThrottleInterval {
            // Inside the throttle window: defer the write. The pending flush
            // task wakes after the remaining delay and persists the latest
            // value, coalescing any further writes that arrive in between.
            pendingStorage = storage
            scheduleFlush(after: Self.saveThrottleInterval - now.timeIntervalSince(last))
            return
        }
        persist(storage)
        pendingStorage = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        lastSavedAt = now
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func scheduleFlush(after delay: TimeInterval) {
        if pendingFlushTask != nil { return }
        let nanoseconds = UInt64(max(0.05, delay) * 1_000_000_000)
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.flushPendingWrites()
        }
    }

    private func prune(_ storage: inout Storage, retentionDays: Int) {
        guard let cutoffKey = retentionCutoffKey(retentionDays: retentionDays) else { return }
        storage.entries.removeAll { $0.date < cutoffKey }
    }

    private func retentionCutoffKey(now: Date = Date(), retentionDays: Int) -> String? {
        let normalized = CostDataSettings.normalizedRetentionDays(retentionDays)
        guard normalized > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(normalized - 1), to: today) else { return nil }
        let cutoffKey = dateFormatter.string(from: cutoff)
        return cutoffKey
    }

    private func migrateLegacyStorageIfNeeded(_ storage: inout Storage) -> Bool {
        guard storage.schemaVersion < Self.storageSchemaVersion else { return false }
        var byKey: [String: Entry] = [:]
        for entry in storage.entries {
            let migratedDate = legacyLocalStartOfDay(for: entry.date)
            let migratedKey = migratedDate.map { dateFormatter.string(from: $0) } ?? entry.date
            let compoundKey = "\(entry.tool)\u{0}\(migratedKey)"
            if var existing = byKey[compoundKey] {
                existing.costUSD = max(existing.costUSD, entry.costUSD)
                existing.totalTokens = max(existing.totalTokens, entry.totalTokens)
                byKey[compoundKey] = existing
            } else {
                byKey[compoundKey] = Entry(
                    tool: entry.tool,
                    date: migratedKey,
                    costUSD: entry.costUSD,
                    totalTokens: entry.totalTokens
                )
            }
        }
        storage.entries = Array(byKey.values)
        storage.schemaVersion = Self.storageSchemaVersion
        return true
    }

    private func legacyLocalStartOfDay(for legacyKey: String) -> Date? {
        guard let legacyDate = legacyUTCDateFormatter.date(from: legacyKey) else { return nil }
        let base = calendar.startOfDay(for: legacyDate)
        for offset in -1...1 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: base) else { continue }
            if legacyUTCDateFormatter.string(from: candidate) == legacyKey {
                return candidate
            }
        }
        return base
    }
}
