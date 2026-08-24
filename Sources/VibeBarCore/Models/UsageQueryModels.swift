import Foundation

/// Query surface for the per-request usage ledger (`UsageEventLedger`).
///
/// Every type here is a plain value: the ledger is an actor, so query
/// results have to cross an isolation boundary and must be `Sendable`.
/// Money is always `Int64` micro-USD (1 USD = 1_000_000 micros) — the
/// ledger never stores or sums a `Double`, so totals over millions of
/// requests stay exact. Formatting back to a `$x.yz` string is
/// `UsageFormatting`'s job.

// MARK: - Filter

/// Range + optional provider / model narrowing applied to every query.
///
/// `range` is half-open: `start` inclusive, `end` exclusive.
/// A `nil` list means "no restriction"; an *empty* list means "nothing
/// matches" and every query returns an empty result for it.
public struct UsageQueryFilter: Sendable, Equatable {
    public var range: DateInterval
    public var tools: [ToolType]?
    /// Local harnesses to keep. Orthogonal to `tools`: a company chip narrows
    /// the quota-side tool, this narrows the CLI / app the events came from.
    public var harnesses: [Harness]?
    public var models: [String]?

    public init(
        range: DateInterval,
        tools: [ToolType]? = nil,
        harnesses: [Harness]? = nil,
        models: [String]? = nil
    ) {
        self.range = range
        self.tools = tools
        self.harnesses = harnesses
        self.models = models
    }
}

// MARK: - Trend bucketing

public enum UsageTrendBucket: String, Sendable, Equatable, CaseIterable, Codable {
    case hour
    case day
    case week

    /// A day of history or less is drawn per hour; anything wider is drawn
    /// per local calendar day. Wider windows collapse to local calendar
    /// weeks, keeping the automatic chart legible without making a UI-only
    /// decision that disagrees with the ledger.
    public static func recommended(for range: DateInterval) -> UsageTrendBucket {
        if range.duration <= 24 * 60 * 60 { return .hour }
        if range.duration <= 45 * 24 * 60 * 60 { return .day }
        return .week
    }
}

extension Optional where Wrapped == UsageTrendBucket {
    /// The chart control's intent: an explicit bucket, or `nil` for
    /// "automatic", which resolves through the same Core policy as callers
    /// that do not specify a bucket. Changing it always changes the
    /// underlying query rather than merely relabelling an already-built
    /// series.
    public func resolved(for range: DateInterval) -> UsageTrendBucket {
        self ?? .recommended(for: range)
    }
}

// MARK: - Summary

/// Headline metrics over a filter.
///
/// Token columns are already normalized by the ledger: `freshInput` is
/// non-cached prompt tokens, `cacheRead` is cache hits, `cacheCreation` is
/// cache writes. They never overlap, so they can be summed freely.
public struct UsageSummaryMetrics: Sendable, Equatable {
    public let requests: Int
    /// Requests whose provider/model had no usable price. They contribute
    /// `0` to `costMicros`; this counter is how a UI says "3 of 40 requests
    /// are unpriced" instead of silently under-reporting spend.
    public let unpricedRequests: Int
    /// `nil` only when *no* row in range carried a price at all. A mix of
    /// priced and unpriced rows still reports the priced subtotal.
    public let costMicros: Int64?
    public let freshInput: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheCreation: Int64

    public init(
        requests: Int,
        unpricedRequests: Int,
        costMicros: Int64?,
        freshInput: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheCreation: Int64
    ) {
        self.requests = requests
        self.unpricedRequests = unpricedRequests
        self.costMicros = costMicros
        self.freshInput = freshInput
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
    }

    public static let empty = UsageSummaryMetrics(
        requests: 0,
        unpricedRequests: 0,
        costMicros: nil,
        freshInput: 0,
        output: 0,
        cacheRead: 0,
        cacheCreation: 0
    )

    /// Every token the provider actually moved, cache hits included.
    public var realTotalTokens: Int64 {
        freshInput + output + cacheCreation + cacheRead
    }

    /// Share of *input-side* tokens served from cache. Output tokens are
    /// deliberately excluded — they are never cacheable, and folding them in
    /// would make a chatty session look like a cache miss. `nil` when there
    /// was no input-side traffic at all.
    public var cacheHitRate: Double? {
        let denominator = freshInput + cacheCreation + cacheRead
        guard denominator > 0 else { return nil }
        return Double(cacheRead) / Double(denominator)
    }
}

/// Token-only headline windows for the Overview, derived from the canonical
/// request ledger rather than the cost snapshot cache.
public struct UsageTokenHeadlineTotals: Sendable, Equatable {
    public let allTimeTokens: Int64
    public let todayTokens: Int64
    public let yesterdayTokens: Int64
    public let last7DaysTokens: Int64
    public let last30DaysTokens: Int64
    public let peakDayTokens: Int64
    public let peakDay: Date?

