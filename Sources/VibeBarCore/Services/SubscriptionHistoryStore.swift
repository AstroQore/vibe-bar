import Foundation

/// Persists inferred subscription cycles, not point-in-time samples.
///
/// A changing `resetAt` is only a forecast and is never used as cycle
/// identity. The active cycle is finalized when usage materially drops (the
/// provider refilled the quota), with crossing the previous reset boundary as
/// a secondary signal. This avoids the old failure mode where a few seconds of
/// reset-time drift created thousands of fake weekly cycles.
public actor SubscriptionHistoryStore {
    public static let shared = SubscriptionHistoryStore()

    private struct Storage: Codable {
        var schemaVersion: Int
        var legacyTimelineImported: Bool
        var samples: [SubscriptionWindowSample]

        init(
            schemaVersion: Int = SubscriptionHistoryStore.storageSchemaVersion,
            legacyTimelineImported: Bool = false,
            samples: [SubscriptionWindowSample] = []
        ) {
            self.schemaVersion = schemaVersion
            self.legacyTimelineImported = legacyTimelineImported
            self.samples = samples
        }
    }

    private struct VersionHeader: Decodable { let schemaVersion: Int }

    private let fileURL: URL
    private var cachedStorage: Storage?
    private var lastSavedAt: Date?
    private var pendingFlushTask: Task<Void, Never>?
    private var pendingStorage: Storage?

    private static let storageSchemaVersion = 2
    private static let saveThrottleInterval: TimeInterval = 30
    private static let maxFileBytes = 16 * 1024 * 1024
    private static let supportedTools: Set<ToolType> = [
        .codex, .claude, .gemini, .antigravity, .grok
    ]

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
            guard let resetAt = bucket.resetAt, bucket.usedPercent.isFinite else { continue }
            let used = clamp(bucket.usedPercent)
            let currentIndex = storage.samples.indices
                .filter {
                    storage.samples[$0].accountId == quota.accountId
                        && storage.samples[$0].bucketId == bucket.id
                        && !storage.samples[$0].isCompleted
                }
                .max { storage.samples[$0].lastSeenAt < storage.samples[$1].lastSeenAt }

            guard let currentIndex else {
                storage.samples.append(makeCurrentSample(
                    quota: quota,
                    bucket: bucket,
                    used: used,
                    resetAt: resetAt,
                    now: now
                ))
                dirty = true
                continue
            }

            var current = storage.samples[currentIndex]
            if let reason = completionReason(
                for: current,
                newUsedPercent: used,
                newResetAt: resetAt,
                now: now
            ) {
                current.completedAt = now
                current.completionReason = reason
                // The observed refill time is more useful than a stale reset
                // forecast when providers reset early or late.
                current.windowEnd = now
                storage.samples[currentIndex] = current
                storage.samples.append(makeCurrentSample(
                    quota: quota,
                    bucket: bucket,
                    used: used,
                    resetAt: resetAt,
                    now: now
                ))
            } else {
                current.windowEnd = resetAt
                current.windowStart = bucket.rawWindowSeconds.map {
                    resetAt.addingTimeInterval(-TimeInterval($0))
                } ?? current.windowStart
                current.rawWindowSeconds = bucket.rawWindowSeconds ?? current.rawWindowSeconds
                current.peakUsedPercent = max(current.peakUsedPercent, used)
                current.lastUsedPercent = used
                current.observationCount += 1
                current.lastSeenAt = max(current.lastSeenAt, now)
                storage.samples[currentIndex] = current
            }
            dirty = true
        }

        guard dirty else { return }
        pruneInPlace(&storage, retentionDays: retentionDays, now: now)
        save(storage)
    }

    /// One-time best-effort migration from the old hourly fill timeline. Only
    /// material downward jumps become completed cycles; ordinary samples are
    /// intentionally discarded so the new chart starts truthful.
    public func importLegacyTimeline(
        _ points: [FillTimelinePoint],
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        var storage = load()
        guard !storage.legacyTimelineImported else { return }
        storage.legacyTimelineImported = true

        let grouped = Dictionary(grouping: points) {
            SubscriptionHistoryKey(accountId: $0.accountId, bucketId: $0.bucketId)
        }
        for (_, rawPoints) in grouped {
            let sorted = rawPoints.sorted { $0.sampledAt < $1.sampledAt }
            guard let first = sorted.first, Self.supportedTools.contains(first.tool) else { continue }
            var peak = clamp(first.usedPercent)
            var previous = first
            var segmentStart = first.sampledAt
            for point in sorted.dropFirst() {
                let currentUsed = clamp(point.usedPercent)
                if Self.isMaterialRefill(previous: previous.usedPercent, peak: peak, current: currentUsed) {
                    storage.samples.append(SubscriptionWindowSample(
                        accountId: first.accountId,
                        tool: first.tool,
                        bucketId: first.bucketId,
                        windowEnd: point.sampledAt,
                        windowStart: segmentStart,
                        rawWindowSeconds: nil,
                        peakUsedPercent: peak,
                        lastUsedPercent: clamp(previous.usedPercent),
                        observationCount: 1,
                        firstSeenAt: segmentStart,
                        lastSeenAt: previous.sampledAt,
                        completedAt: point.sampledAt,
                        completionReason: .legacyTimelineMigration
                    ))
                    segmentStart = point.sampledAt
                    peak = currentUsed
                } else {
                    peak = max(peak, currentUsed)
                }
                previous = point
            }
        }
        pruneInPlace(&storage, retentionDays: retentionDays, now: Date())
        save(storage)
    }

    public func samples(
        accountId: String,
        bucketId: String,
        now: Date = Date(),
        includeCurrent: Bool = true,
        limit: Int? = nil
    ) -> [SubscriptionWindowSample] {
        var matching = load().samples.filter {
            $0.accountId == accountId
                && $0.bucketId == bucketId
                && (includeCurrent || $0.isCompleted)
        }
        matching.sort { sampleSortDate($0) > sampleSortDate($1) }
        if let limit, matching.count > limit {
            matching = Array(matching.prefix(limit))
        }
        return matching
    }

    public func allSamples() -> [SubscriptionWindowSample] { load().samples }

    public func prune(retentionDays: Int, now: Date = Date()) {
        var storage = load()
        pruneInPlace(&storage, retentionDays: retentionDays, now: now)
        save(storage)
    }

    public func eraseAll() {
        cachedStorage = Storage()
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

    // MARK: - Reset inference

    private func completionReason(
        for current: SubscriptionWindowSample,
        newUsedPercent: Double,
        newResetAt: Date,
        now: Date
    ) -> SubscriptionWindowSample.CompletionReason? {
        if Self.isMaterialRefill(
            previous: current.lastUsedPercent,
            peak: current.peakUsedPercent,
            current: newUsedPercent
        ) {
            return .refillDetected
        }

        let window = TimeInterval(current.rawWindowSeconds ?? 86_400)
        let meaningfulAdvance = max(300, window * 0.2)
        let crossedOldBoundary = now >= current.windowEnd.addingTimeInterval(-120)
        let resetForecastAdvanced = newResetAt.timeIntervalSince(current.windowEnd) >= meaningfulAdvance
        if crossedOldBoundary && resetForecastAdvanced {
            return .scheduledReset
        }
        return nil
    }

    private static func isMaterialRefill(previous: Double, peak: Double, current: Double) -> Bool {
        let normalizedPrevious = min(100, max(0, previous))
        let normalizedPeak = min(100, max(0, peak))
        let normalizedCurrent = min(100, max(0, current))
        let threshold = max(5, min(15, normalizedPeak * 0.2))
        return normalizedPrevious - normalizedCurrent >= threshold
            && normalizedPeak - normalizedCurrent >= threshold
    }

    private func makeCurrentSample(
        quota: AccountQuota,
        bucket: QuotaBucket,
        used: Double,
        resetAt: Date,
        now: Date
    ) -> SubscriptionWindowSample {
        SubscriptionWindowSample(
            accountId: quota.accountId,
            tool: quota.tool,
            bucketId: bucket.id,
            windowEnd: resetAt,
            windowStart: bucket.rawWindowSeconds.map {
                resetAt.addingTimeInterval(-TimeInterval($0))
            },
            rawWindowSeconds: bucket.rawWindowSeconds,
            peakUsedPercent: used,
            lastUsedPercent: used,
            observationCount: 1,
            firstSeenAt: now,
            lastSeenAt: now
        )
    }

    // MARK: - Persistence

    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    private func sampleSortDate(_ sample: SubscriptionWindowSample) -> Date {
        sample.completedAt ?? sample.lastSeenAt
    }

    private func load() -> Storage {
        if let cachedStorage { return cachedStorage }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = (attrs[.size] as? NSNumber)?.intValue,
           size > Self.maxFileBytes {
            let empty = Storage()
            cachedStorage = empty
            return empty
        }
        guard let data = try? Data(contentsOf: fileURL),
              let header = try? JSONDecoder().decode(VersionHeader.self, from: data),
              header.schemaVersion == Self.storageSchemaVersion,
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            let empty = Storage()
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
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000))
            await self?.flushPendingWrites()
        }
    }

    private func pruneInPlace(_ storage: inout Storage, retentionDays: Int, now: Date) {
        guard !CostDataSettings.isUnlimitedRetention(retentionDays) else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        storage.samples.removeAll {
            let relevantDate = $0.completedAt ?? $0.lastSeenAt
            return relevantDate < cutoff
        }
    }
}
