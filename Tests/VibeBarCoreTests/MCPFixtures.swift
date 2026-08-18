import Foundation
@testable import VibeBarCore

/// A deterministic `MCPDataSource`.
///
/// Everything is a fixed value: no home directory, no ledger, no network, no
/// clock. That is what lets the tool tests assert on exact JSON — the point of
/// the `MCPDataSource` seam is that the whole MCP surface can be exercised
/// without a running app.
final class FakeMCPDataSource: MCPDataSource, @unchecked Sendable {
    /// 2026-01-01T00:00:00Z.
    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    // Recorded calls, so a test can assert what the server passed down.
    private(set) var lastUsageFilter: UsageQueryFilter?
    private(set) var lastTrendBucket: UsageTrendBucket?
    private(set) var lastRequestCursor: UsageRequestCursor?
    private(set) var lastRequestPageSize: Int?
    private(set) var lastSessionQuery: String?
    private(set) var lastSessionLimit: Int?

    /// `refreshQuota` is the one method a test drives from two tasks at once,
    /// so its recording is the one that needs a lock.
    private let refreshLock = NSLock()
    private var recordedRefreshCalls: [(tools: [ToolType]?, force: Bool)] = []
    var refreshCalls: [(tools: [ToolType]?, force: Bool)] {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        return recordedRefreshCalls
    }

    /// Flip to make every ledger-backed tool report the "no ledger" failure.
    var ledgerAvailable = true
    /// What `refreshQuota` claims happened.
    var refreshTriggered = true
    /// How long `refreshQuota` stays inside the data source. Non-nil keeps two
    /// concurrent calls overlapping long enough to expose a throttle that
    /// admits before it marks.
    var refreshDuration: Duration?

    // MARK: Identity

    func serverInfo() async -> MCPServerInfo {
        MCPServerInfo(name: "vibebar", version: "9.9.9 (42)")
    }

    // MARK: Quota

    static let claudeQuota = AccountQuota(
        accountId: "anthropic-primary",
        tool: .claude,
        buckets: [
            QuotaBucket(
                id: "five_hour",
                title: "All Models",
                shortLabel: "5h",
                usedPercent: 42.5,
                resetAt: epoch.addingTimeInterval(3_600),
                rawWindowSeconds: 18_000,
                groupTitle: "All Models"
            ),
            QuotaBucket(
                id: "weekly",
                title: "Weekly",
                shortLabel: "wk",
                usedPercent: 12,
                resetAt: epoch.addingTimeInterval(86_400),
                rawWindowSeconds: 604_800
            )
        ],
        plan: "Max",
        email: "someone@example.com",
        queriedAt: epoch
    )

    static let codexQuota = AccountQuota(
        accountId: "openai-primary",
        tool: .codex,
        buckets: [
            QuotaBucket(
                id: "five_hour",
                title: "All Models",
                shortLabel: "5h",
                usedPercent: 7,
                resetAt: epoch.addingTimeInterval(1_800),
                rawWindowSeconds: 18_000
            )
        ],
        plan: "Pro",
        email: nil,
        queriedAt: epoch
    )

    func quotaAccounts(tools: [ToolType]?, includeForecast: Bool) async throws -> [MCPQuotaAccountDTO] {
        let wanted = tools.map(Set.init)
        return [Self.claudeQuota, Self.codexQuota]
            .filter { wanted?.contains($0.tool) ?? true }
            .map { quota in
                MCPQuotaAccountDTO(
                    quota: quota,
                    lastUpdated: Self.epoch,
                    lastAttempted: Self.epoch.addingTimeInterval(60),
                    inFlight: false,
                    error: nil,
                    forecastsByBucketID: [:]
                )
            }
    }

    func refreshQuota(tools: [ToolType]?, force: Bool) async throws -> MCPRefreshResultDTO {
        refreshLock.lock()
        recordedRefreshCalls.append((tools, force))
        let duration = refreshDuration
        refreshLock.unlock()
        if let duration { try? await Task.sleep(for: duration) }
        return MCPRefreshResultDTO(
            triggered: refreshTriggered,
            mode: force ? "forced" : "stale-only",
            message: force ? "Refreshing everything." : "Refreshing what was stale."
        )
    }

    // MARK: Usage

    private func requireLedger() throws {
        guard ledgerAvailable else { throw MCPToolFailure("The usage ledger is unavailable.") }
    }

