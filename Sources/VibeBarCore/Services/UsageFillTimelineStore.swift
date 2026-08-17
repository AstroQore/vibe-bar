import Foundation

/// Persists quota observations used by reset history and pace forecasting.
///
/// Scope mirrors `SubscriptionHistoryStore` where it makes sense:
///
/// - Every quota for the five core providers is recorded, including Codex
///   Spark, Claude Fable, and every Gemini Web / AntiGravity lane.
/// - Slot size and retention follow the quota window so short rolling limits
///   stay detailed without making weekly/monthly history unnecessarily large.
///
/// File: `~/.vibebar/fill_timeline.json` (mode 0600).
public actor UsageFillTimelineStore {
    public static let shared = UsageFillTimelineStore()

    private struct Storage: Codable {
        var schemaVersion: Int
        var points: [FillTimelinePoint]

        init(
            schemaVersion: Int = UsageFillTimelineStore.storageSchemaVersion,
            points: [FillTimelinePoint] = []
        ) {
            self.schemaVersion = schemaVersion
            self.points = points
        }
    }

    private let fileURL: URL
    private var cachedStorage: Storage?
    private var lastSavedAt: Date?
    private var pendingFlushTask: Task<Void, Never>?
    private var pendingStorage: Storage?

    private static let storageSchemaVersion = 2
    private static let saveThrottleInterval: TimeInterval = 30
    private static let maxFileBytes = 24 * 1024 * 1024
    private static let supportedTools: Set<ToolType> = [.codex, .claude, .gemini, .antigravity, .grok, .cursor]

    public init(fileURL: URL = UsageFillTimelineStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.fillTimelineURL
    }

    // MARK: - Public API

    public func observe(
        _ quota: AccountQuota,
        now: Date = Date(),
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        guard Self.supportedTools.contains(quota.tool) else { return }

        var storage = load()
        var dirty = false
        for bucket in quota.buckets {
            guard bucket.usedPercent.isFinite else { continue }
            let percent = min(100, max(0, bucket.usedPercent))
            let slotStart = Self.slotStart(for: now, windowSeconds: bucket.rawWindowSeconds)
            if let idx = storage.points.firstIndex(where: {
                $0.accountId == quota.accountId
                    && $0.bucketId == bucket.id
                    && $0.slotStart == slotStart
            }) {
                storage.points[idx].usedPercent = percent
                storage.points[idx].sampledAt = now
                storage.points[idx].resetAt = bucket.resetAt
                storage.points[idx].rawWindowSeconds = bucket.rawWindowSeconds
            } else {
                storage.points.append(FillTimelinePoint(
                    accountId: quota.accountId,
                    tool: quota.tool,
                    bucketId: bucket.id,
                    slotStart: slotStart,
                    usedPercent: percent,
                    sampledAt: now,
                    resetAt: bucket.resetAt,
                    rawWindowSeconds: bucket.rawWindowSeconds
                ))
            }
            dirty = true
        }
        guard dirty else { return }
        pruneInPlace(&storage, retentionDays: retentionDays, now: now)
        save(storage)
    }

    /// Points for one account+bucket, oldest first.
    public func points(accountId: String, bucketId: String) -> [FillTimelinePoint] {
        load().points
            .filter { $0.accountId == accountId && $0.bucketId == bucketId }
            .sorted { $0.slotStart < $1.slotStart }
    }

    /// Points for several buckets of one account, oldest first per bucket.
    ///
    /// One actor hop for the whole account instead of one per bucket: the
    /// caller republishes the result into `@Published` state, and an `await`
    /// between buckets meant every bucket landed in its own main-actor tick —
    /// which is a full popover re-render each, thirty-odd of them per refresh.
    /// Buckets with no recorded points are absent from the result.
    public func points(accountId: String, bucketIds: [String]) -> [String: [FillTimelinePoint]] {
        let wanted = Set(bucketIds)
        guard !wanted.isEmpty else { return [:] }
        var grouped: [String: [FillTimelinePoint]] = [:]
        for point in load().points
        where point.accountId == accountId && wanted.contains(point.bucketId) {
            grouped[point.bucketId, default: []].append(point)
        }
        return grouped.mapValues { $0.sorted { $0.slotStart < $1.slotStart } }
    }

    public func allPoints() -> [FillTimelinePoint] {
        load().points
    }

    public func eraseAll() {
        cachedStorage = Storage(points: [])
        pendingStorage = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        lastSavedAt = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func flushPendingWrites() async {
        if let storage = pendingStorage {
            persist(storage)
            pendingStorage = nil
            lastSavedAt = Date()
        }
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
    }

    // MARK: - Private

    static func hourSlotStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3_600) * 3_600)
    }

    static func slotStart(for date: Date, windowSeconds: Int?) -> Date {
        UsageTimelineSlotPolicy.slotStart(for: date, windowSeconds: windowSeconds)
    }

    private func load() -> Storage {
        if let cached = cachedStorage { return cached }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = (attrs[.size] as? NSNumber)?.intValue,
           size > Self.maxFileBytes {
            let empty = Storage()
            cachedStorage = empty
            return empty
        }
        guard let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            let empty = Storage()
            cachedStorage = empty
            return empty
        }
        if storage.schemaVersion > Self.storageSchemaVersion {
            let empty = Storage()
            persist(empty)
            cachedStorage = empty
            return empty
        }
        var migrated = storage
        if migrated.schemaVersion < Self.storageSchemaVersion {
            migrated.schemaVersion = Self.storageSchemaVersion
            persist(migrated)
        }
        cachedStorage = migrated
        return migrated
    }

    private func save(_ storage: Storage) {
        cachedStorage = storage
        let now = Date()
        if let last = lastSavedAt, now.timeIntervalSince(last) < Self.saveThrottleInterval {
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

    private func pruneInPlace(_ storage: inout Storage, retentionDays: Int, now: Date) {
        storage.points.removeAll { point in
            let horizon = UsageTimelineSlotPolicy.retentionHorizonDays(
                windowSeconds: point.rawWindowSeconds,
                retentionDays: retentionDays
            )
            return point.slotStart < now.addingTimeInterval(-TimeInterval(horizon) * 86_400)
        }
    }
}
