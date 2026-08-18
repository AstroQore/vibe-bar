import Foundation

// MARK: - Vocabulary

public enum MCPUsageGrouping: String, Sendable, CaseIterable {
    case harness
    case provider
    case model
}

/// The three windows `cost.history` offers, mapped onto `CostTimeframe`.
/// Deliberately narrower than `CostTimeframe`: "today" and "yesterday" are
/// one- and two-point series that `cost.snapshot` already answers better.
public enum MCPCostHistoryTimeframe: String, Sendable, CaseIterable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all

    public var timeframe: CostTimeframe {
        switch self {
        case .sevenDays:  return .week
        case .thirtyDays: return .month
        case .all:        return .all
        }
    }
}

// MARK: - Data source

/// Everything the MCP surface needs from the running app.
///
/// Core owns the protocol shape and every projection; the App supplies one
/// implementation over `AppEnvironment`. That split is what lets the whole
/// tool surface be tested against a fixture without a menu bar, a home
/// directory, or a network.
public protocol MCPDataSource: AnyObject, Sendable {
    func serverInfo() async -> MCPServerInfo

    func quotaAccounts(tools: [ToolType]?, includeForecast: Bool) async throws -> [MCPQuotaAccountDTO]
    func refreshQuota(tools: [ToolType]?, force: Bool) async throws -> MCPRefreshResultDTO

    func usageSummary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics
    func usageGroupRows(_ filter: UsageQueryFilter, groupBy: MCPUsageGrouping) async throws -> [MCPUsageGroupRowDTO]
    func usageTrend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket?) async throws -> UsageTrendSeries
    func usageRequests(
        _ filter: UsageQueryFilter,
        after cursor: UsageRequestCursor?,
        pageSize: Int
    ) async throws -> UsageRequestPage

    func costSnapshots(tools: [ToolType]?) async throws -> MCPCostSnapshotsDTO
    func costHistory(tool: ToolType, timeframe: MCPCostHistoryTimeframe) async throws -> CostHistory

    func searchSessions(
        query: String,
        providers: [SessionProvider]?,
        harnesses: [Harness]?,
        limit: Int
    ) async throws -> [SessionSearchHit]
    func listSessions(
        providers: [SessionProvider]?,
        harnesses: [Harness]?,
        since: Date?,
        offset: Int,
        limit: Int
    ) async throws -> SessionSummaryPage

    func serviceStatus(tools: [ToolType]?) async throws -> MCPServiceStatusDTO
    func effectivePricing() async throws -> [EffectiveModelPricingRow]

    /// The one tool that writes. Implementations gate it on
    /// `AppSettings.mcpServer.allowSkillInstall` and route it through
    /// `SkillsService`, so the write allowlist in `AGENTS.md` § 7 holds for
    /// agents exactly as it does for the Workbench.
    func installSkill(
        source: SkillInstallSource,
        apps: [SkillAppTarget],
        method: SkillSyncMethod
    ) async throws -> MCPSkillInstallDTO
}

// MARK: - Server

/// Dispatches one JSON-RPC message at a time against an `MCPDataSource`.
///
/// Stateless apart from the forced-refresh throttle, so a second client
/// connecting does not need a second server — `MCPSocketServer` hands every
/// connection to the same instance.
public final class MCPServer: @unchecked Sendable {
    /// The MCP revision this server implements. Clients that ask for a
    /// different one still get this; the spec's rule is that the server
    /// answers with what it actually speaks and the client decides.
    public static let protocolVersion = "2025-06-18"

    /// Floor between two *forced* refreshes. Stale-only refreshes are already
    /// self-limiting — they no-op when nothing is stale — but `force: true`
    /// hits every provider's API, and an agent in a retry loop would otherwise
    /// turn the user's own tooling into a rate-limit problem.
    public static let forcedRefreshMinimumInterval: TimeInterval = 20

    private let dataSource: any MCPDataSource
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastForcedRefreshAt: Date?

    public init(dataSource: any MCPDataSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dataSource = dataSource
        self.now = now
    }

    // MARK: Entry points

