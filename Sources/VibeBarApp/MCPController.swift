import Combine
import Foundation
import VibeBarCore

/// Owns the local MCP server and answers its tools from `AppEnvironment`.
///
/// Two jobs, kept in one place on purpose. The lifecycle half starts and stops
/// the Unix-socket listener as the setting changes, so the socket exists
/// exactly while the app is running with MCP enabled. The data half is the
/// `MCPDataSource` implementation: every method hops to the main actor, reads
/// already-cached state, and hands Core a value to project — no method here
/// starts a network fetch except `refreshQuota`, which is the one tool that
/// says it does.
@MainActor
final class MCPController: ObservableObject, MCPDataSource {
    /// Live listener state, for the Settings pane.
    @Published private(set) var isRunning = false
    @Published private(set) var connectionCount = 0
    @Published private(set) var lastClientActivityAt: Date?
    /// Why the listener is not up, when it should be. Shown in Settings rather
    /// than only logged: a failed bind is the difference between "agents can
    /// read my usage" and silence.
    @Published private(set) var startupError: String?

    let socketPath: String

    /// `~/.vibebar/mcp.sock` rather than the user's absolute home — the
    /// Settings pane is the one place the path is shown, and it is the form
    /// people recognise (and the one that can appear in a screenshot).
    var displaySocketPath: String {
        let home = RealHomeDirectory.path
        guard socketPath.hasPrefix(home + "/") else { return socketPath }
        return "~" + socketPath.dropFirst(home.count)
    }

    private weak var environment: AppEnvironment?
    private var server: MCPServer?
    private var socketServer: MCPSocketServer?
    private var cancellables: Set<AnyCancellable> = []

    /// The session index, opened on the first `sessions.*` call.
    ///
    /// Deliberately not built at launch: opening it costs a SQLite file the
    /// menu-bar-only session never needs, and the Workbench's Sessions page
    /// keeps its own handle. Two connections to one WAL database with a busy
    /// timeout is a supported arrangement — the alternative, threading this
    /// through `SessionManagerModel`, would couple the MCP surface to the
    /// Workbench's lifecycle for no benefit.
    private var sessionIndex: SessionIndexService?
    private var sessionIndexUnavailable = false
    /// One opportunistic scan per process when the index has never been built.
    /// Without it, `sessions.search` answers "nothing" until the user happens
    /// to open the Workbench, which reads as a bug rather than as an empty
    /// index.
    private var didAttemptSessionBackfill = false
    /// The privacy switch, mirrored so the index actor can read it without a
    /// main-actor hop — and, unlike a captured `Bool`, re-read on every pass.
    /// Toggling "Index message text" off has to reach the MCP surface too, or
    /// an agent's `sessions.search` would keep hitting (and re-populating) an
    /// index the user just disabled.
    private let bodyIndexing: BodyIndexingFlag

    init(environment: AppEnvironment, socketPath: String = MCPSocketServer.defaultSocketPath) {
        self.environment = environment
        self.socketPath = socketPath
        self.bodyIndexing = BodyIndexingFlag(
            environment.settingsStore.settings.sessionBodyIndexingEnabled
        )
    }

    // MARK: - Lifecycle

    /// Start listening if the setting says so, and keep following that setting.
    func start(settingsStore: SettingsStore) {
        applyEnabled(settingsStore.settings.mcpServer.enabled)
        settingsStore.$settings
            .map(\.mcpServer.enabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.applyEnabled(enabled) }
            }
            .store(in: &cancellables)

