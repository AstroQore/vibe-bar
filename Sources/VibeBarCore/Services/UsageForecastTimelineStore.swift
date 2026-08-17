import Foundation

/// Persists the pace forecast that was actually shown for each quota bucket.
///
/// Scope mirrors `UsageFillTimelineStore`:
///
/// - Same five core providers, same adaptive slot policy, last sample in a slot
///   wins, same window-aware retention horizon.
/// - Written only when a quota refresh succeeds. Nothing here runs at render
///   time — the live forecast the UI draws is still computed on demand.
///
/// The chart pairs these points with the fill timeline: the fill line is what
/// happened, this is what was predicted at the time. Recomputing an old
/// forecast from today's history would quietly launder hindsight into the
/// projection line, which is exactly what the feature is meant to expose.
///
/// File: `~/.vibebar/forecast_timeline.json` (mode 0600).
public actor UsageForecastTimelineStore {
    public static let shared = UsageForecastTimelineStore()

    private struct Storage: Codable {
        var schemaVersion: Int
        var points: [ForecastTimelinePoint]

        init(
            schemaVersion: Int = UsageForecastTimelineStore.storageSchemaVersion,
            points: [ForecastTimelinePoint] = []
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
    /// Defensive cap only. Slot cardinality matches the fill timeline and each
    /// point is roughly twice the payload, so the real file stays far under a
    /// megabyte; a file past this size is corrupt, not legitimate history.
    private static let maxFileBytes = 24 * 1024 * 1024
    private static let supportedTools: Set<ToolType> = [.codex, .claude, .gemini, .antigravity, .grok, .cursor]

    public init(fileURL: URL = UsageForecastTimelineStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.forecastTimelineURL
    }

    // MARK: - Public API

    /// Record one refresh worth of forecasts. Buckets without a forecast are
    /// simply omitted by the caller — a missing projection is not stored as a
    /// zero.
    public func observe(
        _ forecasts: [BucketForecastObservation],
        accountId: String,
        tool: ToolType,
        now: Date = Date(),
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        guard Self.supportedTools.contains(tool), !forecasts.isEmpty else { return }

        var storage = load()
        var dirty = false
        for forecast in forecasts {
            guard forecast.projectedUsedPercent.isFinite,
                  forecast.projectedUsedLowerPercent.isFinite,
                  forecast.projectedUsedUpperPercent.isFinite
            else { continue }
            let slotStart = UsageTimelineSlotPolicy.slotStart(
                for: now,
                windowSeconds: forecast.rawWindowSeconds
            )
            if let idx = storage.points.firstIndex(where: {
                $0.accountId == accountId
                    && $0.bucketId == forecast.bucketId
                    && $0.slotStart == slotStart
            }) {
                storage.points[idx].sampledAt = now
                storage.points[idx].projectedUsedPercent = forecast.projectedUsedPercent
                storage.points[idx].projectedUsedLowerPercent = forecast.projectedUsedLowerPercent
                storage.points[idx].projectedUsedUpperPercent = forecast.projectedUsedUpperPercent
                storage.points[idx].resetAt = forecast.resetAt
                storage.points[idx].rawWindowSeconds = forecast.rawWindowSeconds
            } else {
                storage.points.append(ForecastTimelinePoint(
                    accountId: accountId,
                    tool: tool,
                    bucketId: forecast.bucketId,
                    slotStart: slotStart,
                    sampledAt: now,
                    projectedUsedPercent: forecast.projectedUsedPercent,
                    projectedUsedLowerPercent: forecast.projectedUsedLowerPercent,
                    projectedUsedUpperPercent: forecast.projectedUsedUpperPercent,
                    resetAt: forecast.resetAt,
                    rawWindowSeconds: forecast.rawWindowSeconds
                ))
            }
            dirty = true
        }
        guard dirty else { return }
        pruneInPlace(&storage, retentionDays: retentionDays, now: now)
        save(storage)
    }

    /// Points for one account+bucket, oldest first.
    public func points(accountId: String, bucketId: String) -> [ForecastTimelinePoint] {
        load().points
            .filter { $0.accountId == accountId && $0.bucketId == bucketId }
            .sorted { $0.slotStart < $1.slotStart }
    }

    public func allPoints() -> [ForecastTimelinePoint] {
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