    /// Handle one framed line. Returns the framed reply, or `nil` for a
    /// notification (which must produce no output at all).
    public func handle(line: Data) async -> Data? {
        let request: MCPRequest
        do {
            request = try MCPRequest.decode(line: line)
        } catch let error as MCPRPCError {
            return MCPResponse(id: .null, error: error).framed()
        } catch {
            return MCPResponse(id: .null, error: .parseError()).framed()
        }
        return await respond(to: request)?.framed()
    }

    public func respond(to request: MCPRequest) async -> MCPResponse? {
        guard let id = request.id else {
            // Notifications are fire-and-forget. `notifications/initialized`
            // is the only one that matters today; unknown ones are ignored
            // rather than answered, because answering a notification is
            // itself a protocol violation.
            return nil
        }
        do {
            return MCPResponse(id: id, result: try await result(for: request))
        } catch let error as MCPRPCError {
            return MCPResponse(id: id, error: error)
        } catch {
            return MCPResponse(id: id, error: .internalError(SafeLog.sanitize(error.localizedDescription)))
        }
    }

    private func result(for request: MCPRequest) async throws -> MCPJSON {
        switch request.method {
        case "initialize":
            return await initializeResult()
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(MCPToolCatalog.all.map(\.json))])
        case "resources/list":
            return .object(["resources": .array(MCPResourceCatalog.all.map(\.json))])
        case "resources/templates/list":
            return .object(["resourceTemplates": .array([])])
        case "prompts/list":
            return .object(["prompts": .array([])])
        case "resources/read":
            return try readResource(request.params)
        case "tools/call":
            return try await callTool(request.params)
        default:
            throw MCPRPCError.methodNotFound(request.method)
        }
    }

    private func initializeResult() async -> MCPJSON {
        let info = await dataSource.serverInfo()
        return .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object(["listChanged": .bool(false), "subscribe": .bool(false)])
            ]),
            "serverInfo": .object([
                "name": .string(info.name),
                "version": .string(info.version)
            ]),
            "instructions": .string(
                "Vibe Bar reports this Mac's AI subscription quota, token usage, spend and local "
                    + "agent sessions. Read the vibebar://naming-spec resource before comparing "
                    + "providers: quota answers use company / SubProvider names, usage answers use "
                    + "harness names, and the two must never be mixed in one list."
            )
        ])
    }

    // MARK: Resources

    private func readResource(_ params: MCPJSON?) throws -> MCPJSON {
        guard let uri = params?["uri"]?.stringValue, !uri.isEmpty else {
            throw MCPRPCError.invalidParams("resources/read needs a string 'uri'.")
        }
        guard let contents = MCPResourceCatalog.contents(of: uri) else {
            throw MCPRPCError.invalidParams("Unknown resource '\(uri)'.")
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string(contents.mimeType),
                    "text": .string(contents.text)
                ])
            ])
        ])
    }

    // MARK: Tools

    private func callTool(_ params: MCPJSON?) async throws -> MCPJSON {
        guard let name = params?["name"]?.stringValue, !name.isEmpty else {
            throw MCPRPCError.invalidParams("tools/call needs a string 'name'.")
        }
        guard let tool = MCPToolCatalog.tool(named: name) else {
            throw MCPRPCError.invalidParams("Unknown tool '\(name)'.")
        }
        let arguments = try MCPArguments(tool: tool, raw: params?["arguments"])
        do {
            return try Self.successResult(try await invoke(tool: name, arguments: arguments))
        } catch let failure as MCPToolFailure {
            return Self.errorResult(failure.message)
        } catch let error as MCPRPCError {
            // Argument problems stay JSON-RPC errors: the client, not the
            // model, is the one that can fix a malformed call.
            throw error
        } catch {
            return Self.errorResult(SafeLog.sanitize(error.localizedDescription))
        }
    }

    private func invoke(tool: String, arguments: MCPArguments) async throws -> any Encodable {
        switch tool {
        case "quota.get":         return try await quotaGet(arguments)
        case "quota.refresh":     return try await quotaRefresh(arguments)
        case "usage.summary":     return try await usageSummary(arguments)
        case "usage.trend":       return try await usageTrend(arguments)
        case "usage.requests":    return try await usageRequests(arguments)
        case "cost.snapshot":     return try await costSnapshot(arguments)
        case "cost.history":      return try await costHistory(arguments)
        case "sessions.search":   return try await sessionsSearch(arguments)
        case "sessions.list":     return try await sessionsList(arguments)
        case "status.get":        return try await statusGet(arguments)
        case "pricing.effective": return try await pricingEffective(arguments)
        case "skills.install":    return try await skillsInstall(arguments)
        default:                  throw MCPRPCError.invalidParams("Unknown tool '\(tool)'.")
        }
    }

    // MARK: Tool implementations

    private func quotaGet(_ arguments: MCPArguments) async throws -> MCPQuotaSnapshotDTO {
        let tools = try arguments.optionalEnumList("tools", ToolType.self)
        let includeForecast = try arguments.optionalBool("includeForecast") ?? false
        let accounts = try await dataSource.quotaAccounts(tools: tools, includeForecast: includeForecast)
        return MCPQuotaSnapshotDTO(generatedAt: now(), accounts: accounts)
    }

    private func quotaRefresh(_ arguments: MCPArguments) async throws -> MCPRefreshResultDTO {
        let tools = try arguments.optionalEnumList("tools", ToolType.self)
        let force = try arguments.optionalBool("force") ?? false

        var reservation: ForcedRefreshReservation?
        if force {
            switch admitForcedRefresh() {
            case let .throttled(wait):
                return MCPRefreshResultDTO(
                    triggered: false,
                    mode: "forced",
                    message: "A forced refresh ran less than "
                        + "\(Int(Self.forcedRefreshMinimumInterval))s ago. Try again in \(wait)s, "
                        + "or call quota.get — the cached numbers are almost certainly current."
                )
            case let .admitted(slot):
                reservation = slot
            }
        }

        do {
            let result = try await dataSource.refreshQuota(tools: tools, force: force)
            // The app declined (the toggle is off, or it is shutting down):
            // give the window back rather than charging the caller for a
            // refresh that never happened.
            if let reservation, !result.triggered { release(reservation) }
            return result
        } catch {
            if let reservation { release(reservation) }
            throw error
        }
    }

    private func usageSummary(_ arguments: MCPArguments) async throws -> MCPUsageSummaryDTO {
        let filter = try arguments.usageFilter(now: now())
        let grouping = try arguments.optionalEnum("groupBy", MCPUsageGrouping.self)
        let metrics = try await dataSource.usageSummary(filter)
        let rows = grouping == nil
            ? nil
            : try await dataSource.usageGroupRows(filter, groupBy: grouping!)
        return MCPUsageSummaryDTO(
            generatedAt: now(),
            range: MCPRangeDTO(from: filter.range.start, to: filter.range.end),
            filters: filter.mcpFilters,
            metrics: metrics,
            groupBy: grouping?.rawValue,
            rows: rows
        )
    }

    private func usageTrend(_ arguments: MCPArguments) async throws -> MCPUsageTrendDTO {
        let filter = try arguments.usageFilter(now: now())
        let bucket = try arguments.optionalEnum("bucket", UsageTrendBucket.self)
        let series = try await dataSource.usageTrend(filter, bucket: bucket)
        return MCPUsageTrendDTO(
            generatedAt: now(),
            range: MCPRangeDTO(from: filter.range.start, to: filter.range.end),
            filters: filter.mcpFilters,
            series: series
        )
    }

    private func usageRequests(_ arguments: MCPArguments) async throws -> MCPUsageRequestsDTO {
        let filter = try arguments.usageFilter(now: now())
        let pageSize = try arguments.optionalInt("pageSize", minimum: 1, maximum: 200) ?? 50
        var cursor: UsageRequestCursor?
        if let raw = try arguments.optionalString("cursor") {
            guard let decoded = MCPCursorCoding.decode(raw) else {
                throw MCPRPCError.invalidParams(
                    "'cursor' is not a cursor this server issued. Pass back a 'nextCursor' verbatim, or omit it."
                )
            }
            cursor = decoded
        }
        let page = try await dataSource.usageRequests(filter, after: cursor, pageSize: pageSize)
        return MCPUsageRequestsDTO(
            generatedAt: now(),
            range: MCPRangeDTO(from: filter.range.start, to: filter.range.end),
            filters: filter.mcpFilters,
            page: page
        )
    }

    private func costSnapshot(_ arguments: MCPArguments) async throws -> MCPCostSnapshotsDTO {
        let tools = try arguments.optionalEnumList("tools", ToolType.self)
        return try await dataSource.costSnapshots(tools: tools)
    }

    private func costHistory(_ arguments: MCPArguments) async throws -> MCPCostHistoryDTO {
        let tool = try arguments.requiredEnum("tool", ToolType.self)
        let timeframe = try arguments.optionalEnum("timeframe", MCPCostHistoryTimeframe.self) ?? .thirtyDays
        let history = try await dataSource.costHistory(tool: tool, timeframe: timeframe)
        return MCPCostHistoryDTO(timeframe: timeframe.rawValue, history: history)
    }

    private func sessionsSearch(_ arguments: MCPArguments) async throws -> MCPSessionListDTO {
        let query = try arguments.requiredString("query")
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPRPCError.invalidParams("'query' must not be blank.")
        }
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 50) ?? 20
        let hits = try await dataSource.searchSessions(
            query: query,
            providers: try arguments.optionalEnumList("providers", SessionProvider.self),
            harnesses: try arguments.optionalEnumList("harnesses", Harness.self),
            limit: limit
        )
        return MCPSessionListDTO(
            generatedAt: now(),
            sessions: hits.map {
                MCPSessionSummaryDTO(summary: $0.summary, snippet: $0.snippet, matchedSeq: $0.matchedSeq)
            },
            totalCount: nil,
            offset: nil,
            limit: limit
        )
    }

    private func sessionsList(_ arguments: MCPArguments) async throws -> MCPSessionListDTO {
        let offset = try arguments.optionalInt("offset", minimum: 0, maximum: 1_000_000) ?? 0
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 100) ?? 50
        let page = try await dataSource.listSessions(
            providers: try arguments.optionalEnumList("providers", SessionProvider.self),
            harnesses: try arguments.optionalEnumList("harnesses", Harness.self),
            since: try arguments.optionalDate("since"),
            offset: offset,
            limit: limit
        )
        return MCPSessionListDTO(
            generatedAt: now(),
            sessions: page.summaries.map { MCPSessionSummaryDTO(summary: $0) },
            totalCount: page.totalCount,
            offset: page.offset,
            limit: page.limit
        )
    }

    private func statusGet(_ arguments: MCPArguments) async throws -> MCPServiceStatusDTO {
        try await dataSource.serviceStatus(tools: try arguments.optionalEnumList("tools", ToolType.self))
    }

    private func pricingEffective(_ arguments: MCPArguments) async throws -> MCPPricingDTO {
        let family = try arguments.optionalEnum("provider", PricingProviderFamily.self)
        let needle = try arguments.optionalString("model")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rows = try await dataSource.effectivePricing()
            .filter { row in family == nil || row.provider == family }
            .filter { row in
                guard let needle else { return true }
                return row.model.lowercased().contains(needle)
            }
        return MCPPricingDTO(generatedAt: now(), rows: rows.map(MCPPricingRowDTO.init(row:)))
    }

    /// The source string is parsed here, before the app is involved: a typo or
    /// an off-allowlist host is the caller's to fix, and saying so as
    /// `invalidParams` keeps it out of the Skills manager entirely.
    private func skillsInstall(_ arguments: MCPArguments) async throws -> MCPSkillInstallDTO {
        let raw = try arguments.requiredString("source")
        let source: SkillInstallSource
        do {
            source = try SkillInstallSource(raw)
        } catch {
            throw MCPRPCError.invalidParams("skills.install: \(error.localizedDescription)")
        }
        let apps = try arguments.optionalEnumList("apps", SkillAppTarget.self) ?? []
        var method = SkillSyncMethod.auto
        if let requested = try arguments.optionalEnum("method", SkillSyncMethod.self) {
            guard requested != .auto else {
                throw MCPRPCError.invalidParams(
                    "skills.install: 'method' must be 'symlink' or 'copy'; omit it for the default."
                )
            }
            method = requested
        }
        return try await dataSource.installSkill(source: source, apps: apps, method: method)
    }

    // MARK: Forced-refresh throttle

    /// A claimed forced-refresh window, and what to put back if it is released.
    private struct ForcedRefreshReservation {
        let claimedAt: Date
        let previous: Date?
    }

    private enum ForcedRefreshAdmission {
        case admitted(ForcedRefreshReservation)
        case throttled(seconds: Int)
    }

    /// Claim the forced-refresh window, or report the seconds still to wait.
    ///
    /// Checking and stamping have to happen under one lock hold. Two clients
    /// calling `quota.refresh {force:true}` at the same instant would otherwise
    /// both read an expired timestamp, both pass, and both suspend on the data
    /// source before either of them marked anything — which is exactly the
    /// double API hit the throttle exists to prevent.
    private func admitForcedRefresh() -> ForcedRefreshAdmission {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if let last = lastForcedRefreshAt {
            let elapsed = current.timeIntervalSince(last)
            if elapsed < Self.forcedRefreshMinimumInterval {
                return .throttled(seconds: max(1, Int((Self.forcedRefreshMinimumInterval - elapsed).rounded(.up))))
            }
        }
        let reservation = ForcedRefreshReservation(claimedAt: current, previous: lastForcedRefreshAt)
        lastForcedRefreshAt = current
        return .admitted(reservation)
    }

    /// Roll a reservation back, so a refusal does not burn the window.
    ///
    /// Only the reservation still on record is rolled back: while it stands,
    /// every other forced call is throttled, so a mismatch can only mean the
    /// window already moved on and is not ours to undo.
    private func release(_ reservation: ForcedRefreshReservation) {
        lock.lock()
        if lastForcedRefreshAt == reservation.claimedAt {
            lastForcedRefreshAt = reservation.previous
        }
        lock.unlock()
    }

    // MARK: Result shaping

    /// Every tool answers the same way: pretty JSON in `content` for the model
    /// to read, and the identical object in `structuredContent` for a client
    /// that parses. One encode feeds both, so they cannot drift.
    static func successResult(_ payload: any Encodable) throws -> MCPJSON {
        let text = try MCPJSON.prettyText(AnyEncodableBox(payload))
        let structured = try MCPJSON.encoding(AnyEncodableBox(payload))
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": structured,
            "isError": .bool(false)
        ])
    }

    static func errorResult(_ message: String) -> MCPJSON {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true)
        ])
    }
}

