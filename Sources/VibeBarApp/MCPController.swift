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

    /// One opportunistic scan per process when the index has never been built.
    /// Without it, `sessions.search` answers "nothing" until the user happens
    /// to open the Workbench, which reads as a bug rather than as an empty
    /// index.
    private var didAttemptSessionBackfill = false
    /// Built on the first `sessions.transcript` call. See `transcriptRegistry`.
    private var registryStorage: SessionProviderRegistry?
    /// Latched once the index is known to hold rows, so `readingSessions`
    /// stops asking. See `isSessionIndexUnbuilt`.
    private var didObservePopulatedIndex = false

    /// How long a connected client may say nothing before its socket is
    /// closed.
    ///
    /// The package leaves this off, because a library cannot know whether its
    /// host's clients respawn after an intentional EOF. Vibe Bar's do: every
    /// client is a `--mcp-stdio` child that the agent starts on demand and
    /// restarts the moment it needs the socket again. Without a timeout those
    /// children accumulate — 21 were alive on one machine — each holding one
    /// of the 64 connection slots for the rest of the app's life. Forty-five
    /// minutes is far longer than any pause inside a working session and far
    /// shorter than a day of leaving editors open.
    static let clientIdleTimeout: TimeInterval = 45 * 60

    init(environment: AppEnvironment, socketPath: String = MCPSocketServer.configuredSocketPath) {
        self.environment = environment
        self.socketPath = socketPath
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

        // The body-indexing switch is followed by `SharedSessionIndex`, which
        // owns the flag the index actor reads — one subscription for both the
        // Workbench's Sessions page and this surface.
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
        let socket = MCPSocketServer(
            server: server,
            socketPath: socketPath,
            idleTimeout: Self.clientIdleTimeout
        )
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

    /// The one door every session read goes through.
    ///
    /// `read` runs, and if the index has *never been built* the one-per-process
    /// backfill runs and `read` is retried. It is a single entry point on
    /// purpose: the backfill used to be remembered at each call site, and the
    /// host-side `sessions.list` path was added without it — so a fresh
    /// install with a `to` or `models` filter returned zero and never scanned.
    ///
    /// "Never been built" is asked of the store, not inferred from a zero-row
    /// result. Inferring it made the door far too eager: an offset past the
    /// last row, a filter that legitimately matches nothing, an unknown
    /// transcript id — each of those is an ordinary empty answer, and each
    /// used to kick off a filesystem-wide sweep of every provider's logs.
    /// `isEmpty` survives only as a cheap gate on *asking*: rows in hand
    /// already prove the index is populated, so the count query never runs on
    /// the common path.
    private func readingSessions<T>(
        isEmpty: (T) -> Bool,
        _ read: (SessionIndexService) async throws -> T
    ) async throws -> T {
        let index = try sessionIndexService()
        let first = try await read(index)
        guard isEmpty(first) else {
            didObservePopulatedIndex = true
            return first
        }
        guard await isSessionIndexUnbuilt(), await backfillSessionIndexIfNeeded(index) else {
            return first
        }
        return try await read(index)
    }

    /// Has the session index never held a row?
    ///
    /// One `SELECT COUNT(*)` per process at most: a populated index latches
    /// the flag and is never asked again, and an unpopulated one is answered
    /// by the backfill's own one-shot guard.
    private func isSessionIndexUnbuilt() async -> Bool {
        if didObservePopulatedIndex { return false }
        guard let store = environment?.sessionIndex.store else { return false }
        let count = (try? await store.sessionCount()) ?? 0
        if count > 0 {
            didObservePopulatedIndex = true
            return false
        }
        return true
    }

    func searchSessions(
        query: String,
        filter: SessionQueryFilter,
        limit: Int
    ) async throws -> MCPSessionSearchOutcome {
        // An explicitly empty list means "nothing" (see
        // `SessionQueryFilter.matchesNothing`), and nothing is answerable
        // without touching the index at all.
        guard !filter.matchesNothing else { return MCPSessionSearchOutcome(hits: []) }
        // The store ranks and caps, and `to`, `from` and `models` are ours to
        // apply afterwards (it has no upper time bound and no model column
        // filter). So the host-side filter runs *after* the ranking cut, and
        // a query whose top hits are all excluded — searching with an old
        // `to` bound against a term that matches mostly recent sessions — can
        // starve a page of matches that exist further down.
        //
        // Escalate rather than accept that: ask for more ranked hits until
        // the page is filled or the store's own ceiling is reached. At most
        // two passes, and FTS ranking is the fast part of this query.
        let needsHostFilter = !(filter.isAnsweredEntirelyByTheIndex && filter.from == nil)
        return try await readingSessions(isEmpty: \.hits.isEmpty) { index in
            var wanted = needsHostFilter
                ? min(limit * Self.searchOverFetchFactor, Self.searchOverFetchCap)
                : limit
            var matched: [SessionSearchHit] = []
            var sawEverything = false
            while true {
                let hits = try await Self.rankedHits(
                    index, query: query, filter: filter, limit: wanted
                )
                matched = hits.filter { filter.matches($0.summary) }
                // Fewer hits than asked for means the store had no more to
                // rank, so nothing is hiding below the cut.
                sawEverything = hits.count < wanted
                if matched.count >= limit || sawEverything || wanted >= Self.searchRankingCeiling {
                    break
                }
                wanted = Self.searchRankingCeiling
            }
            // Silence is the one wrong answer here: an agent cannot tell
            // "nothing matches" from "the ranking cut ate the matches".
            let incomplete = matched.count < limit && !sawEverything
            return MCPSessionSearchOutcome(
                hits: Array(matched.prefix(limit)),
                notice: incomplete
                    ? "Filters ran after the ranking cut: the top \(wanted) hits for this query "
                        + "yielded \(matched.count) match(es), and more may exist below the cut. "
                        + "Narrow 'query', or widen 'from' / 'to' / 'models' / 'projectDir'."
                    : nil
            )
        }
    }

    /// Over-fetch multiplier and the ceiling on one ranked pass.
    private static let searchOverFetchFactor = 4
    private static let searchOverFetchCap = 200
    /// `SessionIndexStore.search` clamps its own limit here, so asking for
    /// more than this returns the same rows.
    private static let searchRankingCeiling = 500
    /// How many index rows a host-side-filtered `sessions.list` will walk
    /// before it stops and says so. Eight store pages at 11 000 indexed
    /// sessions — enough to page deep into a filtered view, bounded enough
    /// that a pathological filter cannot turn one tool call into a full scan.
    private static let listScanCap = 4_000
    private static let listStorePageSize = 500

    private nonisolated static func rankedHits(
        _ index: SessionIndexService,
        query: String,
        filter: SessionQueryFilter,
        limit: Int
    ) async throws -> [SessionSearchHit] {
        try await index.search(
            query,
            providers: filter.providers,
            harnesses: filter.harnesses,
            projectIncludes: filter.projectIncludes,
            limit: limit
        )
    }

    func listSessions(
        filter: SessionQueryFilter,
        offset: Int,
        limit: Int
    ) async throws -> MCPSessionListing {
        guard !filter.matchesNothing else {
            return MCPSessionListing(
                summaries: [], totalCount: 0, offset: offset, limit: limit, hasMore: false
            )
        }
        // Both paths go through `readingSessions`, so a fresh install
        // backfills and retries whichever one the filter selected.
        return try await readingSessions(isEmpty: \.summaries.isEmpty) { index in
            // Fast path: the index can answer all of it, so its own count and
            // offset describe exactly the rows returned.
            if filter.isAnsweredEntirelyByTheIndex {
                let page = try await Self.storePage(
                    index, filter: filter, offset: offset, limit: limit
                )
                return MCPSessionListing(
                    summaries: page.summaries,
                    totalCount: page.totalCount,
                    offset: page.offset,
                    limit: page.limit,
                    hasMore: page.offset + page.summaries.count < page.totalCount
                )
            }

            // Host-side path: walk the index in store pages and filter as we
            // go. `totalCount` is withheld rather than reported — the store's
            // count describes the rows before `to` / `models` ran.
            var kept: [SessionSummary] = []
            var scanned = 0
            var storeOffset = 0
            var exhausted = false
            // One past the last row this page needs, so the loop knows when to
            // stop instead of draining the index.
            let needed = offset + limit + 1
            while kept.count < needed, scanned < Self.listScanCap {
                let page = try await Self.storePage(
                    index, filter: filter, offset: storeOffset, limit: Self.listStorePageSize
                )
                guard !page.summaries.isEmpty else { exhausted = true; break }
                scanned += page.summaries.count
                storeOffset += page.summaries.count
                kept.append(contentsOf: page.summaries.filter(filter.matches))
                if storeOffset >= page.totalCount { exhausted = true; break }
            }
            let window = Array(kept.dropFirst(offset).prefix(limit))
            let hasMore = kept.count > offset + window.count || !exhausted
            return MCPSessionListing(
                summaries: window,
                totalCount: exhausted && scanned < Self.listScanCap ? kept.count : nil,
                offset: offset,
                limit: limit,
                hasMore: hasMore,
                notice: scanned >= Self.listScanCap
                    ? "Stopped after examining \(scanned) indexed sessions; 'to' and 'models' are "
                        + "applied after the index query. Narrow 'from', 'projectDir' or 'harnesses' "
                        + "to see further back."
                    : nil
            )
        }
    }

    private nonisolated static func storePage(
        _ index: SessionIndexService,
        filter: SessionQueryFilter,
        offset: Int,
        limit: Int
    ) async throws -> SessionSummaryPage {
        try await index.summaryPage(
            providers: filter.providers,
            harnesses: filter.harnesses,
            since: filter.from,
            projectIncludes: filter.projectIncludes,
            order: .recentFirst,
            offset: offset,
            limit: limit
        )
    }

    // MARK: - MCPDataSource: transcripts

    /// The raw registry, built once. The *bounded* one lives on
    /// `SharedSessionIndex` and belongs to the indexer; a transcript read
    /// wants whole messages, bounded by bytes rather than by excerpt policy.
    private var transcriptRegistry: SessionProviderRegistry {
        if let registryStorage { return registryStorage }
        let registry = SessionProviderRegistry.standard(homeDirectory: RealHomeDirectory.path)
        registryStorage = registry
        return registry
    }

    func sessionTranscript(
        locator: SessionLocator,
        window: TranscriptWindowRequest
    ) async throws -> SessionTranscriptResult {
        let found = try await readingSessions(isEmpty: { $0 == nil }) { index in
            try await index.summary(provider: locator.provider, sessionID: locator.sessionID)
        }
        guard let summary = found else {
            throw MCPToolFailure(
                "No indexed \(locator.provider.displayName) session with id '\(locator.sessionID)'. "
                    + "The index is as fresh as Vibe Bar's last sweep, so a session created moments "
                    + "ago may not be in it yet. Use sessions.search or sessions.list to get an id."
            )
        }
        guard let adapter = transcriptRegistry.adapter(for: summary.provider) else {
            throw MCPToolFailure("No reader is registered for \(summary.provider.displayName).")
        }
        let scratch = VibeBarLocalStore.sessionIndexScratchDirectoryURL(
            homeDirectory: RealHomeDirectory.path
        )
        // Off the main actor, and off the index actor: the read is the
        // expensive part and neither of those may wait on it.
        let read = try await Self.readWindow(
            adapter: adapter,
            url: URL(fileURLWithPath: summary.sourcePath),
            request: window,
            scratchDirectory: scratch
        )
        return SessionTranscriptResult(summary: summary, window: read)
    }

    /// Same shape as the Workbench's transcript parse: a held detached task
    /// with its cancellation forwarded, so a client that disconnects mid-read
    /// actually stops the parse instead of only stopping the wait.
    private nonisolated static func readWindow(
        adapter: any SessionProviderAdapter,
        url: URL,
        request: TranscriptWindowRequest,
        scratchDirectory: URL
    ) async throws -> TranscriptWindow {
        let handle = Task.detached(priority: .userInitiated) {
            try SessionIndexingBounds.readTranscriptWindow(
                adapter: adapter,
                fileURL: url,
                request: request,
                scratchDirectory: scratchDirectory
            )
        }
        return try await withTaskCancellationHandler {
            do {
                return try await handle.value
            } catch is CancellationError {
                throw MCPToolFailure("The transcript read was cancelled.")
            } catch {
                // Never the raw error: a parse failure's description can carry
                // the path, and this string goes to an agent and into logs.
                throw MCPToolFailure(
                    "This session's log could not be read: "
                        + SafeLog.sanitize(error.localizedDescription)
                )
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// The app-wide index, opened on this call if nothing has needed it yet.
    ///
    /// This used to open a second `SessionIndexStore` of its own. Two
    /// connections to one WAL database are legal, but two *indexers* meant an
    /// MCP backfill and a Workbench refresh could each walk all 11 000
    /// session files at the same time over the same 1 GB database.
    private func sessionIndexService() throws -> SessionIndexService {
        guard let environment, let service = environment.sessionIndex.service else {
            throw MCPToolFailure("The session index could not be opened, so sessions cannot be listed.")
        }
        return service
    }

    /// Returns true when a scan actually ran, so the caller re-queries.
    private func backfillSessionIndexIfNeeded(_ index: SessionIndexService) async -> Bool {
        guard !didAttemptSessionBackfill else { return false }
        didAttemptSessionBackfill = true
        // Same gate the Workbench's refresh takes: one indexer at a time, and
        // never on top of the daily compaction pass. The wait is cancellable
        // and claims nothing when it throws, so a client that disconnects
        // mid-wait does not strand the gate.
        let gate = SessionIndexMaintenanceGate.shared
        do {
            try await gate.acquire()
        } catch {
            // Gave up while queued. The one-per-process flag stays set: this
            // was still the process's one opportunistic backfill attempt.
            return false
        }
        guard !Task.isCancelled else {
            await gate.release()
            return false
        }
        await index.refreshIndex()
        await gate.release()
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
