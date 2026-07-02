import Foundation

/// Persists short-horizon fill samples (`FillTimelinePoint`) so the popover
/// can render a CodexBar-style timeline — thin per-hour bars over the last
/// week — for each headline quota bucket.
///
/// Scope mirrors `SubscriptionHistoryStore` where it makes sense:
///
/// - **Provider gate.** Only the four primary providers (`codex`, `claude`,
///   `gemini`, `grok`).
/// - **Bucket gate.** Headline buckets only (`groupTitle == nil`) — the
///   five_hour / weekly / monthly rows the utilization panel shows. Unlike
///   the window-peak store, 5-hour rolling buckets ARE recorded: a
///   point-in-time series has no monotonicity requirement.
/// - **Horizon.** Hour-slot samples, pruned past `maxHorizonDays` (8) — the
///   chart shows 7 days; retention settings below that are respected.
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

    private static let storageSchemaVersion = 1
    private static let saveThrottleInterval: TimeInterval = 30
    private static let maxFileBytes = 4 * 1024 * 1024
    private static let maxHorizonDays = 8
    private static let supportedTools: Set<ToolType> = [.codex, .claude, .gemini, .grok]

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
        let slotStart = Self.hourSlotStart(for: now)
        for bucket in quota.buckets {
            guard bucket.groupTitle == nil else { continue }
            guard bucket.usedPercent.isFinite else { continue }
            let percent = min(100, max(0, bucket.usedPercent))
            if let idx = storage.points.firstIndex(where: {
                $0.accountId == quota.accountId
                    && $0.bucketId == bucket.id
                    && $0.slotStart == slotStart
            }) {
                storage.points[idx].usedPercent = percent
                storage.points[idx].sampledAt = now
            } else {
                storage.points.append(FillTimelinePoint(
                    accountId: quota.accountId,
                    tool: quota.tool,
                    bucketId: bucket.id,
                    slotStart: slotStart,
                    usedPercent: percent,
                    sampledAt: now
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
        cachedStorage = storage
        return storage
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
        let horizon: Int
        if CostDataSettings.isUnlimitedRetention(retentionDays) {
            horizon = Self.maxHorizonDays
        } else {
            horizon = max(0, min(Self.maxHorizonDays, retentionDays))
        }
        let cutoff = now.addingTimeInterval(-TimeInterval(horizon) * 86_400)
        storage.points.removeAll { $0.slotStart < cutoff }
    }
}