    public init(
        allTimeTokens: Int64,
        todayTokens: Int64,
        yesterdayTokens: Int64,
        last7DaysTokens: Int64,
        last30DaysTokens: Int64,
        peakDayTokens: Int64,
        peakDay: Date?
    ) {
        self.allTimeTokens = allTimeTokens
        self.todayTokens = todayTokens
        self.yesterdayTokens = yesterdayTokens
        self.last7DaysTokens = last7DaysTokens
        self.last30DaysTokens = last30DaysTokens
        self.peakDayTokens = peakDayTokens
        self.peakDay = peakDay
    }
}

// MARK: - Trend series

public struct UsageTrendPoint: Sendable, Equatable, Identifiable {
    public let bucketStart: Date
    public let freshInput: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheCreation: Int64
    public let costMicros: Int64

    public var id: Date { bucketStart }

    public init(
        bucketStart: Date,
        freshInput: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheCreation: Int64,
        costMicros: Int64
    ) {
        self.bucketStart = bucketStart
        self.freshInput = freshInput
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.costMicros = costMicros
    }

    public var totalTokens: Int64 {
        freshInput + output + cacheRead + cacheCreation
    }
}

/// One provider's zero-filled projection of a trend. It deliberately shares
/// the parent series' buckets, which keeps legend, lines, hover selection and
/// totals on one semantic source of truth.
public struct UsageProviderTrendSeries: Sendable, Equatable, Identifiable {
    public let tool: ToolType
    public let points: [UsageTrendPoint]

    public var id: ToolType { tool }

    public init(tool: ToolType, points: [UsageTrendPoint]) {
        self.tool = tool
        self.points = points
    }
}

/// Zero-filled series: every bucket between the filter's `start` and `end`
/// is present, including the empty ones, so a chart never has to invent
/// gaps.
public struct UsageTrendSeries: Sendable, Equatable {
    public let bucket: UsageTrendBucket
    public let points: [UsageTrendPoint]
    public let providerSeries: [UsageProviderTrendSeries]

    public init(
        bucket: UsageTrendBucket,
        points: [UsageTrendPoint],
        providerSeries: [UsageProviderTrendSeries] = []
    ) {
        self.bucket = bucket
        self.points = points
        self.providerSeries = providerSeries
    }
}

// MARK: - Request log

public struct UsageRequestRow: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let date: Date
    /// Quota-axis tool the request is billed against.
    public let tool: ToolType
    /// Usage-axis producer: the CLI or app the request came from. Request
    /// surfaces name this one, because a request log is usage, not quota.
    public let harness: Harness
    public let model: String
    public let freshInput: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheCreation: Int64
    public let costMicros: Int64?
    public let serviceTier: String?
    public let sessionId: String?
    public let sourceKey: String?

    public init(
        id: Int64,
        date: Date,
        tool: ToolType,
        harness: Harness,
        model: String,
        freshInput: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheCreation: Int64,
        costMicros: Int64?,
        serviceTier: String?,
        sessionId: String?,
        sourceKey: String?
    ) {
        self.id = id
        self.date = date
        self.tool = tool
        self.harness = harness
        self.model = model
        self.freshInput = freshInput
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.costMicros = costMicros
        self.serviceTier = serviceTier
        self.sessionId = sessionId
        self.sourceKey = sourceKey
    }

    public var totalTokens: Int64 {
        freshInput + output + cacheRead + cacheCreation
    }
}

/// A position in the request log's `ts DESC, id DESC` ordering.
///
/// Paging by `LIMIT`/`OFFSET` makes SQLite re-walk and re-skip everything
/// ahead of the page, and it silently drops or repeats rows when the ledger
/// gains events between two pages. A cursor names the last row of the page
/// the caller already has, so the next page is a range scan that starts
/// exactly where the previous one stopped. `id` breaks the tie between
/// events that share a second.
public struct UsageRequestCursor: Sendable, Equatable, Hashable {
    public let ts: Int64
    public let id: Int64

    public init(ts: Int64, id: Int64) {
        self.ts = ts
        self.id = id
    }
}

/// One page of the request log, newest first. A page past the end is not an
/// error: it comes back with no rows, no `nextCursor`, and the real
/// `totalCount`.
public struct UsageRequestPage: Sendable, Equatable {
    public let rows: [UsageRequestRow]
    /// Detail rows matching the filter, or `nil` when the caller asked not to
    /// recount. The count is a full scan of the matched set and it cannot
    /// change while the filter is pinned, so continuing a run re-uses the
    /// number the first page already reported.
    public let totalCount: Int?
    public let pageSize: Int
    /// The cursor this page continued from — `nil` for the first page. Lets a
    /// caller drop a page that answers a position it has already moved past.
    public let cursor: UsageRequestCursor?
    /// Pass as `after:` to fetch the next page. `nil` ends the sequence.
    public let nextCursor: UsageRequestCursor?

    public init(
        rows: [UsageRequestRow],
        totalCount: Int?,
        pageSize: Int,
        cursor: UsageRequestCursor? = nil,
        nextCursor: UsageRequestCursor? = nil
    ) {
        self.rows = rows
        self.totalCount = totalCount
        self.pageSize = pageSize
        self.cursor = cursor
        self.nextCursor = nextCursor
    }
}

// MARK: - Grouped stats

