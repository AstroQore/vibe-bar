import Foundation

/// Persists per-bucket subscription fill history so the UI can render
/// a sparkline of "how full did I get in each of the last N reset
/// windows" alongside the live quota bar.
///
/// Scope is intentionally narrow:
///
/// - **Provider gate.** Only the four primary providers (`codex`,
///   `claude`, `gemini`, `grok`) are recorded. Misc providers are not
///   subscription plans in the same sense and are silently dropped.
/// - **Window gate.** Only buckets whose window is fixed-clock and
///   monotonic within the window — concretely
///   `rawWindowSeconds == nil || rawWindowSeconds >= 86_400` — are
///   recorded. The 5-hour on-demand rolling windows on Claude/Codex
///   are excluded because the clock doesn't tick when idle, so the
///   peak-per-window series is non-monotonic in a way that would
///   invert "used more" into "sparkline goes down".
///
/// File: `~/.vibebar/subscription_history.json` (mode 0600). Retention
/// is driven by callers passing `retentionDays`, matching how
/// `CostHistoryStore` consumes `CostDataSettings.retentionDays`.
public actor SubscriptionHistoryStore {
    public static let shared = SubscriptionHistoryStore()

    private struct Storage: Codable {
        var schemaVersion: Int
        var samples: [SubscriptionWindowSample]

        init(
            schemaVersion: Int = SubscriptionHistoryStore.storageSchemaVersion,
            samples: [SubscriptionWindowSample] = []
        ) {
            self.schemaVersion = schemaVersion
            self.samples = samples
        }
    }

    private let fileURL: URL
    private var cachedStorage: Storage?
    private var lastSavedAt: Date?
    private var pendingFlushTask: Task<Void, Never>?
    private var pendingStorage: Storage?

    private static let storageSchemaVersion = 1
    private static let saveThrottleInterval: TimeInterval = 30
    private static let maxFileBytes = 16 * 1024 * 1024

    private static let supportedTools: Set<ToolType> = [.codex, .claude, .gemini, .grok]
    /// Buckets with a `rawWindowSeconds` smaller than this threshold are
    /// dropped at observe time — they're on-demand rolling windows and
    /// don't have a monotonic peak-per-window series.
    private static let minimumTrackedWindowSeconds = 86_400

    public init(fileURL: URL = SubscriptionHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.subscriptionHistoryURL
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
            guard let windowEnd = bucket.resetAt else { continue }
            guard bucket.usedPercent.isFinite else { continue }
            if let secs = bucket.rawWindowSeconds, secs < Self.minimumTrackedWindowSeconds {
                continue
            }
            let windowStart = bucket.rawWindowSeconds.map {
                windowEnd.addingTimeInterval(-TimeInterval($0))
            }
            if let idx = storage.samples.firstIndex(where: {
                $0.accountId == quota.accountId
                    && $0.bucketId == bucket.id
                    && $0.windowEnd == windowEnd
            }) {
                var sample = storage.samples[idx]
                sample.peakUsedPercent = max(sample.peakUsedPercent, clamp(bucket.usedPercent))
                sample.lastUsedPercent = clamp(bucket.usedPercent)
                sample.observationCount += 1
                sample.lastSeenAt = max(sample.lastSeenAt, now)
                // windowStart and rawWindowSeconds might tighten across
                // refreshes (e.g. an adapter learning the window size
                // later); accept the latest non-nil value.
                if sample.windowStart == nil, windowStart != nil {
                    sample.windowStart = windowStart
                }
                if sample.rawWindowSeconds == nil, let s = bucket.rawWindowSeconds {
                    sample.rawWindowSeconds = s
                }
                storage.samples[idx] = sample
                dirty = true
            } else {
                let sample = SubscriptionWindowSample(
                    accountId: quota.accountId,
                    tool: quota.tool,
                    bucketId: bucket.id,
                    windowEnd: windowEnd,
                    windowStart: windowStart,
                    rawWindowSeconds: bucket.rawWindowSeconds,
                    peakUsedPercent: bucket.usedPercent,
                    lastUsedPercent: bucket.usedPercent,
                    observationCount: 1,
                    firstSeenAt: now,
                    lastSeenAt: now
                )
                storage.samples.append(sample)
                dirty = true
            }
        }
        guard dirty else { return }
        pruneInPlace(&storage, retentionDays: retentionDays, now: now)
        save(storage)
    }

    public func samples(
        accountId: String,
        bucketId: String,
        now: Date = Date(),
        includeCurrent: Bool = true,
        limit: Int? = nil
    ) -> [SubscriptionWindowSample] {
        let storage = load()
        var matching = storage.samples.filter {
            $0.accountId == accountId && $0.bucketId == bucketId
        }
        if !includeCurrent {
            matching.removeAll { $0.windowEnd > now }
        }
        matching.sort { $0.windowEnd > $1.windowEnd }
        if let limit, matching.count > limit {
            matching = Array(matching.prefix(limit))
        }
        return matching
    }

    public func allSamples() -> [SubscriptionWindowSample] {
        load().samples
    }

    public func prune(retentionDays: Int, now: Date = Date()) {
        var storage = load()
        pruneInPlace(&storage, retentionDays: retentionDays, now: now)
        save(storage)
    }

    public func eraseAll() {
        cachedStorage = Storage(samples: [])
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

    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
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
            // Future schema we don't understand — drop and start fresh
            // rather than risk corrupting the user's newer data.
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
        if CostDataSettings.isUnlimitedRetention(retentionDays) { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        storage.samples.removeAll { $0.windowEnd < cutoff }
    }
}
