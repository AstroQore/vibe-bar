import Foundation

/// Persists inferred subscription cycles, not point-in-time samples.
///
/// Small `resetAt` changes remain forecast drift, but a move of at least ten
/// percent of the quota window is independent reset evidence. The active cycle
/// is finalized when usage materially drops, reset time clearly advances, or
/// concordant weak usage/reset signals jointly cross the evidence threshold.
/// This catches low-use and between-poll refills without turning a few seconds
/// of reset-time drift into thousands of fake weekly cycles.
public actor SubscriptionHistoryStore {
    public static let shared = SubscriptionHistoryStore()

    private struct Storage: Codable {
        var schemaVersion: Int
        var legacyTimelineImported: Bool
        /// One-time repair pass for reset transitions that older builds missed
        /// because they required a five-point usage drop. Optional keeps
        /// schema-v2 files backward compatible.
        var resetSignalRepairVersion: Int?
        var samples: [SubscriptionWindowSample]

        init(
            schemaVersion: Int = SubscriptionHistoryStore.storageSchemaVersion,
            legacyTimelineImported: Bool = false,
            resetSignalRepairVersion: Int? = nil,
            samples: [SubscriptionWindowSample] = []
        ) {
            self.schemaVersion = schemaVersion
            self.legacyTimelineImported = legacyTimelineImported
            self.resetSignalRepairVersion = resetSignalRepairVersion
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
    private static let currentResetSignalRepairVersion = 1
    private static let strongResetAdvanceFraction = 0.10
    private static let weakResetAdvanceFraction = 0.01
    private static let minimumStrongUsageDrop = 0.5
    private static let minimumWeakUsageDrop = 0.25
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

    /// One-time best-effort migration from the old hourly fill timeline.
    /// Material downward jumps and proportional reset-time advances become
    /// completed cycles; ordinary samples are intentionally discarded so the
    /// new chart starts truthful.
    public func importLegacyTimeline(
        _ points: [FillTimelinePoint],
        retentionDays: Int = CostDataSettings.defaultRetentionDays
    ) {
        var storage = load()
        let needsLegacyImport = !storage.legacyTimelineImported
        let needsResetSignalRepair = (storage.resetSignalRepairVersion ?? 0)
            < Self.currentResetSignalRepairVersion
        guard needsLegacyImport || needsResetSignalRepair else { return }

        if needsLegacyImport {
            storage.legacyTimelineImported = true
            importMaterialRefills(points, into: &storage)
        }

        if needsResetSignalRepair {
            repairMissedResetSignals(points, in: &storage)
            storage.resetSignalRepairVersion = Self.currentResetSignalRepairVersion
        }
        pruneInPlace(&storage, retentionDays: retentionDays, now: Date())
        save(storage)
    }

    private func importMaterialRefills(_ points: [FillTimelinePoint], into storage: inout Storage) {
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
    }

    /// Replays retained point observations once with the current reset-signal
    /// model. This repairs low-utilization and reset-time-only transitions
    /// missed by older builds without manufacturing cycles from ordinary
    /// reset forecast drift.
    private func repairMissedResetSignals(
        _ points: [FillTimelinePoint],
        in storage: inout Storage
    ) {
        let grouped = Dictionary(grouping: points) {
            SubscriptionHistoryKey(accountId: $0.accountId, bucketId: $0.bucketId)
        }
        for (_, rawPoints) in grouped {
            let sorted = rawPoints.sorted { $0.sampledAt < $1.sampledAt }
            guard let first = sorted.first,
                  sorted.count > 1,
                  Self.supportedTools.contains(first.tool)
            else { continue }

            var previous = first
            var segmentStart = first.sampledAt
            var segmentPeak = clamp(first.usedPercent)
            var segmentObservationCount = 1
            var addedRepair = false

            for point in sorted.dropFirst() {
                let currentUsed = clamp(point.usedPercent)
                let windowSeconds = previous.rawWindowSeconds ?? point.rawWindowSeconds
                let previousResetAt = previous.resetAt ?? previous.sampledAt
                let provisional = SubscriptionWindowSample(
                    accountId: first.accountId,
                    tool: first.tool,
                    bucketId: first.bucketId,
                    windowEnd: previousResetAt,
                    windowStart: segmentStart,
                    rawWindowSeconds: windowSeconds,
                    peakUsedPercent: segmentPeak,
                    lastUsedPercent: clamp(previous.usedPercent),
                    observationCount: segmentObservationCount,
                    firstSeenAt: segmentStart,
                    lastSeenAt: previous.sampledAt
                )
                let newResetAt = point.resetAt ?? previousResetAt
                let reason = completionReason(
                    for: provisional,
                    newUsedPercent: currentUsed,
                    newResetAt: newResetAt,
                    now: point.sampledAt
                )

                if let reason {
                    if !hasNearbyCompletedSample(
                        accountId: first.accountId,
                        bucketId: first.bucketId,
                        completedAt: point.sampledAt,
                        windowSeconds: windowSeconds,
                        in: storage.samples
                    ) {
                        storage.samples.append(SubscriptionWindowSample(
                            accountId: first.accountId,
                            tool: first.tool,
                            bucketId: first.bucketId,
                            windowEnd: point.sampledAt,
                            windowStart: segmentStart,
                            rawWindowSeconds: windowSeconds,
                            peakUsedPercent: segmentPeak,
                            lastUsedPercent: clamp(previous.usedPercent),
                            observationCount: segmentObservationCount,
                            firstSeenAt: segmentStart,
                            lastSeenAt: previous.sampledAt,
                            completedAt: point.sampledAt,
                            completionReason: reason
                        ))
                        addedRepair = true
                    }
                    segmentStart = point.sampledAt
                    segmentPeak = currentUsed
                    segmentObservationCount = 1
                } else {
                    segmentPeak = max(segmentPeak, currentUsed)
                    segmentObservationCount += 1
                }
                previous = point
            }

            guard addedRepair else { continue }
            let activeIndex = storage.samples.indices
                .filter {
                    storage.samples[$0].accountId == first.accountId
                        && storage.samples[$0].bucketId == first.bucketId
                        && !storage.samples[$0].isCompleted
                }
                .max { storage.samples[$0].lastSeenAt < storage.samples[$1].lastSeenAt }
            guard let activeIndex,
                  storage.samples[activeIndex].firstSeenAt < segmentStart
            else { continue }

            let currentResetAt = previous.resetAt ?? storage.samples[activeIndex].windowEnd
            let currentWindowSeconds = previous.rawWindowSeconds
                ?? storage.samples[activeIndex].rawWindowSeconds
            storage.samples[activeIndex] = SubscriptionWindowSample(
                accountId: first.accountId,
                tool: first.tool,
                bucketId: first.bucketId,
                windowEnd: currentResetAt,
                windowStart: currentWindowSeconds.map {
                    currentResetAt.addingTimeInterval(-TimeInterval($0))
                } ?? segmentStart,
                rawWindowSeconds: currentWindowSeconds,
                peakUsedPercent: segmentPeak,
                lastUsedPercent: clamp(previous.usedPercent),
                observationCount: segmentObservationCount,
                firstSeenAt: segmentStart,
                lastSeenAt: previous.sampledAt
            )
        }
    }

    private func hasNearbyCompletedSample(
        accountId: String,
        bucketId: String,
        completedAt: Date,
        windowSeconds: Int?,
        in samples: [SubscriptionWindowSample]
    ) -> Bool {
        let tolerance = Self.repairDuplicateTolerance(windowSeconds: windowSeconds)
        return samples.contains {
            $0.accountId == accountId
                && $0.bucketId == bucketId
                && $0.completedAt.map { abs($0.timeIntervalSince(completedAt)) <= tolerance } == true
        }
    }

    private static func repairDuplicateTolerance(windowSeconds: Int?) -> TimeInterval {
        switch windowSeconds {
        case let seconds? where seconds <= 6 * 3_600:
            return 10 * 60
        case let seconds? where seconds <= 8 * 86_400:
            return 2 * 3_600
        case let seconds? where seconds <= 45 * 86_400:
            return 12 * 3_600
        default:
            return 2 * 3_600
        }
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
        let resetAdvance = max(0, newResetAt.timeIntervalSince(current.windowEnd))
        let meaningfulAdvance = max(300, window * Self.strongResetAdvanceFraction)
        if resetAdvance >= meaningfulAdvance {
            // A provider can refill and consume again between polls, so a
            // clear move into the next reset window is sufficient even when
            // the newly observed usage is equal to or above the old value.
            return .scheduledReset
        }

        let weakAdvance = max(300, window * Self.weakResetAdvanceFraction)
        let crossedOldBoundary = now >= current.windowEnd.addingTimeInterval(-120)
        if crossedOldBoundary && resetAdvance >= weakAdvance {
            return .scheduledReset
        }

        let usageDrop = max(0, current.lastUsedPercent - newUsedPercent)
        let usageThreshold = Self.materialRefillThreshold(previous: current.lastUsedPercent)
        if usageDrop >= Self.minimumWeakUsageDrop,
           resetAdvance >= weakAdvance,
           usageDrop / usageThreshold + resetAdvance / meaningfulAdvance >= 1 {
            // Two concordant weak signals can identify a refill even though
            // neither clears its standalone threshold.
            return .scheduledReset
        }
        return nil
    }

    private static func isMaterialRefill(previous: Double, peak: Double, current: Double) -> Bool {
        let normalizedPrevious = min(100, max(0, previous))
        let normalizedPeak = min(100, max(0, peak))
        let normalizedCurrent = min(100, max(0, current))
        let threshold = materialRefillThreshold(previous: normalizedPrevious)
        return normalizedPrevious - normalizedCurrent >= threshold
            && normalizedPeak - normalizedCurrent >= threshold
    }

    private static func materialRefillThreshold(previous: Double) -> Double {
        max(minimumStrongUsageDrop, min(15, previous * 0.2))
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
