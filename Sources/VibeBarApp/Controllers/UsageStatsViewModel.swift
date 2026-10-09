import Foundation
import Observation
import VibeBarCore

/// Filter state and the current snapshot behind the Workbench Usage page.
///
/// The model holds two things: what the user asked for (range, harnesses,
/// model, project) and the one `UsageDashboardSnapshot` that answers it.
/// Every query, merge and file read runs on `UsageDashboardAggregator`, an
/// actor; a filter change starts a task there and the finished snapshot is
/// assigned here in one write, so no frame waits on SQLite or the disk.
///
/// While the page is on screen a background loop fills the session-level
/// caches (structure sidecar, activity scans) a budget at a time and
/// re-snapshots when something new landed. Leaving the page cancels it.
@MainActor
@Observable
final class UsageStatsViewModel {
    // MARK: Filters

    private(set) var range: UsageDashboardRange = DemoMode.isEnabled ? .month : .week
    /// `nil` is every harness, `[]` none — `HarnessSelection`'s convention.
    private(set) var selectedHarnesses: Set<Harness>?
    private(set) var selectedModel: String?
    private(set) var selectedProject: String?

    // MARK: Results

    private(set) var snapshot: UsageDashboardSnapshot
    private(set) var isLoading = false
    /// The background fill has work left for the current query.
    private(set) var isEnriching = false
    /// The session index has never been built and is being built now.
    private(set) var isBuildingIndex = false
    private(set) var lastUpdatedAt: Date?

    let isLedgerAvailable: Bool

    // MARK: Request log

    /// The request-level rows the previous page's Requests tab listed, newest
    /// first, for the query on screen. Read page by page, and only once the
    /// card asks: a 30-day ledger is a six-figure row count.
    private(set) var requestRows: [UsageRequestRow] = []
    private(set) var requestTotal = 0
    private(set) var isLoadingRequests = false
    var hasMoreRequests: Bool { requestCursor != nil }
    @ObservationIgnored private var requestCursor: UsageRequestCursor?
    /// What the loaded pages were read for (`UsageRequestLogKey`).
    @ObservationIgnored private var requestKey: UsageRequestLogKey?
    @ObservationIgnored private var wantsRequests = false
    /// The header's Refresh was clicked: the next snapshot re-reads the
    /// request pages even if nothing in its key moved.
    @ObservationIgnored private var pendingUserRefresh = false
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private static let requestPageSize = 40

    var harnessOptions: [Harness] { snapshot.options.harnesses.map(\.harness) }

    var hasActiveFilters: Bool {
        selectedHarnesses != nil || selectedModel != nil || selectedProject != nil
    }

    // MARK: Dependencies

    @ObservationIgnored private let ledger: UsageEventLedger?
    @ObservationIgnored private let sessionIndex: () -> SharedSessionIndex
    @ObservationIgnored private var aggregatorStorage: UsageDashboardAggregator?
    @ObservationIgnored private var indexService: SessionIndexService?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var hasLoadedOnce = false
    /// How long a sweep waits when nothing is left to fill.
    @ObservationIgnored private let idleInterval: Duration = .seconds(45)

    init(ledger: UsageEventLedger?, sessionIndex: @escaping () -> SharedSessionIndex) {
        self.ledger = ledger
        self.sessionIndex = sessionIndex
        self.isLedgerAvailable = ledger != nil
        let now = Date()
        let initialRange: UsageDashboardRange = DemoMode.isEnabled ? .month : .week
        self.snapshot = .empty(query: UsageDashboardQuery(
            range: initialRange,
            interval: initialRange.interval(now: now, earliest: nil)
        ))
    }

    /// Built on first activation: opening the session index is the Sessions
    /// page's cost too, and a Workbench opened elsewhere should not pay it.
    private var aggregator: UsageDashboardAggregator {
        if let aggregatorStorage { return aggregatorStorage }
        let shared = sessionIndex()
        indexService = shared.service
        let aggregator = UsageDashboardAggregator(
            ledger: ledger,
            sessions: shared.service.map { SessionIndexDashboardSource(service: $0) },
            structures: SessionStructureDashboardSource.live(),
            activity: SessionActivityStore()
        )
        aggregatorStorage = aggregator
        return aggregator
    }

    // MARK: Lifecycle

