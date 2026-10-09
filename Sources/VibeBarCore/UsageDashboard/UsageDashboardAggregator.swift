import Foundation

// MARK: - Sources

/// Where the dashboard's session list comes from: the kit's session index in
/// the app, a fixed list in tests.
public protocol UsageDashboardSessionSource: Sendable {
    /// Listed sessions (Auto Review children excluded) whose last activity
    /// is at or after `since`, most recent first.
    func sessions(activeSince since: Date) async -> [SessionSummary]
    /// Every listed session in the index; `0` means it has never been built.
    func totalSessionCount() async -> Int
}

/// Structure stats for the sessions the sidecar holds, and the budgeted
/// background parse that fills it.
public protocol UsageDashboardStructureSource: Sendable {
    /// Stats whose row matches the file's current fingerprint, by path.
    func freshStats(for summaries: [SessionSummary]) async -> [String: SessionStats]
    /// Parse what is missing, within the service's own budget. Returns how
    /// many files were parsed.
    func fill(_ summaries: [SessionSummary]) async -> Int
    /// Files above this are never parsed in the background.
    var maxFileBytes: Int64 { get }
}

/// The kit's session index, read through `SessionVisibleRows` so Auto
/// Reviews stay folded exactly as the Sessions page folds them.
public struct SessionIndexDashboardSource: UsageDashboardSessionSource {
    public let service: SessionIndexService
    /// Upper bound on one read, so "All" on a Mac with a decade of rollouts
    /// cannot allocate an unbounded list.
    public var limit: Int

    public init(service: SessionIndexService, limit: Int = 20_000) {
        self.service = service
        self.limit = limit
    }

    public func sessions(activeSince since: Date) async -> [SessionSummary] {
        var out: [SessionSummary] = []
        var offset = 0
        while out.count < limit {
            guard let page = try? await SessionVisibleRows.page(
                service, since: since, order: .recentFirst, offset: offset, limit: 500
            ) else { break }
            out.append(contentsOf: page.summaries)
            offset += page.summaries.count
            if page.summaries.isEmpty || offset >= page.totalCount { break }
        }
        return out
    }

    public func totalSessionCount() async -> Int {
        (try? await SessionVisibleRows.page(service, offset: 0, limit: 1))?.totalCount ?? 0
    }
}

/// `SessionStructureStore` for reads, `SessionStructureService` for fills.
public struct SessionStructureDashboardSource: UsageDashboardStructureSource {
    public let store: SessionStructureStore
    public let service: SessionStructureService

    public init(store: SessionStructureStore, service: SessionStructureService) {
        self.store = store
        self.service = service
    }

    /// The app's instance: both on the live sidecar, Codex state through
    /// `RealHomeDirectory`.
    public static func live() -> SessionStructureDashboardSource {
        let store = SessionStructureStore()
        return SessionStructureDashboardSource(
            store: store,
            service: SessionStructureService(
                store: store,
                codexState: CodexThreadStateReader(homeDirectory: RealHomeDirectory.path)
            )
        )
    }

    public var maxFileBytes: Int64 { service.configuration.batchMaxFileBytes }

    public func freshStats(for summaries: [SessionSummary]) async -> [String: SessionStats] {
        let eligible = summaries.filter { SessionStructureService.supports($0.provider) }
        guard !eligible.isEmpty else { return [:] }
        let rows = await store.statsRows(forPaths: eligible.map(\.sourcePath))
        var out: [String: SessionStats] = [:]
        for summary in eligible {
            guard let row = rows[summary.sourcePath],
                  let fingerprint = SessionFileFingerprint.of(path: summary.sourcePath),
                  row.fingerprint == fingerprint
            else { continue }
            out[summary.sourcePath] = row.stats
        }
        return out
    }

    public func fill(_ summaries: [SessionSummary]) async -> Int {
        await service.refresh(summaries: summaries).parsed
    }
}

// MARK: - Aggregator