    func usageSummary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics {
        try requireLedger()
        lastUsageFilter = filter
        return UsageSummaryMetrics(
            requests: 120,
            unpricedRequests: 3,
            costMicros: 4_560_000,
            freshInput: 1_000,
            output: 2_000,
            cacheRead: 3_000,
            cacheCreation: 4_000
        )
    }

    func usageGroupRows(
        _ filter: UsageQueryFilter,
        groupBy: MCPUsageGrouping
    ) async throws -> [MCPUsageGroupRowDTO] {
        try requireLedger()
        lastUsageFilter = filter
        switch groupBy {
        case .harness:
            return [
                MCPUsageGroupRowDTO(
                    key: Harness.claudeCode.rawValue,
                    label: Harness.claudeCode.displayName,
                    company: Harness.claudeCode.companyName,
                    requests: 90,
                    totalTokens: 9_000,
                    costMicros: 3_000_000
                )
            ]
        case .provider:
            return [
                MCPUsageGroupRowDTO(
                    key: ToolType.claude.rawValue,
                    label: ToolType.claude.vendorName,
                    company: ToolType.claude.vendorName,
                    requests: 90,
                    totalTokens: 9_000,
                    costMicros: 3_000_000
                )
            ]
        case .model:
            return [
                MCPUsageGroupRowDTO(
                    key: "claude-opus-4-7",
                    label: "claude-opus-4-7",
                    company: nil,
                    requests: 90,
                    totalTokens: 9_000,
                    costMicros: 3_000_000
                )
            ]
        }
    }

