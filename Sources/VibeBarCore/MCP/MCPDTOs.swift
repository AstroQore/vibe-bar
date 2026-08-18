import Foundation

/// Codable projections of the Core types the MCP tools answer with.
///
/// Most of those types are deliberately not `Codable` (`UsageQueryFilter`,
/// `UsageSummaryMetrics`, `SessionSummaryPage`, the pricing rows), and the
/// ones that are encode a persistence shape rather than a wire shape. Keeping
/// a projection layer here means the on-disk formats stay free to change
/// without breaking an agent's parsing, and it is the one place that decides
/// what an agent is allowed to see.
///
/// **Field style is camelCase, everywhere, and it is pinned by
/// `MCPDTOEncodingTests`.** Money is reported twice — exact `costMicros`
/// (Int64 micro-USD, what the ledger actually stores) and a rounded `costUSD`
/// for display — so an agent never has to guess at the unit.
/// Emails are masked through `EmailMasker`; nothing here can carry a cookie,
/// a token, or an organization id.

// MARK: - Shared

public enum MCPMoney {
    /// Micro-USD → USD, rounded to cents. The micros stay alongside it for
    /// anything that needs to add totals up without drift.
    public static func usd(_ micros: Int64) -> Double {
        (Double(micros) / 1_000_000.0 * 100).rounded() / 100
    }
}

public struct MCPRangeDTO: Codable, Equatable, Sendable {
    public let from: Date
    public let to: Date

    public init(from: Date, to: Date) {
        self.from = from
        self.to = to
    }
}

// MARK: - quota.get

public struct MCPQuotaForecastDTO: Codable, Equatable, Sendable {
    public let verdict: String
    public let confidence: String
    public let currentUsedPercent: Double
    public let projectedUsedPercent: Double
    public let projectedUsedLowerPercent: Double
    public let projectedUsedUpperPercent: Double
    public let runOutAt: Date?

    public init(
        verdict: String,
        confidence: String,
        currentUsedPercent: Double,
        projectedUsedPercent: Double,
        projectedUsedLowerPercent: Double,
        projectedUsedUpperPercent: Double,
        runOutAt: Date?
    ) {
        self.verdict = verdict
        self.confidence = confidence
        self.currentUsedPercent = currentUsedPercent
        self.projectedUsedPercent = projectedUsedPercent
        self.projectedUsedLowerPercent = projectedUsedLowerPercent
        self.projectedUsedUpperPercent = projectedUsedUpperPercent
        self.runOutAt = runOutAt
    }
}

public struct MCPQuotaBucketDTO: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let shortLabel: String
    public let groupTitle: String?
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetAt: Date?
    public let windowSeconds: Int?
    public let forecast: MCPQuotaForecastDTO?

    public init(
        id: String,
        title: String,
        shortLabel: String,
        groupTitle: String?,
        usedPercent: Double,
        remainingPercent: Double,
        resetAt: Date?,
        windowSeconds: Int?,
        forecast: MCPQuotaForecastDTO?
    ) {
        self.id = id
        self.title = title
        self.shortLabel = shortLabel
        self.groupTitle = groupTitle
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
        self.forecast = forecast
    }
}

/// One account's live quota, named on the **quota axis**: L1 `company`,
/// L2 `subProvider`, L3 bucket group / bucket. See `AGENTS.md` § 7.1.
public struct MCPQuotaAccountDTO: Codable, Equatable, Sendable {
    public let accountId: String
    public let tool: String
    public let company: String
    public let subProvider: String
    public let plan: String?
    /// Masked through `EmailMasker` — never the raw mailbox.
    public let email: String?
    public let buckets: [MCPQuotaBucketDTO]
    public let queriedAt: Date?
    public let lastUpdated: Date?
    public let lastAttempted: Date?
    public let inFlight: Bool
    public let error: String?

    public init(
        accountId: String,
        tool: String,
        company: String,
        subProvider: String,
        plan: String?,
        email: String?,
        buckets: [MCPQuotaBucketDTO],
        queriedAt: Date?,
        lastUpdated: Date?,
        lastAttempted: Date?,
        inFlight: Bool,
        error: String?
    ) {
        self.accountId = accountId
        self.tool = tool
        self.company = company
        self.subProvider = subProvider
        self.plan = plan
        self.email = email
        self.buckets = buckets
        self.queriedAt = queriedAt
        self.lastUpdated = lastUpdated
        self.lastAttempted = lastAttempted
        self.inFlight = inFlight
        self.error = error
    }
}

public struct MCPQuotaSnapshotDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let accounts: [MCPQuotaAccountDTO]

    public init(generatedAt: Date, accounts: [MCPQuotaAccountDTO]) {
        self.generatedAt = generatedAt
        self.accounts = accounts
    }
}

extension MCPQuotaForecastDTO {
    public init(forecast: QuotaPaceForecast) {
        self.init(
            verdict: forecast.verdict.rawValue,
            confidence: forecast.confidence.rawValue,
            currentUsedPercent: forecast.currentUsedPercent,
            projectedUsedPercent: forecast.projectedUsedPercent,
            projectedUsedLowerPercent: forecast.projectedUsedLowerPercent,
            projectedUsedUpperPercent: forecast.projectedUsedUpperPercent,
            runOutAt: forecast.runOutAt
        )
    }
}

extension MCPQuotaBucketDTO {
    public init(bucket: QuotaBucket, forecast: QuotaPaceForecast?) {
        self.init(
            id: bucket.id,
            title: bucket.title,
            shortLabel: bucket.shortLabel,
            groupTitle: bucket.groupTitle,
            usedPercent: bucket.usedPercent,
            remainingPercent: bucket.remainingPercent,
            resetAt: bucket.resetAt,
            windowSeconds: bucket.rawWindowSeconds,
            forecast: forecast.map(MCPQuotaForecastDTO.init(forecast:))
        )
    }
}

extension MCPQuotaAccountDTO {
    /// Project one cached account, keyed by bucket id for the optional
    /// forecasts. This is the only place a quota reaches the wire, so it is
    /// also the only place the email has to be masked.
    public init(
        quota: AccountQuota,
        lastUpdated: Date?,
        lastAttempted: Date?,
        inFlight: Bool,
        error: QuotaError?,
        forecastsByBucketID: [String: QuotaPaceForecast] = [:]
    ) {
        self.init(
            accountId: quota.accountId,
            tool: quota.tool.rawValue,
            company: quota.tool.vendorName,
            subProvider: quota.tool.quotaSubProviderName(),
            plan: quota.plan,
            email: quota.email.map(EmailMasker.mask),
            buckets: quota.buckets.map {
                MCPQuotaBucketDTO(bucket: $0, forecast: forecastsByBucketID[$0.id])
            },
            queriedAt: quota.queriedAt,
            lastUpdated: lastUpdated,
            lastAttempted: lastAttempted,
            inFlight: inFlight,
            error: error?.userFacingMessage
        )
    }
}

// MARK: - quota.refresh

public struct MCPRefreshResultDTO: Codable, Equatable, Sendable {
    public let triggered: Bool
    /// `stale-only` or `forced` — which scheduler path ran.
    public let mode: String
    public let message: String

    public init(triggered: Bool, mode: String, message: String) {
        self.triggered = triggered
        self.mode = mode
        self.message = message
    }
}

// MARK: - usage.summary

public struct MCPUsageFiltersDTO: Codable, Equatable, Sendable {
    public let tools: [String]?
    public let harnesses: [String]?
    public let models: [String]?

    public init(tools: [String]?, harnesses: [String]?, models: [String]?) {
        self.tools = tools
        self.harnesses = harnesses
        self.models = models
    }
}

/// One `groupBy` row. `key` is the machine value to filter by next
/// (`claudeCode`, `claude`, a raw model id); `label` is what a human reads.
public struct MCPUsageGroupRowDTO: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    /// L1 company, present for harness and provider rows. Never for models.
    public let company: String?
    public let requests: Int
    public let totalTokens: Int64
    public let costMicros: Int64
    public let costUSD: Double

    public init(key: String, label: String, company: String?, requests: Int, totalTokens: Int64, costMicros: Int64) {
        self.key = key
        self.label = label
        self.company = company
        self.requests = requests
        self.totalTokens = totalTokens
        self.costMicros = costMicros
        self.costUSD = MCPMoney.usd(costMicros)
    }
}