public struct UsageProviderStat: Sendable, Equatable, Identifiable {
    public let tool: ToolType
    public let requests: Int
    public let totalTokens: Int64
    public let costMicros: Int64

    public var id: ToolType { tool }

    public init(tool: ToolType, requests: Int, totalTokens: Int64, costMicros: Int64) {
        self.tool = tool
        self.requests = requests
        self.totalTokens = totalTokens
        self.costMicros = costMicros
    }

    /// Collapse tool/SubProvider rows into the L1 company/brand totals used by
    /// Provider Mix and the Providers table. Filters and request rows remain
    /// at L2 so users can still narrow individual SubProviders.
    public static func mergedByCompany(_ rows: [UsageProviderStat]) -> [UsageProviderStat] {
        var totals: [ToolType: (requests: Int, tokens: Int64, cost: Int64)] = [:]
        for row in rows {
            let representative = row.tool.coreProviderRepresentative ?? row.tool
            totals[representative, default: (0, 0, 0)].requests += row.requests
            totals[representative, default: (0, 0, 0)].tokens += row.totalTokens
            totals[representative, default: (0, 0, 0)].cost += row.costMicros
        }
        return totals.map { tool, total in
            UsageProviderStat(
                tool: tool,
                requests: total.requests,
                totalTokens: total.tokens,
                costMicros: total.cost
            )
        }.sorted {
            $0.totalTokens == $1.totalTokens
                ? $0.tool.vendorName < $1.tool.vendorName
                : $0.totalTokens > $1.totalTokens
        }
    }


}

/// Totals for one local harness — the unit every usage / cost surface groups
/// by. Never mixed with `UsageProviderStat` in the same list: that one speaks
/// the quota hierarchy's company level, this one speaks harnesses.
public struct UsageHarnessStat: Sendable, Equatable, Identifiable {
    public let harness: Harness
    public let requests: Int
    public let totalTokens: Int64
    public let costMicros: Int64

    public var id: Harness { harness }

    public init(harness: Harness, requests: Int, totalTokens: Int64, costMicros: Int64) {
        self.harness = harness
        self.requests = requests
        self.totalTokens = totalTokens
        self.costMicros = costMicros
    }

    /// Fold the ledger's raw `(tool, harness)` groups into one row per
    /// harness, heaviest first.
    ///
    /// The merge is real work, not a formality: a ledger migrated from before
    /// the harness dimension existed can hold both a backfilled group and a
    /// freshly stamped one for the same harness, and rows for one harness can
    /// arrive under more than one group key while a re-scan is in flight.
    public static func mergedByHarness(_ rows: [UsageHarnessStat]) -> [UsageHarnessStat] {
        var totals: [Harness: (requests: Int, tokens: Int64, cost: Int64)] = [:]
        for row in rows {
            totals[row.harness, default: (0, 0, 0)].requests += row.requests
            totals[row.harness, default: (0, 0, 0)].tokens += row.totalTokens
            totals[row.harness, default: (0, 0, 0)].cost += row.costMicros
        }
        return totals.map { harness, total in
            UsageHarnessStat(
                harness: harness,
                requests: total.requests,
                totalTokens: total.tokens,
                costMicros: total.cost
            )
        }.sorted {
            $0.totalTokens == $1.totalTokens
                ? $0.harness.displayName < $1.harness.displayName
                : $0.totalTokens > $1.totalTokens
        }
    }
}

public struct UsageModelStat: Sendable, Equatable, Identifiable {
    public let model: String
    public let requests: Int
    public let totalTokens: Int64
    public let costMicros: Int64
    /// Integer micro-USD, half-up rounded. Zero when `requests == 0`.
    public let avgCostMicrosPerRequest: Int64

    public var id: String { model }

    public init(
        model: String,
        requests: Int,
        totalTokens: Int64,
        costMicros: Int64,
        avgCostMicrosPerRequest: Int64
    ) {
        self.model = model
        self.requests = requests
        self.totalTokens = totalTokens
        self.costMicros = costMicros
        self.avgCostMicrosPerRequest = avgCostMicrosPerRequest
    }

    /// Half-up integer average, kept out of `Double` so a long tail of
    /// cheap requests can't drift the reported per-request cost.
    public static func averageMicros(total: Int64, requests: Int) -> Int64 {
        guard requests > 0 else { return 0 }
        let count = Int64(requests)
        if total >= 0 { return (total + count / 2) / count }
        return -((-total + count / 2) / count)
    }
}

/// Request-level usage attributed to one local project directory.
///
/// This dimension is intentionally path-backed: `name` is presentation only,
/// while `id` remains the normalized absolute path so two repositories with
/// the same last component never collapse into one row.
public struct UsageProjectStat: Sendable, Equatable, Identifiable {
    public let path: String
    public let requests: Int
    public let totalTokens: Int64
    public let costMicros: Int64

    public var id: String { path }
    public var name: String { UsageProjectIdentity.displayName(for: path) }

    public init(path: String, requests: Int, totalTokens: Int64, costMicros: Int64) {
        self.path = path
        self.requests = requests
        self.totalTokens = totalTokens
        self.costMicros = costMicros
    }
}