    func usageTrend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket?) async throws -> UsageTrendSeries {
        try requireLedger()
        lastUsageFilter = filter
        lastTrendBucket = bucket
        return UsageTrendSeries(
            bucket: bucket ?? .day,
            points: [
                UsageTrendPoint(
                    bucketStart: Self.epoch,
                    freshInput: 10,
                    output: 20,
                    cacheRead: 30,
                    cacheCreation: 40,
                    costMicros: 1_500_000
                )
            ]
        )
    }

    func usageRequests(
        _ filter: UsageQueryFilter,
        after cursor: UsageRequestCursor?,
        pageSize: Int
    ) async throws -> UsageRequestPage {
        try requireLedger()
        lastUsageFilter = filter
        lastRequestCursor = cursor
        lastRequestPageSize = pageSize
        return UsageRequestPage(
            rows: [
                UsageRequestRow(
                    id: 7,
                    date: Self.epoch,
                    tool: .claude,
                    harness: .claudeCode,
                    model: "claude-opus-4-7",
                    freshInput: 10,
                    output: 20,
                    cacheRead: 30,
                    cacheCreation: 40,
                    costMicros: 250_000,
                    serviceTier: "standard",
                    sessionId: "session-1",
                    sourceKey: "source-key"
                )
            ],
            totalCount: 1,
            pageSize: pageSize,
            cursor: cursor,
            nextCursor: UsageRequestCursor(ts: 1_767_225_600, id: 7)
        )
    }

    // MARK: Cost

    func costSnapshots(tools: [ToolType]?) async throws -> MCPCostSnapshotsDTO {
        let wanted = tools.map(Set.init)
        let rows = [ToolType.claude, ToolType.codex]
            .filter { wanted?.contains($0) ?? true }
            .map { tool in
                MCPCostToolSnapshotDTO(snapshot: Self.costSnapshot(for: tool))
            }
        return MCPCostSnapshotsDTO(
            generatedAt: Self.epoch,
            privacyModeEnabled: false,
            tools: rows
        )
    }

    static func costSnapshot(for tool: ToolType) -> CostSnapshot {
        CostSnapshot(
            tool: tool,
            todayCostUSD: 1.25,
            last7DaysCostUSD: 8.5,
            last30DaysCostUSD: 30.75,
            allTimeCostUSD: 120.5,
            todayTokens: 100,
            last7DaysTokens: 700,
            last30DaysTokens: 3_000,
            allTimeTokens: 12_000,
            todayRequests: 4,
            last7DaysRequests: 28,
            last30DaysRequests: 120,
            allTimeRequests: 480,
            dailyHistory: [],
            heatmap: UsageHeatmap(tool: tool, cells: [], totalTokens: 0),
            modelBreakdowns: [],
            jsonlFilesFound: 3,
            updatedAt: epoch
        )
    }

    func costHistory(tool: ToolType, timeframe: MCPCostHistoryTimeframe) async throws -> CostHistory {
        CostHistory(
            tool: tool,
            days: [DailyCostPoint(date: Self.epoch, costUSD: 1.25, totalTokens: 100)],
            updatedAt: Self.epoch
        )
    }

    // MARK: Sessions

    static let sessionSummary = SessionSummary(
        provider: .claude,
        sessionID: "abc-123",
        harness: .claudeCode,
        model: "claude-opus-4-7",
        title: "Refactor the socket server",
        summary: nil,
        projectDir: "/Users/example/Code/demo",
        createdAt: epoch,
        lastActiveAt: epoch.addingTimeInterval(600),
        sourcePath: "/Users/example/.claude/projects/demo/abc-123.jsonl",
        sizeBytes: 4_096,
        messageCount: 12
    )

    func searchSessions(
        query: String,
        providers: [SessionProvider]?,
        harnesses: [Harness]?,
        limit: Int
    ) async throws -> [SessionSearchHit] {
        lastSessionQuery = query
        lastSessionLimit = limit
        return [
            SessionSearchHit(
                summary: Self.sessionSummary,
                snippet: "the <b>socket</b> server",
                matchedSeq: 4
            )
        ]
    }

    func listSessions(
        providers: [SessionProvider]?,
        harnesses: [Harness]?,
        since: Date?,
        offset: Int,
        limit: Int
    ) async throws -> SessionSummaryPage {
        SessionSummaryPage(
            summaries: [Self.sessionSummary],
            totalCount: 1,
            offset: offset,
            limit: limit
        )
    }

    // MARK: Status and pricing

    func serviceStatus(tools: [ToolType]?) async throws -> MCPServiceStatusDTO {
        let wanted = tools.map { Set($0.compactMap { $0.coreProviderRepresentative }) }
        let rows = ToolType.combinedStatusPageProviders
            .filter { wanted?.contains($0) ?? true }
            .map { tool in
                MCPServiceStatusRowDTO(
                    tool: tool.rawValue,
                    company: tool.vendorName,
                    indicator: "none",
                    description: "All Systems Operational",
                    updatedAt: Self.epoch,
                    isRefreshing: false,
                    error: nil
                )
            }
        return MCPServiceStatusDTO(generatedAt: Self.epoch, lastFetched: Self.epoch, companies: rows)
    }

    func effectivePricing() async throws -> [EffectiveModelPricingRow] {
        [
            EffectiveModelPricingRow(
                provider: .claude,
                model: "claude-opus-4-7",
                inputPerMillion: 15,
                outputPerMillion: 75,
                cacheReadPerMillion: 1.5,
                cacheWritePerMillion: 18.75
            ),
            EffectiveModelPricingRow(
                provider: .codex,
                model: "gpt-5-codex",
                inputPerMillion: 1.25,
                outputPerMillion: 10
            )
        ]
    }
}

// MARK: - Helpers shared by the MCP tests

enum MCPTestSupport {
    /// Build one framed request line.
    static func line(id: Int?, method: String, params: MCPJSON? = nil) -> Data {
        var fields: [String: MCPJSON] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]
        if let id { fields["id"] = .int(Int64(id)) }
        if let params { fields["params"] = params }
        return (try? MCPJSON.object(fields).serialized()) ?? Data()
    }

    static func call(id: Int, tool: String, arguments: MCPJSON = .object([:])) -> Data {
        line(
            id: id,
            method: "tools/call",
            params: .object(["name": .string(tool), "arguments": arguments])
        )
    }

    static func decode(_ data: Data?) throws -> MCPJSON {
        let data = try XCTUnwrapData(data)
        return try JSONDecoder().decode(MCPJSON.self, from: data)
    }

    /// The tool result's `structuredContent`, or a readable failure.
    static func structured(_ response: MCPJSON) throws -> MCPJSON {
        guard let structured = response["result"]?["structuredContent"] else {
            throw MCPTestError("No structuredContent in \(response)")
        }
        return structured
    }

    static func isError(_ response: MCPJSON) -> Bool {
        response["result"]?["isError"]?.boolValue ?? false
    }

    static func errorText(_ response: MCPJSON) -> String? {
        response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    private static func XCTUnwrapData(_ data: Data?) throws -> Data {
        guard let data else { throw MCPTestError("Expected a response, got none.") }
        return data
    }
}

struct MCPTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