public struct MCPUsageSummaryDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let range: MCPRangeDTO
    public let filters: MCPUsageFiltersDTO
    public let requests: Int
    /// Requests whose model had no usable price. They add `0` to the cost, so
    /// a non-zero count here means the total is a floor, not a total.
    public let unpricedRequests: Int
    public let costMicros: Int64?
    public let costUSD: Double?
    public let freshInputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    public let totalTokens: Int64
    public let cacheHitRate: Double?
    public let groupBy: String?
    public let rows: [MCPUsageGroupRowDTO]?

    public init(
        generatedAt: Date,
        range: MCPRangeDTO,
        filters: MCPUsageFiltersDTO,
        metrics: UsageSummaryMetrics,
        groupBy: String?,
        rows: [MCPUsageGroupRowDTO]?
    ) {
        self.generatedAt = generatedAt
        self.range = range
        self.filters = filters
        self.requests = metrics.requests
        self.unpricedRequests = metrics.unpricedRequests
        self.costMicros = metrics.costMicros
        self.costUSD = metrics.costMicros.map(MCPMoney.usd)
        self.freshInputTokens = metrics.freshInput
        self.outputTokens = metrics.output
        self.cacheReadTokens = metrics.cacheRead
        self.cacheCreationTokens = metrics.cacheCreation
        self.totalTokens = metrics.realTotalTokens
        self.cacheHitRate = metrics.cacheHitRate
        self.groupBy = groupBy
        self.rows = rows
    }
}

// MARK: - usage.trend

public struct MCPUsageTrendPointDTO: Codable, Equatable, Sendable {
    public let bucketStart: Date
    public let freshInputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    public let totalTokens: Int64
    public let costMicros: Int64
    public let costUSD: Double

    public init(point: UsageTrendPoint) {
        self.bucketStart = point.bucketStart
        self.freshInputTokens = point.freshInput
        self.outputTokens = point.output
        self.cacheReadTokens = point.cacheRead
        self.cacheCreationTokens = point.cacheCreation
        self.totalTokens = point.totalTokens
        self.costMicros = point.costMicros
        self.costUSD = MCPMoney.usd(point.costMicros)
    }
}

public struct MCPUsageTrendDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let range: MCPRangeDTO
    public let filters: MCPUsageFiltersDTO
    /// The bucket the ledger actually used. An hourly request over a range
    /// older than the detail window resolves down to `day`, so this can
    /// differ from what was asked for.
    public let bucket: String
    public let points: [MCPUsageTrendPointDTO]

    public init(
        generatedAt: Date,
        range: MCPRangeDTO,
        filters: MCPUsageFiltersDTO,
        series: UsageTrendSeries
    ) {
        self.generatedAt = generatedAt
        self.range = range
        self.filters = filters
        self.bucket = series.bucket.rawValue
        self.points = series.points.map(MCPUsageTrendPointDTO.init(point:))
    }
}

// MARK: - usage.requests

public struct MCPUsageRequestRowDTO: Codable, Equatable, Sendable {
    public let id: Int64
    public let date: Date
    /// Quota-axis tool the request is billed against.
    public let tool: String
    /// Usage-axis producer — the CLI or app that made the request.
    public let harness: String
    public let harnessName: String
    public let model: String
    public let freshInputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    public let totalTokens: Int64
    public let costMicros: Int64?
    public let costUSD: Double?
    public let serviceTier: String?
    public let sessionId: String?

    public init(row: UsageRequestRow) {
        self.id = row.id
        self.date = row.date
        self.tool = row.tool.rawValue
        self.harness = row.harness.rawValue
        self.harnessName = row.harness.displayName
        self.model = row.model
        self.freshInputTokens = row.freshInput
        self.outputTokens = row.output
        self.cacheReadTokens = row.cacheRead
        self.cacheCreationTokens = row.cacheCreation
        self.totalTokens = row.totalTokens
        self.costMicros = row.costMicros
        self.costUSD = row.costMicros.map(MCPMoney.usd)
        self.serviceTier = row.serviceTier
        self.sessionId = row.sessionId
    }
}

public struct MCPUsageRequestsDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let range: MCPRangeDTO
    public let filters: MCPUsageFiltersDTO
    public let rows: [MCPUsageRequestRowDTO]
    public let totalCount: Int?
    public let pageSize: Int
    /// Opaque. Pass it back as `cursor` for the next page; absent means the
    /// sequence ended.
    public let nextCursor: String?

    public init(
        generatedAt: Date,
        range: MCPRangeDTO,
        filters: MCPUsageFiltersDTO,
        page: UsageRequestPage
    ) {
        self.generatedAt = generatedAt
        self.range = range
        self.filters = filters
        self.rows = page.rows.map(MCPUsageRequestRowDTO.init(row:))
        self.totalCount = page.totalCount
        self.pageSize = page.pageSize
        self.nextCursor = page.nextCursor.map(MCPCursorCoding.encode)
    }
}