        // Follow the body-indexing switch for as long as the app runs, not
        // just until the first `sessions.*` call opened the index.
        settingsStore.$settings
            .map(\.sessionBodyIndexingEnabled)
            .removeDuplicates()
            .sink { [bodyIndexing] enabled in bodyIndexing.set(enabled) }
            .store(in: &cancellables)
    }

    func stop() {
        socketServer?.stop()
        socketServer = nil
        server = nil
        isRunning = false
        connectionCount = 0
    }

    private func applyEnabled(_ enabled: Bool) {
        guard enabled else {
            stop()
            startupError = nil
            return
        }
        guard socketServer == nil else { return }
        let server = MCPServer(dataSource: self)
        let socket = MCPSocketServer(server: server, socketPath: socketPath)
        socket.onConnectionChange = { [weak self] count, at in
            Task { @MainActor in
                self?.connectionCount = count
                self?.lastClientActivityAt = at
            }
        }
        do {
            try socket.start()
            self.server = server
            self.socketServer = socket
            self.isRunning = true
            self.startupError = nil
        } catch let error as MCPSocketError {
            self.startupError = error.message
            self.isRunning = false
            SafeLog.warn("MCP server did not start: \(SafeLog.sanitize(error.message))")
        } catch {
            self.startupError = error.localizedDescription
            self.isRunning = false
            SafeLog.warn("MCP server did not start: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }

    // MARK: - MCPDataSource: identity

    func serverInfo() async -> MCPServerInfo {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let version: String
        switch (short, build) {
        case let (.some(short), .some(build)): version = "\(short) (\(build))"
        case let (.some(short), .none):        version = short
        // `swift run` has no Info.plist at all; saying so beats reporting a
        // version number that is not in any release.
        default:                               version = "source build"
        }
        return MCPServerInfo(name: "vibebar", version: version)
    }

    // MARK: - MCPDataSource: quota

    func quotaAccounts(tools: [ToolType]?, includeForecast: Bool) async throws -> [MCPQuotaAccountDTO] {
        guard let environment else { throw MCPToolFailure("Vibe Bar is shutting down.") }
        let quotaService = environment.quotaService
        let wanted = tools.map(Set.init)
        let identities = environment.accountStore.accounts
            .filter { wanted?.contains($0.tool) ?? true }

        return identities.map { identity in
            let quota = quotaService.cachedQuota(for: identity.id)
                ?? AccountQuota(
                    accountId: identity.id,
                    tool: identity.tool,
                    buckets: [],
                    plan: identity.plan,
                    email: identity.email,
                    queriedAt: Date(timeIntervalSince1970: 0)
                )
            var forecasts: [String: QuotaPaceForecast] = [:]
            if includeForecast {
                let snapshot = environment.costService.snapshot(for: quota.tool)
                for bucket in quota.buckets {
                    forecasts[bucket.id] = quotaService.paceForecast(
                        accountId: quota.accountId,
                        bucket: bucket,
                        activityHeatmap: snapshot?.heatmap,
                        dailyActivity: snapshot?.dailyHistory ?? []
                    )
                }
            }
            return MCPQuotaAccountDTO(
                quota: quota,
                // A never-refreshed account has no timestamps at all; the
                // sentinel `queriedAt` above would otherwise read as 1970.
                lastUpdated: quotaService.lastUpdatedByAccount[identity.id],
                lastAttempted: quotaService.lastAttemptedByAccount[identity.id],
                inFlight: quotaService.inFlightAccountIds.contains(identity.id),
                error: quotaService.lastErrorByAccount[identity.id],
                forecastsByBucketID: forecasts
            )
        }
    }

    func refreshQuota(tools: [ToolType]?, force: Bool) async throws -> MCPRefreshResultDTO {
        guard let environment else { throw MCPToolFailure("Vibe Bar is shutting down.") }
        guard environment.settingsStore.settings.mcpServer.allowRefreshTools else {
            return MCPRefreshResultDTO(
                triggered: false,
                mode: force ? "forced" : "stale-only",
                message: "Refreshing from agents is switched off in Vibe Bar → Settings → MCP Server. "
                    + "quota.get still reports the cached numbers and when they were fetched."
            )
        }

        if force {
            if let tools, !tools.isEmpty {
                for tool in tools { environment.refresh(tool) }
                return MCPRefreshResultDTO(
                    triggered: true,
                    mode: "forced",
                    message: "Refreshing \(tools.map(\.rawValue).joined(separator: ", ")). "
                        + "Call quota.get in a few seconds for the new numbers."
                )
            }
            environment.scheduler.triggerRefresh()
            return MCPRefreshResultDTO(
                triggered: true,
                mode: "forced",
                message: "Refreshing every visible account. Call quota.get in a few seconds for the new numbers."
            )
        }

        // The same `tools` filter the forced path honours. Without it a
        // narrowly-scoped call would quietly refresh every provider — and an
        // explicitly empty list, which the argument parser preserves on
        // purpose, would widen to "everything" instead of matching nothing.
        let triggered = environment.scheduler.triggerRefreshForStaleCacheIfNeeded(tools: tools)
        let scope = tools.map { $0.map(\.rawValue).joined(separator: ", ") }
        return MCPRefreshResultDTO(
            triggered: triggered,
            mode: "stale-only",
            message: triggered
                ? "Refreshing the accounts whose cache was stale. Call quota.get in a few seconds."
                : scope.map {
                    $0.isEmpty
                        ? "'tools' was empty, so nothing was selected to refresh."
                        : "Nothing was stale for \($0) — it is inside its refresh interval. "
                            + "quota.get already has current numbers."
                } ?? "Nothing was stale — every account is inside its refresh interval. "
                    + "quota.get already has current numbers."
        )
    }

    // MARK: - MCPDataSource: usage ledger

    private func ledger() throws -> UsageEventLedger {
        guard let ledger = environment?.usageLedger else {
            throw MCPToolFailure(
                "The usage ledger is unavailable, so per-request history cannot be queried. "
                    + "cost.snapshot still reports per-provider totals."
            )
        }
        return ledger
    }

    func usageSummary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics {
        try await ledger().summary(filter)
    }

    func usageGroupRows(
        _ filter: UsageQueryFilter,
        groupBy: MCPUsageGrouping
    ) async throws -> [MCPUsageGroupRowDTO] {
        let ledger = try ledger()
        switch groupBy {
        case .harness:
            // Fold the ledger's raw (tool, harness) groups first: a migrated
            // ledger can hold both a backfilled and a freshly stamped group
            // for one harness, and reporting them as two rows would invent a
            // harness split that does not exist.
            return UsageHarnessStat.mergedByHarness(try await ledger.harnessStats(filter)).map { stat in
                MCPUsageGroupRowDTO(
                    key: stat.harness.rawValue,
                    label: stat.harness.displayName,
                    company: stat.harness.companyName,
                    requests: stat.requests,
                    totalTokens: stat.totalTokens,
                    costMicros: stat.costMicros
                )
            }
        case .provider:
            return UsageProviderStat.mergedByCompany(try await ledger.providerStats(filter)).map { stat in
                MCPUsageGroupRowDTO(
                    key: stat.tool.rawValue,
                    label: stat.tool.vendorName,
                    company: stat.tool.vendorName,
                    requests: stat.requests,
                    totalTokens: stat.totalTokens,
                    costMicros: stat.costMicros
                )
            }
        case .model:
            return try await ledger.modelStats(filter).map { stat in
                MCPUsageGroupRowDTO(
                    key: stat.model,
                    label: UsageModelNaming.canonicalDisplayName(stat.model),
                    company: nil,
                    requests: stat.requests,
                    totalTokens: stat.totalTokens,
                    costMicros: stat.costMicros
                )
            }
        }
    }

    func usageTrend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket?) async throws -> UsageTrendSeries {
        try await ledger().trend(filter, bucket: bucket)
    }

    func usageRequests(
        _ filter: UsageQueryFilter,
        after cursor: UsageRequestCursor?,
        pageSize: Int
    ) async throws -> UsageRequestPage {
        try await ledger().requestPage(filter, after: cursor, pageSize: pageSize)
    }

    // MARK: - MCPDataSource: cost

    func costSnapshots(tools: [ToolType]?) async throws -> MCPCostSnapshotsDTO {
        guard let environment else { throw MCPToolFailure("Vibe Bar is shutting down.") }
        let wanted = tools.map(Set.init)
        let snapshots = ToolType.costAwareProviders
            .filter { wanted?.contains($0) ?? true }
            .compactMap { environment.costService.snapshot(for: $0) }
        return MCPCostSnapshotsDTO(
            generatedAt: Date(),
            privacyModeEnabled: environment.settingsStore.settings.costData.privacyModeEnabled,
            tools: snapshots.map(MCPCostToolSnapshotDTO.init(snapshot:))
        )
    }

    func costHistory(tool: ToolType, timeframe: MCPCostHistoryTimeframe) async throws -> CostHistory {
        guard let environment else { throw MCPToolFailure("Vibe Bar is shutting down.") }
        return await environment.costService.costHistory(for: tool, timeframe: timeframe.timeframe)
    }

    // MARK: - MCPDataSource: sessions

    func searchSessions(
        query: String,
        providers: [SessionProvider]?,
        harnesses: [Harness]?,
        limit: Int
    ) async throws -> [SessionSearchHit] {
        let index = try sessionIndexService()
        var hits = try await index.search(query, providers: providers, harnesses: harnesses, limit: limit)
        if hits.isEmpty, await backfillSessionIndexIfNeeded(index) {
            hits = try await index.search(query, providers: providers, harnesses: harnesses, limit: limit)
        }
        return hits
    }

    func listSessions(
        providers: [SessionProvider]?,
        harnesses: [Harness]?,
        since: Date?,
        offset: Int,
        limit: Int
    ) async throws -> SessionSummaryPage {
        let index = try sessionIndexService()
        var page = try await index.summaryPage(
            providers: providers,
            harnesses: harnesses,
            since: since,
            order: .recentFirst,
            offset: offset,
            limit: limit
        )
        if page.totalCount == 0, await backfillSessionIndexIfNeeded(index) {
            page = try await index.summaryPage(
                providers: providers,
                harnesses: harnesses,
                since: since,
                order: .recentFirst,
                offset: offset,
                limit: limit
            )
        }
        return page
    }

    private func sessionIndexService() throws -> SessionIndexService {
        if let sessionIndex { return sessionIndex }
        guard !sessionIndexUnavailable else {
            throw MCPToolFailure("The session index could not be opened, so sessions cannot be listed.")
        }
        do {
            let store = try SessionIndexStore(url: VibeBarLocalStore.sessionIndexURL)
            // Explicit home on both: the kit's own defaults resolve the real
            // home, not the one `RealHomeDirectory` may be redirected to.
            let home = RealHomeDirectory.path
            let service = SessionIndexService(
                homeDirectory: home,
                store: store,
                // Bounded like the Workbench's indexer: MCP-triggered
                // backfills hit the same multi-hundred-MB rollouts.
                registry: SessionIndexingBounds.boundedRegistry(
                    SessionProviderRegistry.standard(homeDirectory: home),
                    scratchDirectory: VibeBarLocalStore
                        .sessionIndexScratchDirectoryURL(homeDirectory: home)
                ),
                bodyIndexing: { [bodyIndexing] in bodyIndexing.current }
            )
            sessionIndex = service
            return service
        } catch {
            sessionIndexUnavailable = true
            SafeLog.warn("MCP: opening the session index failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw MCPToolFailure("The session index could not be opened, so sessions cannot be listed.")
        }
    }

    /// Returns true when a scan actually ran, so the caller re-queries.
    private func backfillSessionIndexIfNeeded(_ index: SessionIndexService) async -> Bool {
        guard !didAttemptSessionBackfill else { return false }
        didAttemptSessionBackfill = true
        await index.refreshIndex()
        return true
    }

    // MARK: - MCPDataSource: status and pricing

    func serviceStatus(tools: [ToolType]?) async throws -> MCPServiceStatusDTO {
        guard let environment else { throw MCPToolFailure("Vibe Bar is shutting down.") }
        let controller = environment.serviceStatus
        // Status is an L1 company fact: Google AI covers Gemini + AntiGravity
        // and SpaceXAI covers Grok + Cursor, so a request naming a member
        // resolves to the company row that actually has a feed.
        let wanted = tools.map { Set($0.compactMap { $0.coreProviderRepresentative }) }
        let rows = ToolType.combinedStatusPageProviders
            .filter { wanted?.contains($0) ?? true }
            .map { tool -> MCPServiceStatusRowDTO in
                let projection = controller.projection(for: tool)
                return MCPServiceStatusRowDTO(
                    tool: tool.rawValue,
                    company: tool.vendorName,
                    indicator: projection.snapshot?.indicator.rawValue ?? "unknown",
                    description: projection.snapshot?.description ?? "No status has been read yet.",
                    updatedAt: projection.snapshot?.updatedAt,
                    isRefreshing: projection.isRefreshing,
                    error: projection.error
                )
            }
        return MCPServiceStatusDTO(
            generatedAt: Date(),
            lastFetched: controller.lastFetched,
            companies: rows
        )
    }

    func effectivePricing() async throws -> [EffectiveModelPricingRow] {
        PricingResolver.active.effectiveModelPrices
    }

    // MARK: - MCPDataSource: skills

    /// The only tool that writes, and it writes nothing this app could not
    /// already write: `SkillsService` owns the SSOT copy, the per-app
    /// projection, and the write allowlist (`AGENTS.md` § 7). Everything here
    /// is the gate and the hand-off.
    func installSkill(
        source: SkillInstallSource,
        apps: [SkillAppTarget],
        method: SkillSyncMethod
    ) async throws -> MCPSkillInstallDTO {
        guard let environment else { throw MCPToolFailure("Vibe Bar is shutting down.") }
        guard environment.settingsStore.settings.mcpServer.allowSkillInstall else {
            throw MCPToolFailure(
                "Installing skills from agents is switched off in Vibe Bar → Settings → MCP Server. "
                    + "The user can install it themselves from Workbench → Skills → Discover."
            )
        }
        let outcome = try await environment.skillsService.install(
            from: source,
            enableFor: apps,
            method: method
        )
        // Directory names only: the source can be a path under the user's home.
        SafeLog.info(
            "MCP: installed \(outcome.installed.map(\.skill.directory).joined(separator: ", "))"
        )
        return MCPSkillInstallDTO(outcome: outcome)
    }
}