    func activate() {
        guard !hasLoadedOnce else {
            reload()
            return
        }
        hasLoadedOnce = true
        reload()
    }

    /// Fill the session caches while the page is visible. `UsageStatsPage`
    /// awaits this in its `.task`, so SwiftUI cancels it when the page goes.
    func pollWhileVisible() async {
        await refreshIndexIfDue()
        while !Task.isCancelled {
            // The query on screen; a filter change lands in the next sweep.
            let report = await aggregator.enrich(snapshot.query)
            if Task.isCancelled { break }
            isEnriching = report.hasMore
            if report.changed {
                await aggregator.invalidateSessions()
                reload(silently: true)
            }
            do {
                try await Task.sleep(for: report.hasMore ? .milliseconds(400) : idleInterval)
            } catch {
                break
            }
            if !report.hasMore {
                // Idle wake-up: pick up whatever a cost scan or a CLI wrote
                // meanwhile — re-scanning the index once its ten minutes are
                // up. A snapshot equal to the one on screen is not assigned,
                // so this costs no render.
                await refreshIndexIfDue()
                await aggregator.invalidateSessions()
                reload(silently: true)
            }
        }
        isEnriching = false
    }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        isLoading = false
    }

    func refresh() {
        pendingUserRefresh = true
        Task { [weak self] in
            guard let self else { return }
            await self.aggregator.invalidateSessions()
            self.reload()
        }
    }

    // MARK: Filter mutation

    func setRange(_ range: UsageDashboardRange) {
        guard range != self.range else { return }
        self.range = range
        reload()
    }

    func toggleHarness(_ harness: Harness) {
        setSelectedHarnesses(HarnessSelection.toggle([harness], in: selectedHarnesses, options: harnessOptions))
    }

    /// ⌥-click on a harness chip: that harness alone.
    func soloHarness(_ harness: Harness) {
        setSelectedHarnesses(HarnessSelection.solo(harness, options: harnessOptions))
    }

    func toggleAllHarnesses() {
        setSelectedHarnesses(HarnessSelection.toggleAll(selectedHarnesses, options: harnessOptions))
    }

    func setSelectedHarnesses(_ harnesses: Set<Harness>?) {
        guard harnesses != selectedHarnesses else { return }
        selectedHarnesses = harnesses
        reload()
    }

    func setModel(_ model: String?) {
        guard model != selectedModel else { return }
        selectedModel = model
        reload()
    }

    func setProject(_ project: String?) {
        guard project != selectedProject else { return }
        selectedProject = project
        reload()
    }

    func clearFilters() {
        guard hasActiveFilters else { return }
        selectedHarnesses = nil
        selectedModel = nil
        selectedProject = nil
        reload()
    }

    func isHarnessSelected(_ harness: Harness) -> Bool {
        selectedHarnesses?.contains(harness) ?? true
    }

    // MARK: Requests

    /// The card appeared: read the first page for the query on screen.
    func loadRequestsIfNeeded() {
        wantsRequests = true
        guard requestKey != UsageRequestLogKey(snapshot) else { return }
        loadRequests(reset: true)
    }

    func loadMoreRequests() {
        guard requestCursor != nil, !isLoadingRequests else { return }
        loadRequests(reset: false)
    }

    private func loadRequests(reset: Bool) {
        guard let ledger else { return }
        let query = snapshot.query
        if let harnesses = query.harnesses, harnesses.isEmpty { return }
        let cursor = reset ? nil : requestCursor
        requestTask?.cancel()
        isLoadingRequests = true
        if reset { requestKey = UsageRequestLogKey(snapshot) }
        let key = requestKey
        let aggregator = self.aggregator
        requestTask = Task { [weak self] in
            let projects = await aggregator.ledgerProjects(for: query)
            let page = try? await ledger.requestPage(
                query.ledgerFilter,
                projects: projects,
                after: cursor,
                pageSize: Self.requestPageSize,
                includeTotal: reset
            )
            guard let self, !Task.isCancelled, self.requestKey == key else { return }
            self.isLoadingRequests = false
            guard let page else { return }
            if reset {
                self.requestRows = page.rows
                self.requestTotal = page.totalCount ?? page.rows.count
            } else {
                self.requestRows.append(contentsOf: page.rows)
            }
            self.requestCursor = page.nextCursor
        }
    }

    // MARK: Queries

    private func reload(silently: Bool = false) {
        generation &+= 1
        let generation = self.generation
        reloadTask?.cancel()
        if !silently { isLoading = true }
        let aggregator = self.aggregator
        let range = self.range
        let harnesses = selectedHarnesses.map { Array($0) }
        let model = selectedModel
        let project = selectedProject
        let started = ContinuousClock.now
        reloadTask = Task { [weak self] in
            let now = Date()
            let interval = await aggregator.interval(for: range, harnesses: nil, now: now)
            let query = UsageDashboardQuery(
                range: range, interval: interval, harnesses: harnesses, model: model, project: project
            )
            let next = await aggregator.snapshot(query, now: now)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            let applied = ContinuousClock.now
            self.apply(next)
            self.isLoading = false
            if UsageStallProbe.isEnabled {
                // The assignment's main-thread cost: until the run loop is free
                // again, i.e. after SwiftUI's update and the CA commit it drives.
                DispatchQueue.main.async {
                    let milliseconds = (ContinuousClock.now - applied) / .milliseconds(1)
                    FileHandle.standardOutput.write(Data(String(format: "VIBEBAR_USAGE_APPLY silent=%@ ms=%.1f\n", silently ? "true" : "false", milliseconds).utf8))
                }
            }
            if DemoMode.isEnabled {
                // Demo mode is the measuring mode (AGENTS.md § 7): one line
                // per query, filter change to assigned snapshot.
                let milliseconds = Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded())
                FileHandle.standardOutput.write(Data("VIBEBAR_USAGE_TIMING range=\(range.rawValue) harnesses=\(harnesses?.count ?? -1) model=\(model != nil) project=\(project != nil) silent=\(silently) ms=\(milliseconds)\n".utf8))
            }
            await self.warmOtherRanges(model: model, project: project)
        }
    }

    /// Assign only a snapshot that differs from the one on screen: the
    /// background sweep re-reads every few seconds and an identical answer
    /// should not invalidate a single view.
    private func apply(_ next: UsageDashboardSnapshot) {
        var comparable = next
        comparable.generatedAt = snapshot.generatedAt
        if comparable != snapshot || !hasAppliedSnapshot {
            snapshot = next
            hasAppliedSnapshot = true
        }
        lastUpdatedAt = next.generatedAt
        // The request log follows the filters, the window's start and the
        // ledger's revision, and a user refresh; a background re-read that
        // moved none of them leaves the pages already loaded alone.
        let userRefresh = pendingUserRefresh
        pendingUserRefresh = false
        if wantsRequests,
           UsageRequestLogKey.needsReload(loaded: requestKey, next: UsageRequestLogKey(snapshot), userRefresh: userRefresh) {
            loadRequests(reset: true)
        }
    }

    @ObservationIgnored private var hasAppliedSnapshot = false


    /// Read the other ranges' ledger facts after the visible one landed, so
    /// switching range is a cache hit rather than a query.
    private func warmOtherRanges(model: String?, project: String?) async {
        let aggregator = self.aggregator
        let current = range
        let now = Date()
        var queries: [UsageDashboardQuery] = []
        for other in UsageDashboardRange.allCases where other != current {
            let interval = await aggregator.interval(for: other, harnesses: nil, now: now)
            queries.append(UsageDashboardQuery(range: other, interval: interval, model: model, project: project))
        }
        await aggregator.warm(queries)
    }

    /// Re-scan the session index on activation and while the page stays
    /// open, on the Sessions page's terms: at most every ten minutes, one
    /// sweep at a time, behind the maintenance gate
    /// (`SessionIndexRefreshThrottle`). Sessions a CLI wrote since the last
    /// scan would otherwise never reach these cards unless the user opened
    /// Sessions first.
    private func refreshIndexIfDue() async {
        _ = aggregator
        guard let service = indexService,
              await SessionIndexRefreshThrottle.shared.isDue
        else { return }
        let isEmpty = await SessionIndexDashboardSource(service: service).totalSessionCount() == 0
        if isEmpty { isBuildingIndex = true }
        let refreshed = await SessionIndexRefreshThrottle.shared.refreshIfDue {
            await service.refreshIndex()
        }
        isBuildingIndex = false
        guard refreshed, !Task.isCancelled else { return }
        await aggregator.invalidateSessions()
        reload(silently: true)
    }
}
