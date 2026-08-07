import Combine
import Foundation
import VibeBarCore

/// Filter state and query results behind the Workbench's Usage Stats page.
///
/// Every published result is a plain value produced by `UsageEventLedger`,
/// which is an actor: the queries run on its executor and only the finished
/// snapshot is assigned here, so a 30-day scan never blocks a frame.
@MainActor
final class UsageStatsViewModel: ObservableObject {
    /// Range presets deliberately mix two shapes:
    ///
    /// - `today` is the local calendar day so far — midnight → now.
    /// - every `N`-day preset is a *rolling* window of exactly `N × 86400`
    ///   seconds ending now.
    ///
    /// Making the N-day presets calendar-aligned too would collapse "Today"
    /// and "24 h" into the same button for most of the day, and a rolling
    /// 24 h window is also what keeps `UsageTrendBucket.recommended` on
    /// hourly buckets for the shortest preset.
    enum RangePreset: String, CaseIterable, Identifiable {
        case today
        case day1
        case day7
        case day14
        case day30
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today:  "Today"
            case .day1:   "24 h"
            case .day7:   "7 d"
            case .day14:  "14 d"
            case .day30:  "30 d"
            case .custom: "Custom"
            }
        }

        var systemImage: String {
            switch self {
            case .today:  "sun.max"
            case .day1:   "clock"
            case .day7:   "calendar"
            case .day14:  "calendar"
            case .day30:  "calendar"
            case .custom: "calendar.badge.clock"
            }
        }

        /// Seconds of the rolling window, `nil` for the two presets that are
        /// not a fixed span.
        var rollingSpan: TimeInterval? {
            switch self {
            case .today, .custom: nil
            case .day1:  86_400
            case .day7:  7 * 86_400
            case .day14: 14 * 86_400
            case .day30: 30 * 86_400
            }
        }
    }

    enum RefreshInterval: Int, CaseIterable, Identifiable {
        case off = 0
        case fiveSeconds = 5
        case tenSeconds = 10
        case thirtySeconds = 30
        case sixtySeconds = 60

        var id: Int { rawValue }

        var title: String {
            self == .off ? "Off" : "\(rawValue)s"
        }
    }

    // MARK: - Filter state

    @Published var rangePreset: RangePreset = .day7 {
        didSet {
            guard oldValue != rangePreset else { return }
            reload(cascadeModels: false)
        }
    }

    @Published var customStart: Date {
        didSet {
            guard oldValue != customStart, rangePreset == .custom else { return }
            reload(cascadeModels: false)
        }
    }

    @Published var customEnd: Date {
        didSet {
            guard oldValue != customEnd, rangePreset == .custom else { return }
            reload(cascadeModels: false)
        }
    }

    @Published var refreshInterval: RefreshInterval = .off {
        didSet {
            guard oldValue != refreshInterval else { return }
            restartTimer()
        }
    }

    /// `nil` means "every provider". An empty selection is normalized back to
    /// `nil` rather than kept as "match nothing" — a filter bar with no chip
    /// lit should read as unfiltered, not as an empty page.
    @Published private(set) var selectedTools: Set<ToolType>?
    @Published private(set) var selectedModels: Set<String>?

    // MARK: - Results

    @Published private(set) var summary: UsageSummaryMetrics = .empty
    @Published private(set) var trend = UsageTrendSeries(bucket: .day, points: [])
    @Published private(set) var providerStats: [UsageProviderStat] = []
    @Published private(set) var modelStats: [UsageModelStat] = []
    @Published private(set) var requestRows: [UsageRequestRow] = []
    @Published private(set) var requestTotalCount = 0
    @Published private(set) var availableModels: [String] = []
    /// Providers offered as filter chips: the cost-aware set, widened by any
    /// provider the ledger actually has rows for.
    @Published private(set) var knownTools: [ToolType] = ToolType.costAwareProviders
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var lastUpdatedAt: Date?

    let isLedgerAvailable: Bool

    var hasMoreRequests: Bool {
        requestRows.count < requestTotalCount
    }

    var range: DateInterval {
        let now = Date()
        switch rangePreset {
        case .today:
            let start = min(Calendar.current.startOfDay(for: now), now)
            return DateInterval(start: start, end: now)
        case .custom:
            let start = min(customStart, customEnd)
            let end = max(customStart, customEnd)
            return DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
        case .day1, .day7, .day14, .day30:
            let span = rangePreset.rollingSpan ?? 86_400
            return DateInterval(start: now.addingTimeInterval(-span), end: now)
        }
    }

    var filter: UsageQueryFilter {
        UsageQueryFilter(
            range: range,
            tools: selectedTools.map { $0.sorted { $0.rawValue < $1.rawValue } },
            models: selectedModels.map { $0.sorted() }
        )
    }

    var trendBucket: UsageTrendBucket {
        trend.bucket
    }

    // MARK: - Dependencies

    private let ledger: UsageEventLedger?
    private let costService: CostUsageService

    private var reloadTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastCostRefreshAt: Date?
    private var loadedRequestPages = 0
    private var generation: UInt64 = 0
    private var hasLoadedOnce = false
    /// The filter page 0 was fetched with. Later pages reuse it verbatim: a
    /// rolling preset's `now` moves between pages, and re-deriving the range
    /// per page would slide the offsets under the rows already on screen.
    private var activeFilter: UsageQueryFilter?
    /// Providers the ledger has been seen carrying, accumulated across
    /// reloads. Derived from the *filtered* results, so it must only grow —
    /// otherwise narrowing to one provider would retire every other chip and
    /// strand the user with no way back except "All providers".
    private var observedTools: Set<ToolType> = []

    private nonisolated static let requestPageSize = 50
    /// A poll re-reads the ledger every tick, but the ledger only moves when a
    /// cost scan writes to it — and a scan walks the whole session tree. One
    /// rescan a minute is the ceiling regardless of how fast the poll runs.
    private static let costRefreshMinimumInterval: TimeInterval = 60

    init(ledger: UsageEventLedger?, costService: CostUsageService) {
        self.ledger = ledger
        self.costService = costService
        self.isLedgerAvailable = ledger != nil
        let now = Date()
        self.customEnd = now
        self.customStart = now.addingTimeInterval(-7 * 86_400)
    }

    // MARK: - Lifecycle

    /// First load on window open; a re-open re-queries instead of rebuilding,
    /// because the view model outlives the window.
    func activate() {
        restartTimer()
        if hasLoadedOnce {
            reload(cascadeModels: false)
        } else {
            hasLoadedOnce = true
            reload(cascadeModels: true)
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        reloadTask?.cancel()
        reloadTask = nil
    }

    // MARK: - Filter mutation

    func setSelectedTools(_ tools: Set<ToolType>?) {
        let normalized = (tools?.isEmpty ?? true) ? nil : tools
        guard normalized != selectedTools else { return }
        selectedTools = normalized
        reload(cascadeModels: true)
    }

    func toggleTool(_ tool: ToolType) {
        var next = selectedTools ?? Set(knownTools)
        if next.contains(tool) { next.remove(tool) } else { next.insert(tool) }
        // Re-selecting everything is the same statement as "no provider
        // filter", and saying it that way keeps the query unrestricted.
        setSelectedTools(next.count == knownTools.count ? nil : next)
    }

    func setSelectedModels(_ models: Set<String>?) {
        let normalized = (models?.isEmpty ?? true) ? nil : models
        guard normalized != selectedModels else { return }
        selectedModels = normalized
        reload(cascadeModels: false)
    }

    func toggleModel(_ model: String) {
        var next = selectedModels ?? Set(availableModels)
        if next.contains(model) { next.remove(model) } else { next.insert(model) }
        setSelectedModels(next.count == availableModels.count ? nil : next)
    }

    func setCustomRange(start: Date, end: Date) {
        customStart = start
        customEnd = end
    }

    // MARK: - Queries

    func refresh() {
        reload(cascadeModels: true)
    }

    /// Next zero-based page of request rows, appended to what is already on
    /// screen. Pages from a superseded filter are dropped on arrival.
    func loadMoreRequests() {
        guard let ledger, let filter = activeFilter,
              !isLoadingMore, !isLoading, hasMoreRequests
        else { return }
        let generation = self.generation
        let page = loadedRequestPages
        isLoadingMore = true
        Task { [weak self] in
            let result = try? await ledger.requestPage(
                filter, page: page, pageSize: Self.requestPageSize
            )
            guard let self, generation == self.generation else { return }
            self.isLoadingMore = false
            guard let result else { return }
            self.append(result)
        }
    }

    private func reload(cascadeModels: Bool) {
        generation &+= 1
        let generation = self.generation
        reloadTask?.cancel()
        loadedRequestPages = 0
        activeFilter = nil
        // A page still in flight is now for a filter nobody is looking at; it
        // drops itself on the generation check and never clears this, so the
        // reload has to, or paging stays wedged for the rest of the session.
        isLoadingMore = false
        guard let ledger else {
            applyEmpty()
            return
        }
        let tools = filter.tools
        isLoading = true
        reloadTask = Task { [weak self] in
            let models = (try? await ledger.availableModels(tools: tools)) ?? []
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            // Models first: a narrowed provider set can strand a model that no
            // longer exists in the picker, and querying with it would report
            // an empty page the user has no control to clear.
            if cascadeModels {
                self.pruneSelectedModels(to: models)
            }
            self.availableModels = models
            let resolved = self.filter
            let snapshot = await Self.load(ledger: ledger, filter: resolved)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.activeFilter = resolved
            self.apply(snapshot)
        }
    }

    private func pruneSelectedModels(to models: [String]) {
        guard let selectedModels else { return }
        let kept = selectedModels.intersection(models)
        self.selectedModels = kept.isEmpty ? nil : kept
    }

    private func apply(_ snapshot: LoadedUsage) {
        summary = snapshot.summary
        trend = snapshot.trend
        providerStats = snapshot.providers
        modelStats = snapshot.models
        requestRows = snapshot.requests.rows
        requestTotalCount = snapshot.requests.totalCount
        loadedRequestPages = 1
        observedTools.formUnion(snapshot.providers.map(\.tool))
        observedTools.formUnion(selectedTools ?? [])
        knownTools = ToolType.allCases.filter {
            $0.supportsTokenCost || observedTools.contains($0)
        }
        lastUpdatedAt = Date()
        isLoading = false
    }

    private func applyEmpty() {
        summary = .empty
        trend = UsageTrendSeries(bucket: UsageTrendBucket.recommended(for: range), points: [])
        providerStats = []
        modelStats = []
        requestRows = []
        requestTotalCount = 0
        availableModels = []
        isLoading = false
    }

    private func append(_ page: UsageRequestPage) {
        guard page.page == loadedRequestPages else { return }
        let known = Set(requestRows.map(\.id))
        requestRows.append(contentsOf: page.rows.filter { !known.contains($0.id) })
        requestTotalCount = page.totalCount
        loadedRequestPages = page.page + 1
    }

    // MARK: - Polling

    private func restartTimer() {
        tickTask?.cancel()
        let seconds = refreshInterval.rawValue
        guard seconds > 0 else {
            tickTask = nil
            return
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        let now = Date()
        let due = lastCostRefreshAt.map { now.timeIntervalSince($0) >= Self.costRefreshMinimumInterval }
        if due ?? true {
            lastCostRefreshAt = now
            await costService.refreshAll()
        }
        reload(cascadeModels: false)
    }

    // MARK: - Off-main load

    private struct LoadedUsage: Sendable {
        let summary: UsageSummaryMetrics
        let trend: UsageTrendSeries
        let providers: [UsageProviderStat]
        let models: [UsageModelStat]
        let requests: UsageRequestPage
    }

    private nonisolated static func load(
        ledger: UsageEventLedger,
        filter: UsageQueryFilter
    ) async -> LoadedUsage {
        let summary = (try? await ledger.summary(filter)) ?? .empty
        let trend = (try? await ledger.trend(filter))
            ?? UsageTrendSeries(bucket: UsageTrendBucket.recommended(for: filter.range), points: [])
        let providers = (try? await ledger.providerStats(filter)) ?? []
        let models = (try? await ledger.modelStats(filter)) ?? []
        let requests = (try? await ledger.requestPage(filter, page: 0, pageSize: requestPageSize))
            ?? UsageRequestPage(rows: [], totalCount: 0, page: 0, pageSize: requestPageSize)
        return LoadedUsage(
            summary: summary,
            trend: trend,
            providers: providers,
            models: models,
            requests: requests
        )
    }
}
