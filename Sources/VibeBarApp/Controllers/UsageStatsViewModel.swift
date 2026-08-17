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
    /// - `24 h` is a rolling window ending now;
    /// - every multi-day preset is aligned to local calendar days, matching
    ///   `CostSnapshot.last7Days*` / `last30Days*` everywhere else in Vibe Bar.
    ///
    /// Keeping only `24 h` rolling preserves an hourly comparison without
    /// creating a second, contradictory definition of "7 days" inside the
    /// same app.
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

        var calendarDayCount: Int? {
            switch self {
            case .day7: 7
            case .day14: 14
            case .day30: 30
            case .today, .day1, .custom: nil
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
            windowStart = nil
            reload(cascadeModels: false)
        }
    }

    @Published var customStart: Date {
        didSet {
            guard oldValue != customStart, rangePreset == .custom else { return }
            windowStart = nil
            reload(cascadeModels: false)
        }
    }

    @Published var customEnd: Date {
        didSet {
            guard oldValue != customEnd, rangePreset == .custom else { return }
            windowStart = nil
            reload(cascadeModels: false)
        }
    }

    /// This changes the ledger query's grouping, not just the chart label.
    @Published var trendGranularity: UsageTrendGranularity = .automatic {
        didSet {
            guard oldValue != trendGranularity else { return }
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

    /// One publication for the query's mutually consistent result set. The
    /// old six independent `@Published` writes made SwiftUI rebuild the whole
    /// Workbench analytics tree six times after a 30-day query, even though
    /// every value came from the same ledger snapshot.
    @Published private var results = UsageResults.empty
    var summary: UsageSummaryMetrics { results.summary }
    var trend: UsageTrendSeries { results.trend }
    var providerStats: [UsageProviderStat] { results.providerStats }
    var modelStats: [UsageModelStat] { results.modelStats }
    var requestRows: [UsageRequestRow] { results.requestRows }
    var requestTotalCount: Int { results.requestTotalCount }
    @Published private(set) var availableModels: [String] = []
    /// Providers offered as filter chips: the cost-aware set, widened by any
    /// provider the ledger actually has rows for.
    @Published private(set) var knownTools: [ToolType] = ToolType.usageStatsProviders
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var lastUpdatedAt: Date?
    /// True only when the current filter lies wholly above every selected
    /// provider's ledger detail floor. This drives the Hourly menu state and
    /// is refreshed alongside the query it describes.
    @Published private(set) var isHourlyTrendAvailable = true

    let isLedgerAvailable: Bool

    var hasMoreRequests: Bool {
        requestRows.count < requestTotalCount
    }

    var range: DateInterval {
        windowStart.map(anchoredRange(start:)) ?? currentRange
    }

    var canNavigateForward: Bool { windowStart != nil }

    /// Manual buckets stay available only while they remain a useful
    /// interactive chart. The renderer also thins marks, but avoiding a huge
    /// zero-filled provider matrix here keeps a years-long custom range from
    /// allocating tens of thousands of points before drawing even begins.
    func isTrendGranularityAvailable(_ granularity: UsageTrendGranularity) -> Bool {
        guard granularity != .automatic else { return true }
        if granularity == .hour, !isHourlyTrendAvailable { return false }
        let seconds: TimeInterval = switch granularity {
        case .automatic: 1
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        }
        return Int(ceil(range.duration / seconds)) + 1 <= Self.maximumInteractiveTrendBuckets
    }

    private var currentRange: DateInterval {
        let now = Date()
        switch rangePreset {
        case .today:
            let start = min(Calendar.current.startOfDay(for: now), now)
            return DateInterval(start: start, end: now)
        case .custom:
            let start = min(customStart, customEnd)
            let end = max(customStart, customEnd)
            return DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
        case .day1:
            return DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        case .day7, .day14, .day30:
            let days = rangePreset.calendarDayCount ?? 1
            let today = Calendar.current.startOfDay(for: now)
            let start = Calendar.current.date(
                byAdding: .day,
                value: -(days - 1),
                to: today
            ) ?? today
            return DateInterval(start: start, end: now)
        }
    }

    func navigateWindow(by direction: Int) {
        guard direction == -1 || direction == 1 else { return }
        let present = currentRange
        let candidate = shiftedStart(range.start, by: direction)
        if direction > 0, candidate >= present.start {
            resetWindow()
        } else {
            windowStart = candidate
            reload(cascadeModels: false)
        }
    }

    func resetWindow() {
        guard windowStart != nil else { return }
        windowStart = nil
        reload(cascadeModels: false)
    }

    private func anchoredRange(start: Date) -> DateInterval {
        switch rangePreset {
        case .today:
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86_400)
            return DateInterval(start: start, end: end)
        case .day1:
            return DateInterval(start: start, duration: 86_400)
        case .day7, .day14, .day30:
            let days = rangePreset.calendarDayCount ?? 1
            let end = Calendar.current.date(byAdding: .day, value: days, to: start)
                ?? start.addingTimeInterval(TimeInterval(days * 86_400))
            return DateInterval(start: start, end: end)
        case .custom:
            return DateInterval(start: start, duration: max(60, currentRange.duration))
        }
    }

    private func shiftedStart(_ start: Date, by direction: Int) -> Date {
        switch rangePreset {
        case .today:
            return Calendar.current.date(byAdding: .day, value: direction, to: start)
                ?? start.addingTimeInterval(TimeInterval(direction * 86_400))
        case .day1:
            return start.addingTimeInterval(TimeInterval(direction * 86_400))
        case .day7, .day14, .day30:
            let days = (rangePreset.calendarDayCount ?? 1) * direction
            return Calendar.current.date(byAdding: .day, value: days, to: start)
                ?? start.addingTimeInterval(TimeInterval(days * 86_400))
        case .custom:
            return start.addingTimeInterval(currentRange.duration * Double(direction))
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
    /// A historical window start, or `nil` when the preset follows now.
    private var windowStart: Date?
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
    private static let maximumInteractiveTrendBuckets = 1_200
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
        if !isTrendGranularityAvailable(trendGranularity) {
            trendGranularity = .automatic
            return
        }
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
            guard let self else { return }
            // Model availability depends on the provider filter, not the time
            // range. Re-query it only when that filter cascades; changing 7 d
            // to 30 d should go straight to the range queries instead of
            // scanning the ledger's full model index first.
            let models: [String]
            if cascadeModels || self.availableModels.isEmpty {
                models = (try? await ledger.availableModels(tools: tools)) ?? []
            } else {
                models = self.availableModels
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            // Models first: a narrowed provider set can strand a model that no
            // longer exists in the picker, and querying with it would report
            // an empty page the user has no control to clear.
            if cascadeModels {
                self.pruneSelectedModels(to: models)
            }
            self.availableModels = models
            let resolved = self.filter
            let supportsHourly = (try? await ledger.supportsHourlyTrend(resolved)) ?? false
            guard !Task.isCancelled, generation == self.generation else { return }
            self.isHourlyTrendAvailable = supportsHourly
            if self.trendGranularity == .hour, !supportsHourly {
                // Keep the Picker's intent and the returned series aligned.
                // `trend` also falls back defensively in case the floor moves
                // between this check and the subsequent query.
                self.trendGranularity = .automatic
                return
            }
            let granularity = self.trendGranularity
            let snapshot = await Self.load(
                ledger: ledger, filter: resolved, granularity: granularity
            )
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
        results = UsageResults(
            summary: snapshot.summary,
            trend: snapshot.trend,
            providerStats: snapshot.providers,
            modelStats: snapshot.models,
            requestRows: snapshot.requests.rows,
            requestTotalCount: snapshot.requests.totalCount
        )
        loadedRequestPages = 1
        observedTools.formUnion(snapshot.providers.map(\.tool))
        observedTools.formUnion(selectedTools ?? [])
        knownTools = ToolType.allCases.filter {
            ToolType.usageStatsProviders.contains($0) || observedTools.contains($0)
        }
        lastUpdatedAt = Date()
        isLoading = false
    }

    private func applyEmpty() {
        results = UsageResults(
            summary: .empty,
            trend: UsageTrendSeries(
                bucket: trendGranularity.resolved(for: range), points: []
            ),
            providerStats: [],
            modelStats: [],
            requestRows: [],
            requestTotalCount: 0
        )
        availableModels = []
        isLoading = false
    }

    private func append(_ page: UsageRequestPage) {
        guard page.page == loadedRequestPages else { return }
        let known = Set(requestRows.map(\.id))
        var updated = results
        updated.requestRows.append(contentsOf: page.rows.filter { !known.contains($0.id) })
        updated.requestTotalCount = page.totalCount
        results = updated
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

    private struct UsageResults {
        var summary: UsageSummaryMetrics
        var trend: UsageTrendSeries
        var providerStats: [UsageProviderStat]
        var modelStats: [UsageModelStat]
        var requestRows: [UsageRequestRow]
        var requestTotalCount: Int

        static let empty = UsageResults(
            summary: .empty,
            trend: UsageTrendSeries(bucket: .day, points: []),
            providerStats: [],
            modelStats: [],
            requestRows: [],
            requestTotalCount: 0
        )
    }

    private nonisolated static func load(
        ledger: UsageEventLedger,
        filter: UsageQueryFilter,
        granularity: UsageTrendGranularity
    ) async -> LoadedUsage {
        let summary = (try? await ledger.summary(filter)) ?? .empty
        let bucket = granularity.resolved(for: filter.range)
        let trend = (try? await ledger.trend(filter, bucket: bucket))
            ?? UsageTrendSeries(bucket: bucket, points: [])
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
