import Foundation

/// The ledger surface the assembler needs, narrowed to three calls.
///
/// `UsageEventLedger` is an actor, so every query already crosses an
/// isolation boundary; declaring the protocol `async` lets the real ledger
/// satisfy it directly while a test feeds a plain value type.
public protocol EInkUsageQuerying: Sendable {
    func summary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics
    func harnessStats(_ filter: UsageQueryFilter) async throws -> [UsageHarnessStat]
    func trend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket) async throws -> UsageTrendSeries
    /// Today's per-model rows, for the Top Models layout.
    func modelStats(_ filter: UsageQueryFilter) async throws -> [UsageModelStat]
}

public extension EInkUsageQuerying {
    /// Defaulted so a source that predates the Top Models layout — or a test
    /// that only cares about totals — does not have to answer it. An empty
    /// list draws no rows, which is the honest answer for a source that has
    /// none.
    func modelStats(_ filter: UsageQueryFilter) async throws -> [UsageModelStat] { [] }
}

/// Builds an `EInkDataSnapshot` from injected sources.
///
/// Everything it needs arrives as a closure or a protocol so the whole
/// pipeline — assembly, layout, encoding — can be exercised with synthetic
/// numbers and no ledger, network, or device.
public struct EInkDataAssembler: Sendable {
    /// One quota bucket the panel is allowed to show, in display priority.
    public struct QuotaSelector: Sendable, Equatable {
        public var tool: ToolType
        public var bucketID: String

        public init(tool: ToolType, bucketID: String) {
            self.tool = tool
            self.bucketID = bucketID
        }