/// Builds `UsageDashboardSnapshot`s for the Workbench Usage page and keeps
/// the session-level caches behind them filling in the background.
///
/// An actor: every query, file stat and merge runs on its executor, and the
/// page receives one finished value per query. Ledger reads are memoized on
/// the ledger's `contentRevision()`, so switching back to a range already
/// seen costs a dictionary lookup plus the session merge.
public actor UsageDashboardAggregator {
    public struct Configuration: Sendable, Hashable {
        /// The most recent sessions in a range the background fill will
        /// parse and scan; older ones show index metadata only.
        public var enrichmentSessionLimit: Int
        public var activityBudget: SessionActivityStore.FillBudget
        /// How long a session list read from the index is reused.
        public var sessionListLifetime: TimeInterval

        public init(
            enrichmentSessionLimit: Int = 400,
            activityBudget: SessionActivityStore.FillBudget = SessionActivityStore.FillBudget(),
            sessionListLifetime: TimeInterval = 60
        ) {
            self.enrichmentSessionLimit = enrichmentSessionLimit
            self.activityBudget = activityBudget
            self.sessionListLifetime = sessionListLifetime
        }
    }

    public struct EnrichmentReport: Sendable, Hashable {
        /// Something new landed in a cache; a fresh snapshot will differ.
        public var changed: Bool
        /// Work left for another pass.
        public var hasMore: Bool
    }

    public let configuration: Configuration
    private let ledger: UsageEventLedger?
    private let sessionSource: UsageDashboardSessionSource?
    private let structures: UsageDashboardStructureSource?
    private let activity: SessionActivityStore?
    private let calendar: Calendar

    private var factsCache: [FactsKey: UsageLedgerDashboardFacts] = [:]
    private var factsOrder: [FactsKey] = []
    private var sessionTotals: (revision: UInt64, rows: [UsageLedgerDashboardFacts.SessionRow])?
    private var sessionIDCache: [FactsKey: Set<String>] = [:]
    private var projectOptionCache: [FactsKey: [String: Int64]] = [:]
    private var cacheRevision: UInt64?
    private var sessionList: (since: Date, readAt: Date, rows: [SessionSummary])?

    fileprivate struct FactsKey: Hashable {
        var start: Date
        var end: Date
        var harnesses: [Harness]?
        var model: String?
        var project: String?
    }

    public init(
        ledger: UsageEventLedger?,
        sessions: UsageDashboardSessionSource?,
        structures: UsageDashboardStructureSource?,
        activity: SessionActivityStore?,
        calendar: Calendar = UsageDashboardCalendar.local,
        configuration: Configuration = Configuration()
    ) {
        self.ledger = ledger
        self.sessionSource = sessions
        self.structures = structures
        self.activity = activity
        self.calendar = calendar
        self.configuration = configuration
    }

    // MARK: Range

    /// The interval a preset covers now; `all` starts at the ledger's first
    /// retained fact.
    public func interval(for range: UsageDashboardRange, harnesses: [Harness]?, now: Date = Date()) async -> DateInterval {
        var earliest: Date?
        if range == .all, let ledger {
            earliest = try? await ledger.earliestUsageDate(harnesses: harnesses)
        }
        return range.interval(now: now, earliest: earliest, calendar: calendar)
    }

    // MARK: Snapshot

    public func snapshot(_ query: UsageDashboardQuery, now: Date = Date()) async -> UsageDashboardSnapshot {
        if let harnesses = query.harnesses, harnesses.isEmpty {
            return .empty(query: query, now: now)
        }
        var inputs = UsageDashboardInputs(query: query, now: now, calendar: calendar)
        if let ledger {
            let revision = await ledger.contentRevision()
            if cacheRevision != revision {
                cacheRevision = revision
                factsCache.removeAll()
                factsOrder.removeAll()
                sessionIDCache.removeAll()
                projectOptionCache.removeAll()
            }
            let key = FactsKey(query)
            inputs.ledger = await facts(for: query, ledger: ledger)
            inputs.ledgerSessions = await sessionTotals(ledger: ledger, revision: revision)
            if query.model != nil {
                inputs.ledgerSessionIDsInQuery = await sessionIDs(for: query, key: key, ledger: ledger)
            }
            inputs.availableModels = (try? await ledger.availableModels(harnesses: query.harnesses)) ?? []
            inputs.projectOptions = await projectOptions(for: query, facts: inputs.ledger, ledger: ledger)
        }
        let sessions = await sessionsInRange(query.interval, now: now)
        inputs.sessions = sessions
        let inQuery = sessions.filter { query.includes($0.effectiveHarness) }
        if let structures {
            inputs.structures = await structures.freshStats(for: inQuery)
        }
        if let activity {
            inputs.activity = await activity.tallies(for: inQuery)
        }
        inputs.unreachablePaths = unreachable(
            inQuery, query: query, structureStats: inputs.structures, tallies: inputs.activity
        )
        return UsageDashboardBuilder.build(inputs)
    }

    /// Read the ledger facts for `queries` ahead of time, so switching to one
    /// of them later is a cache hit. Cheap to call again: a cached key is
    /// skipped.
    public func warm(_ queries: [UsageDashboardQuery]) async {
        guard let ledger else { return }
        let revision = await ledger.contentRevision()
        guard revision == cacheRevision else { return }
        for query in queries {
            if Task.isCancelled { return }
            _ = await facts(for: query, ledger: ledger)
        }
    }

    /// Drop the cached session list so the next snapshot re-reads the index.
    public func invalidateSessions() {
        sessionList = nil
    }

    // MARK: Background fill

    /// One budgeted pass over the sessions the query shows: structure rows
    /// first (they carry the session's tokens and cost), then activity scans.
    public func enrich(_ query: UsageDashboardQuery, now: Date = Date()) async -> EnrichmentReport {
        if let harnesses = query.harnesses, harnesses.isEmpty {
            return EnrichmentReport(changed: false, hasMore: false)
        }
        let candidates = enrichmentCandidates(await sessionsInRange(query.interval, now: now), query: query)
        guard !candidates.isEmpty else { return EnrichmentReport(changed: false, hasMore: false) }
        var changed = false
        var hasMore = false
        if let structures {
            let reachable = candidates.filter {
                SessionStructureService.supports($0.provider) && $0.sizeBytes <= structures.maxFileBytes
            }
            let fresh = await structures.freshStats(for: reachable)
            let missing = reachable.filter { fresh[$0.sourcePath] == nil }
            if !missing.isEmpty {
                let parsed = await structures.fill(missing)
                changed = changed || parsed > 0
                hasMore = hasMore || (parsed > 0 && parsed < missing.count)
            }
        }
        if Task.isCancelled { return EnrichmentReport(changed: changed, hasMore: false) }
        if let activity {
            let report = await activity.fill(candidates, budget: configuration.activityBudget)
            changed = changed || report.scanned > 0
            hasMore = hasMore || report.deferred > 0
        }
        return EnrichmentReport(changed: changed, hasMore: hasMore)
    }

    // MARK: Pieces

    /// The query's sessions the background fill can work on, most recently
    /// active first — the order both the fill and `unreachable` rank by.
    private func enrichmentOrder(_ sessions: [SessionSummary], query: UsageDashboardQuery) -> [SessionSummary] {
        sessions
            .filter { summary in
                query.includes(summary.effectiveHarness)
                    && (SessionStructureService.supports(summary.provider) || SessionActivityScanner.supports(summary.provider))
                    && (query.project.map { UsageProjectIdentity.normalizedPath(summary.projectDir) == $0 } ?? true)
            }
            .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }

    private func enrichmentCandidates(_ sessions: [SessionSummary], query: UsageDashboardQuery) -> [SessionSummary] {
        Array(enrichmentOrder(sessions, query: query).prefix(configuration.enrichmentSessionLimit))
    }

    /// Sessions still missing a reading the fill will never produce: past
    /// the count cap, or larger than the cap of the source that is missing —
    /// the structure parse stops at `structures.maxFileBytes` (512 MiB), the
    /// activity scan at `activityBudget.maxFileBytes` (1 GiB). The size is
    /// the file's own when it can be read, so an index row written before
    /// the file grew does not hide it.
    private func unreachable(
        _ sessions: [SessionSummary],
        query: UsageDashboardQuery,
        structureStats: [String: SessionStats],
        tallies: [String: SessionActivityTally]
    ) -> Set<String> {
        var out: Set<String> = []
        for (index, summary) in enrichmentOrder(sessions, query: query).enumerated() {
            let path = summary.sourcePath
            let needsStructure = structures != nil
                && SessionStructureService.supports(summary.provider) && structureStats[path] == nil
            let needsActivity = activity != nil
                && SessionActivityScanner.supports(summary.provider) && tallies[path] == nil
            guard needsStructure || needsActivity else { continue }
            if index >= configuration.enrichmentSessionLimit {
                out.insert(path)
                continue
            }
            let size = max(summary.sizeBytes, SessionFileFingerprint.of(path: path)?.size ?? 0)
            if needsStructure, let structures, size > structures.maxFileBytes { out.insert(path) }
            if needsActivity, size > configuration.activityBudget.maxFileBytes { out.insert(path) }
        }
        return out
    }

    private func sessionsInRange(_ interval: DateInterval, now: Date) async -> [SessionSummary] {
        guard let sessionSource else { return [] }
        if let cached = sessionList,
           cached.since <= interval.start,
           now.timeIntervalSince(cached.readAt) < configuration.sessionListLifetime {
            return cached.rows.filter { ($0.lastActiveAt ?? $0.createdAt ?? .distantFuture) >= interval.start }
        }
        let rows = await sessionSource.sessions(activeSince: interval.start)
        sessionList = (interval.start, now, rows)
        return rows
    }

    /// Facts for the query's range, model and project, every harness in —
    /// the builder applies the chips — so a chip toggle is a cache hit.
    private func facts(for query: UsageDashboardQuery, ledger: UsageEventLedger) async -> UsageLedgerDashboardFacts {
        var allHarnesses = query
        allHarnesses.harnesses = nil
        let key = FactsKey(allHarnesses)
        if let cached = factsCache[key] { return cached }
        let facts = (try? await ledger.dashboardFacts(query.ledgerFilterAllHarnesses, project: query.project))
            ?? UsageLedgerDashboardFacts()
        factsCache[key] = facts
        factsOrder.append(key)
        while factsOrder.count > 12 {
            factsCache.removeValue(forKey: factsOrder.removeFirst())
        }
        return facts
    }

    private func sessionTotals(ledger: UsageEventLedger, revision: UInt64) async -> [UsageLedgerDashboardFacts.SessionRow] {
        if let sessionTotals, sessionTotals.revision == revision { return sessionTotals.rows }
        let rows = (try? await ledger.dashboardSessionTotals()) ?? []
        sessionTotals = (revision, rows)
        return rows
    }

    private func sessionIDs(for query: UsageDashboardQuery, key: FactsKey, ledger: UsageEventLedger) async -> Set<String> {
        if let cached = sessionIDCache[key] { return cached }
        let ids = (try? await ledger.dashboardSessionIDs(query.ledgerFilter, project: query.project)) ?? []
        sessionIDCache[key] = ids
        return ids
    }

    private func projectOptions(
        for query: UsageDashboardQuery,
        facts: UsageLedgerDashboardFacts,
        ledger: UsageEventLedger
    ) async -> [String: Int64] {
        guard query.project != nil else {
            return facts.projects.reduce(into: [:]) { $0[$1.key, default: 0] += $1.tokens }
        }
        var unfiltered = query
        unfiltered.project = nil
        unfiltered.harnesses = nil
        let key = FactsKey(unfiltered)
        if let cached = projectOptionCache[key] { return cached }
        let stats = (try? await ledger.projectStats(unfiltered.ledgerFilterAllHarnesses)) ?? []
        let options = Dictionary(stats.map { ($0.path, $0.totalTokens) }, uniquingKeysWith: +)
        projectOptionCache[key] = options
        return options
    }
}

private extension UsageDashboardAggregator.FactsKey {
    init(_ query: UsageDashboardQuery) {
        self.init(
            start: query.interval.start,
            // A preset that follows now moves its end every second; key the
            // cache to the minute so a re-render reuses the read.
            end: Date(timeIntervalSince1970: (query.interval.end.timeIntervalSince1970 / 60).rounded(.down) * 60),
            harnesses: query.harnesses,
            model: query.model,
            project: query.project
        )
    }
}
