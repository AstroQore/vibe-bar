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
    public let tool: ToolType
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

/// One page of the request log. `page` is **zero-based**; a page past the
/// end is not an error, it just comes back with no rows and the real
/// `totalCount`.
public struct UsageRequestPage: Sendable, Equatable {
    public let rows: [UsageRequestRow]
    public let totalCount: Int
    public let page: Int
    public let pageSize: Int

    public init(rows: [UsageRequestRow], totalCount: Int, page: Int, pageSize: Int) {
        self.rows = rows
        self.totalCount = totalCount
        self.page = page
        self.pageSize = pageSize
    }

    public var pageCount: Int {
        guard pageSize > 0 else { return 0 }
        return (totalCount + pageSize - 1) / pageSize
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