        public var fieldID: String { MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucketID) }
    }

    /// The demo's verified priority order. Anything the account does not
    /// expose is skipped rather than drawn empty.
    public static let defaultQuotaPriority: [QuotaSelector] = [
        QuotaSelector(tool: .claude, bucketID: "five_hour"),
        QuotaSelector(tool: .claude, bucketID: "weekly"),
        QuotaSelector(tool: .codex, bucketID: "weekly"),
        QuotaSelector(tool: .grok, bucketID: "weekly"),
        QuotaSelector(tool: .antigravity, bucketID: "claude_gpt_weekly"),
        QuotaSelector(tool: .gemini, bucketID: "weekly"),
        QuotaSelector(tool: .cursor, bucketID: "models")
    ]

    /// The selector a `MenuBarFieldCatalog` field id names, or `nil` when the
    /// id is not a `<tool>.<bucket>` pair this build knows a tool for.
    public static func selector(fieldID: String) -> QuotaSelector? {
        guard let dot = fieldID.firstIndex(of: ".") else { return nil }
        let rawTool = String(fieldID[fieldID.startIndex..<dot])
        let bucketID = String(fieldID[fieldID.index(after: dot)...])
        guard !bucketID.isEmpty, let tool = ToolType(rawValue: rawTool) else { return nil }
        return QuotaSelector(tool: tool, bucketID: bucketID)
    }

    /// The verified priority order, followed by anything a slide picked that
    /// the order does not already cover.
    ///
    /// Without this the picker would be a trap: it lists every bucket the
    /// catalog and the runtime registry know, while the snapshot only ever
    /// carried the seven in `defaultQuotaPriority` — so choosing, say, Codex's
    /// 5 Hours drew an empty row on a panel across the room, which is the one
    /// failure mode a glanceable surface cannot afford.
    public static func priority(includingSelected fieldIDs: [String]) -> [QuotaSelector] {
        var seen = Set(defaultQuotaPriority.map(\.fieldID))
        var result = defaultQuotaPriority
        for fieldID in fieldIDs {
            guard seen.insert(fieldID).inserted, let selector = selector(fieldID: fieldID) else { continue }
            result.append(selector)
        }
        return result
    }

    public var quotaLookup: @Sendable (ToolType) async -> AccountQuota?
    public var usage: any EInkUsageQuerying
    /// Per-tool cost snapshots; their all-time columns and their activity
    /// heatmaps are read.
    public var allTimeCostSnapshots: @Sendable () async -> [CostSnapshot]
    /// The pace verdict for one bucket, injected like the quota lookup so the
    /// whole pipeline stays testable without `QuotaService`.
    public var forecastLookup: @Sendable (ToolType, QuotaBucket) async -> QuotaPaceForecast?
    /// Provider health, for the header's provider-status option.
    public var serviceStatus: @Sendable () async -> [ServiceStatusSnapshot]
    /// Resolves a slot's default name; discovered buckets need the registry.
    ///
    /// The snapshot carries the *default* name and nothing else. A slide's own
    /// override is applied while that slide draws (`EInkQuotaRow.relabeled`),
    /// because the snapshot is shared: merging overrides here meant two slides
    /// naming the same bucket differently both got the first one's name.
    public var registry: QuotaFieldRegistry
    public var quotaPriority: [QuotaSelector]
    public var calendar: Calendar

    public init(
        quotaLookup: @escaping @Sendable (ToolType) async -> AccountQuota?,
        usage: any EInkUsageQuerying,
        allTimeCostSnapshots: @escaping @Sendable () async -> [CostSnapshot],
        forecastLookup: @escaping @Sendable (ToolType, QuotaBucket) async -> QuotaPaceForecast? = { _, _ in nil },
        serviceStatus: @escaping @Sendable () async -> [ServiceStatusSnapshot] = { [] },
        registry: QuotaFieldRegistry = .empty,
        quotaPriority: [QuotaSelector] = EInkDataAssembler.defaultQuotaPriority,
        calendar: Calendar = .current
    ) {
        self.quotaLookup = quotaLookup
        self.usage = usage
        self.allTimeCostSnapshots = allTimeCostSnapshots
        self.forecastLookup = forecastLookup
        self.serviceStatus = serviceStatus
        self.registry = registry
        self.quotaPriority = quotaPriority
        self.calendar = calendar
    }

    public func snapshot(now: Date = Date()) async throws -> EInkDataSnapshot {
        let quota = await quotaRows(now: now)
        let usageSet = try await usageSet(now: now)
        let trend = try await trendPoints(now: now)
        return EInkDataSnapshot(
            generatedAt: now,
            generatedAtLabel: EInkFormat.timestampLabel(now, calendar: calendar),
            generatedAtISO: Self.iso8601.string(from: now),
            quota: quota,
            usage: usageSet,
            trend: trend,
            clockLabel: EInkFormat.clockLabel(now, calendar: calendar),
            dateLabel: EInkFormat.dateLabel(now, calendar: calendar),
            heatmap: EInkHeatmap.summing(await allTimeCostSnapshots().map(\.heatmap)),
            topModels: (try? await modelRows(now: now)) ?? [],
            providerStatusLine: EInkProviderStatusLine.compose(await serviceStatus())
        )
    }

    /// Assembles what the pass actually needs, and never throws.
    ///
    /// Two rules, both about not losing the half that works:
    ///
    /// - The ledger is queried only when a slide draws usage. A device showing
    ///   nothing but quota rows has no business walking a SQLite index every
    ///   fifteen minutes, and a broken ledger must not stop it.
    /// - A usage query that fails leaves the usage columns empty and says so.
    ///   The caller pushes the quota slides and reports the gap; refusing the
    ///   whole pass would blank a panel over data half its slides never
    ///   touched.
    public func assemble(now: Date = Date(), includeUsage: Bool) async -> EInkAssemblyOutcome {
        let quota = await quotaRows(now: now)
        var usage = EInkUsageSet()
        var trend: [EInkTrendPoint] = []
        var models: [EInkModelRow] = []
        var heatmap = EInkHeatmap.empty
        var usageUnavailable = false
        if includeUsage {
            do {
                usage = try await usageSet(now: now)
                trend = try await trendPoints(now: now)
                models = try await modelRows(now: now)
                heatmap = EInkHeatmap.summing(await allTimeCostSnapshots().map(\.heatmap))
            } catch {
                usage = EInkUsageSet()
                trend = []
                models = []
                heatmap = .empty
                usageUnavailable = true
                SafeLog.warn("eink usage assembly failed: \(SafeLog.sanitize(String(describing: error)))")
            }
        }
        return EInkAssemblyOutcome(
            snapshot: EInkDataSnapshot(
                generatedAt: now,
                generatedAtLabel: EInkFormat.timestampLabel(now, calendar: calendar),
                generatedAtISO: Self.iso8601.string(from: now),
                quota: quota,
                usage: usage,
                trend: trend,
                clockLabel: EInkFormat.clockLabel(now, calendar: calendar),
                dateLabel: EInkFormat.dateLabel(now, calendar: calendar),
                heatmap: heatmap,
                topModels: models,
                providerStatusLine: EInkProviderStatusLine.compose(await serviceStatus())
            ),
            usageUnavailable: usageUnavailable
        )
    }

    // MARK: - Quota

    func quotaRows(now: Date) async -> [EInkQuotaRow] {
        var byTool: [ToolType: AccountQuota?] = [:]
        var rows: [EInkQuotaRow] = []
        for selector in quotaPriority {
            let account: AccountQuota?
            if let cached = byTool[selector.tool] {
                account = cached
            } else {
                account = await quotaLookup(selector.tool)
                byTool[selector.tool] = account
            }
            guard let account, let bucket = account.bucket(id: selector.bucketID) else { continue }
            let remaining = Int((100 - bucket.usedPercent).rounded())
            let parts = EInkSlotLabel.parts(for: selector.fieldID, registry: registry, bucket: bucket)
            rows.append(
                EInkQuotaRow(
                    fieldID: selector.fieldID,
                    // Tier 1 on its own line, tiers 2 and 3 on the next: the
                    // split every two-line slot needs, and exactly what
                    // "provider · window" already meant to the one-line ones.
                    providerDisplayName: parts.first ?? selector.tool.quotaSubProviderName(bucketID: selector.bucketID),
                    windowTitle: parts.dropFirst().joined(separator: EInkSlotLabel.separator),
                    remainingPercent: remaining,
                    resetAt: bucket.resetAt,
                    countdown: EInkFormat.countdown(bucket.resetAt, now: now),
                    plan: account.plan ?? "",
                    forecast: await forecastLookup(selector.tool, bucket).map(EInkQuotaForecast.init)
                )
            )
        }
        return rows
    }

    /// The window as the panel prints it, written out in full.
    ///
    /// Never `shortLabel`. That field exists for the menu bar, where "5h" and
    /// "WK" buy back pixels that matter; a panel across a desk has 296 of them
    /// and an abbreviation there is just a word the reader has to decode. The
    /// group title is the only fallback, because it is written out too — a
    /// bucket with neither draws no window word at all rather than an
    /// abbreviation nobody asked for.
    static func windowTitle(for bucket: QuotaBucket) -> String {
        if !bucket.title.isEmpty { return bucket.title }
        return bucket.groupTitle ?? ""
    }

    // MARK: - Usage

    func usageSet(now: Date) async throws -> EInkUsageSet {
        let midnight = calendar.startOfDay(for: now)
        let today = try await totals(range: DateInterval(start: midnight, end: max(midnight, now)))
        let week = try await totals(range: rollingRange(days: 7, now: now))
        let month = try await totals(range: rollingRange(days: 30, now: now))
        var allTime = EInkUsageTotals()
        for snapshot in await allTimeCostSnapshots() {
            allTime.costUSD += snapshot.allTimeCostUSD
            allTime.tokens += Int64(snapshot.allTimeTokens)
            allTime.requests += snapshot.allTimeRequests
        }
        return EInkUsageSet(today: today, week: week, month: month, allTime: allTime)
    }

    private func rollingRange(days: Int, now: Date) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now.addingTimeInterval(-Double(days) * 86_400)
        return DateInterval(start: min(start, now), end: now)
    }

    private func totals(range: DateInterval) async throws -> EInkUsageTotals {
        let filter = UsageQueryFilter(range: range)
        let summary = try await usage.summary(filter)
        let harnessRows = UsageHarnessStat.mergedByHarness(try await usage.harnessStats(filter))
            .sorted { $0.costMicros > $1.costMicros }
            .map {
                EInkHarnessRow(
                    label: $0.harness.displayName,
                    costUSD: Self.usd($0.costMicros),
                    tokens: $0.totalTokens,
                    requests: $0.requests
                )
            }
        return EInkUsageTotals(
            costUSD: Self.usd(summary.costMicros ?? 0),
            tokens: summary.realTotalTokens,
            requests: summary.requests,
            rows: harnessRows
        )
    }

    // MARK: - Models

    func modelRows(now: Date) async throws -> [EInkModelRow] {
        let midnight = calendar.startOfDay(for: now)
        let filter = UsageQueryFilter(range: DateInterval(start: midnight, end: max(midnight, now)))
        return try await usage.modelStats(filter)
            .sorted { $0.costMicros > $1.costMicros }
            .prefix(8)
            .map {
                EInkModelRow(
                    model: $0.model,
                    costUSD: Self.usd($0.costMicros),
                    tokens: $0.totalTokens,
                    requests: $0.requests
                )
            }
    }

    // MARK: - Trend

    func trendPoints(now: Date) async throws -> [EInkTrendPoint] {
        let startOfToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let series = try await usage.trend(UsageQueryFilter(range: DateInterval(start: start, end: end)), bucket: .day)
        return series.points.suffix(7).map { point in
            EInkTrendPoint(
                bucketStart: point.bucketStart,
                dayLabel: Self.dayLabel(point.bucketStart, calendar: calendar),
                weekdayLabel: Self.weekdayLabel(point.bucketStart, calendar: calendar),
                costUSD: Self.usd(point.costMicros),
                tokens: point.totalTokens
            )
        }
    }

    // MARK: - Helpers

    static func usd(_ micros: Int64) -> Double { Double(micros) / 1_000_000 }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d", calendar.component(.day, from: date))
    }

    static func weekdayLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}


/// What one assembly produced, and whether the usage half of it is missing.
public struct EInkAssemblyOutcome: Sendable, Equatable {
    public var snapshot: EInkDataSnapshot
    public var usageUnavailable: Bool

    public init(snapshot: EInkDataSnapshot, usageUnavailable: Bool = false) {
        self.snapshot = snapshot
        self.usageUnavailable = usageUnavailable
    }
}

/// What the engine asks an assembly for.
public struct EInkSnapshotRequest: Sendable, Equatable {
    /// Quota buckets any slide picked, on top of the default priority order.
    public var quotaFieldIDs: [String]
    /// False when no slide on this pass draws usage.
    public var includesUsage: Bool
    public init(quotaFieldIDs: [String], includesUsage: Bool) {
        self.quotaFieldIDs = quotaFieldIDs
        self.includesUsage = includesUsage
    }
}