/// The ledger's keyset cursor as one opaque string.
///
/// Agents copy this value between calls; making its two integers visible
/// would invite hand-editing, and a hand-edited cursor silently skips or
/// repeats rows rather than failing.
public enum MCPCursorCoding {
    public static func encode(_ cursor: UsageRequestCursor) -> String {
        Data("\(cursor.ts).\(cursor.id)".utf8).base64EncodedString()
    }

    public static func decode(_ raw: String) -> UsageRequestCursor? {
        guard let data = Data(base64Encoded: raw) else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: ".")
        guard parts.count == 2,
              let ts = Int64(parts[0]),
              let id = Int64(parts[1])
        else { return nil }
        return UsageRequestCursor(ts: ts, id: id)
    }
}

// MARK: - cost.snapshot

public struct MCPCostWindowDTO: Codable, Equatable, Sendable {
    public let costUSD: Double
    public let tokens: Int
    public let requests: Int

    public init(costUSD: Double, tokens: Int, requests: Int) {
        self.costUSD = costUSD
        self.tokens = tokens
        self.requests = requests
    }
}

public struct MCPCostToolSnapshotDTO: Codable, Equatable, Sendable {
    public let tool: String
    public let company: String
    public let subProvider: String
    public let today: MCPCostWindowDTO
    public let last7d: MCPCostWindowDTO
    public let last30d: MCPCostWindowDTO
    public let allTime: MCPCostWindowDTO
    public let jsonlFilesFound: Int
    public let updatedAt: Date

    public init(snapshot: CostSnapshot) {
        self.tool = snapshot.tool.rawValue
        self.company = snapshot.tool.vendorName
        self.subProvider = snapshot.tool.quotaSubProviderName()
        self.today = MCPCostWindowDTO(
            costUSD: snapshot.todayCostUSD,
            tokens: snapshot.todayTokens,
            requests: snapshot.todayRequests
        )
        self.last7d = MCPCostWindowDTO(
            costUSD: snapshot.last7DaysCostUSD,
            tokens: snapshot.last7DaysTokens,
            requests: snapshot.last7DaysRequests
        )
        self.last30d = MCPCostWindowDTO(
            costUSD: snapshot.last30DaysCostUSD,
            tokens: snapshot.last30DaysTokens,
            requests: snapshot.last30DaysRequests
        )
        self.allTime = MCPCostWindowDTO(
            costUSD: snapshot.allTimeCostUSD,
            tokens: snapshot.allTimeTokens,
            requests: snapshot.allTimeRequests
        )
        self.jsonlFilesFound = snapshot.jsonlFilesFound
        self.updatedAt = snapshot.updatedAt
    }
}

public struct MCPCostSnapshotsDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    /// True when Settings → Cost Data → Privacy mode is on. Every window is
    /// then empty by design, not because nothing was spent.
    public let privacyModeEnabled: Bool
    public let tools: [MCPCostToolSnapshotDTO]

    public init(generatedAt: Date, privacyModeEnabled: Bool, tools: [MCPCostToolSnapshotDTO]) {
        self.generatedAt = generatedAt
        self.privacyModeEnabled = privacyModeEnabled
        self.tools = tools
    }
}

// MARK: - cost.history

public struct MCPCostHistoryPointDTO: Codable, Equatable, Sendable {
    public let date: Date
    public let costUSD: Double
    public let totalTokens: Int

    public init(point: DailyCostPoint) {
        self.date = point.date
        self.costUSD = point.costUSD
        self.totalTokens = point.totalTokens
    }
}

public struct MCPCostHistoryDTO: Codable, Equatable, Sendable {
    public let tool: String
    public let timeframe: String
    public let updatedAt: Date
    public let days: [MCPCostHistoryPointDTO]

    public init(timeframe: String, history: CostHistory) {
        self.tool = history.tool.rawValue
        self.timeframe = timeframe
        self.updatedAt = history.updatedAt
        self.days = history.days.map(MCPCostHistoryPointDTO.init(point:))
    }
}