/// Existential `Encodable` cannot be handed to `JSONEncoder` directly.
private struct AnyEncodableBox: Encodable {
    let wrapped: any Encodable

    init(_ wrapped: any Encodable) { self.wrapped = wrapped }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}

// MARK: - Argument parsing

/// Vibe Bar's own `tools/call` argument accessor.
///
/// `MCPArguments` itself — the unknown-key rejection and the typed scalar
/// readers — is `AgentSessionKit`'s. What is Vibe Bar's is the shape below:
/// the ledger window and the three list filters every usage tool takes.
extension MCPArguments {
    /// `from` / `to` / `days` collapsed into the half-open interval every
    /// ledger query takes, plus the three list filters.
    func usageFilter(now: Date) throws -> UsageQueryFilter {
        let end = try optionalDate("to") ?? now
        let start: Date
        if let from = try optionalDate("from") {
            start = from
        } else {
            let days = try optionalInt("days", minimum: 1, maximum: 3_650) ?? 30
            start = end.addingTimeInterval(-Double(days) * 86_400)
        }
        guard start < end else {
            throw MCPRPCError.invalidParams(
                "\(toolName): the window is empty — 'from' must be earlier than 'to'."
            )
        }
        return UsageQueryFilter(
            range: DateInterval(start: start, end: end),
            tools: try optionalEnumList("tools", ToolType.self),
            harnesses: try optionalEnumList("harnesses", Harness.self),
            models: try optionalStringList("models")
        )
    }
}

extension UsageQueryFilter {
    var mcpFilters: MCPUsageFiltersDTO {
        MCPUsageFiltersDTO(
            tools: tools?.map(\.rawValue),
            harnesses: harnesses?.map(\.rawValue),
            models: models
        )
    }
}