// MARK: - sessions.*

public struct MCPSessionSummaryDTO: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    /// The on-disk store the session came from.
    public let provider: String
    /// Usage-axis label — what the Sessions page shows on the row.
    public let harness: String
    public let harnessName: String
    public let title: String?
    public let summary: String?
    public let projectDir: String?
    /// Raw vendor model id as the log spelled it. `nil` when the log never
    /// recorded one — never inferred from the provider's usual model.
    public let model: String?
    public let createdAt: Date?
    public let lastActiveAt: Date?
    public let messageCount: Int?
    public let sizeBytes: Int64
    public let sourcePath: String
    /// Search only: the matched excerpt, with `<b>` markers around the hit.
    public let snippet: String?
    public let matchedSeq: Int?

    public init(summary: SessionSummary, snippet: String? = nil, matchedSeq: Int? = nil) {
        self.id = summary.id
        self.sessionId = summary.sessionID
        self.provider = summary.provider.rawValue
        self.harness = summary.effectiveHarness.rawValue
        self.harnessName = summary.effectiveHarness.displayName
        self.title = summary.title
        self.summary = summary.summary
        self.projectDir = summary.projectDir
        self.model = summary.model
        self.createdAt = summary.createdAt
        self.lastActiveAt = summary.lastActiveAt
        self.messageCount = summary.hasKnownMessageCount ? summary.messageCount : nil
        self.sizeBytes = summary.sizeBytes
        self.sourcePath = summary.sourcePath
        self.snippet = snippet
        self.matchedSeq = matchedSeq
    }
}

public struct MCPSessionListDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let sessions: [MCPSessionSummaryDTO]
    /// Total matching the filter, for `sessions.list`. Search does not count
    /// past its own limit, so it is absent there.
    public let totalCount: Int?
    public let offset: Int?
    public let limit: Int

    public init(
        generatedAt: Date,
        sessions: [MCPSessionSummaryDTO],
        totalCount: Int?,
        offset: Int?,
        limit: Int
    ) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.totalCount = totalCount
        self.offset = offset
        self.limit = limit
    }
}

// MARK: - status.get

public struct MCPServiceStatusRowDTO: Codable, Equatable, Sendable {
    public let tool: String
    public let company: String
    /// `none` / `minor` / `major` / `critical` / `maintenance`.
    public let indicator: String
    public let description: String
    public let updatedAt: Date?
    public let isRefreshing: Bool
    public let error: String?

    public init(
        tool: String,
        company: String,
        indicator: String,
        description: String,
        updatedAt: Date?,
        isRefreshing: Bool,
        error: String?
    ) {
        self.tool = tool
        self.company = company
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
        self.isRefreshing = isRefreshing
        self.error = error
    }
}

public struct MCPServiceStatusDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let lastFetched: Date?
    public let companies: [MCPServiceStatusRowDTO]

    public init(generatedAt: Date, lastFetched: Date?, companies: [MCPServiceStatusRowDTO]) {
        self.generatedAt = generatedAt
        self.lastFetched = lastFetched
        self.companies = companies
    }
}

// MARK: - pricing.effective

public struct MCPPricingRowDTO: Codable, Equatable, Sendable {
    public let provider: String
    public let company: String
    public let subProvider: String
    public let model: String
    public let displayLabel: String?
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?
    public let thresholdTokens: Int?

    public init(row: EffectiveModelPricingRow) {
        self.provider = row.provider.rawValue
        self.company = row.companyName
        self.subProvider = row.subProviderName
        self.model = row.model
        self.displayLabel = row.displayLabel
        self.inputPerMillion = row.inputPerMillion
        self.outputPerMillion = row.outputPerMillion
        self.cacheReadPerMillion = row.cacheReadPerMillion
        self.cacheWritePerMillion = row.cacheWritePerMillion
        self.thresholdTokens = row.thresholdTokens
    }
}

public struct MCPPricingDTO: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let unit: String
    public let rows: [MCPPricingRowDTO]

    public init(generatedAt: Date, rows: [MCPPricingRowDTO]) {
        self.generatedAt = generatedAt
        self.unit = "USD per 1M tokens"
        self.rows = rows
    }
}

// MARK: - Server identity

public struct MCPServerInfo: Codable, Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
