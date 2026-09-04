import Combine
import Foundation
import VibeBarCore

/// State behind the Workbench's Sessions page.
///
/// Reads come from two places and are deliberately not merged: the SQLite
/// index answers "what sessions exist" instantly from the last scan, and the
/// provider adapters answer "what does this one say" only when a row is
/// selected. Nothing here parses a transcript to draw a list.
@MainActor
final class SessionManagerModel: ObservableObject {
    // MARK: - Filter vocabulary

    enum DateRange: String, CaseIterable, Identifiable {
        case all
        case today
        case week
        case month

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:   L10n.Workbench.Sessions.Range.all
            case .today: L10n.Cost.Timeframe.today
            case .week:  L10n.Cost.Timeframe.week
            case .month: L10n.Cost.Timeframe.month
            }
        }

        var systemImage: String {
            switch self {
            case .all:   "infinity"
            case .today: "sun.max"
            case .week:  "calendar"
            case .month: "calendar"
            }
        }

        /// Start of the window, or `nil` for "no lower bound".
        func start(now: Date = Date()) -> Date? {
            switch self {
            case .all:   nil
            case .today: Calendar.current.startOfDay(for: now)
            case .week:  now.addingTimeInterval(-7 * 86_400)
            case .month: now.addingTimeInterval(-30 * 86_400)
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case recentFirst
        case oldestFirst
        case byProject

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recentFirst: L10n.Workbench.Sessions.Sort.recentFirst
            case .oldestFirst: L10n.Workbench.Sessions.Sort.oldestFirst
            case .byProject:   L10n.Workbench.Sessions.Sort.byProject
            }
        }

        var systemImage: String {
            switch self {
            case .recentFirst: "arrow.down"
            case .oldestFirst: "arrow.up"
            case .byProject:   "folder"
            }
        }
    }

    /// One list row: a session, plus where a full-text hit landed in it.
    struct Row: Identifiable, Hashable, Sendable {
        let summary: SessionSummary
        let snippet: String?
        let matchedSeq: Int?
        let matchedRelated: SessionSummary?
        let reviewCount: Int

        var id: String { summary.id }
    }

    /// Which project a list row groups under.
    ///
    /// The bucket is carried as data rather than as a finished heading. A
    /// pre-translated title stored in `groupedRows` would outlive a language
    /// change: nothing about the data moves when the user picks another
    /// language, so the old wording would sit in the headings until the next
    /// scan. `.named` holds the directory's own last component, which is not
    /// copy and is never translated.
    enum ProjectBucket: Hashable, Sendable {
        case named(String)
        case noProject
        case projectless

        var id: String {
            switch self {
            case let .named(name): "d:\(name)"
            case .noProject:       "n:"
            case .projectless:     "p:"
            }
        }

        var title: String {
            switch self {
            case let .named(name): name
            case .noProject:       L10n.Workbench.Sessions.Project.none
            case .projectless:     L10n.Workbench.Sessions.Project.projectless
            }
        }
    }

    struct ProjectGroup: Identifiable, Sendable {
        let project: ProjectBucket
        let rows: [Row]

        var id: String { project.id }
        var title: String { project.title }
    }

    /// Why the open transcript stops where it does.
    ///
    /// Present only when the viewer read a head window instead of the whole
    /// file. The kit's adapters materialize every message before applying
    /// `range:`, so the bound has to be in bytes and it has to be applied
    /// before the parse — which means the reader genuinely does not know how
    /// many messages the rest of the file holds.
    struct TranscriptTruncation: Equatable, Sendable {
        let shownMessages: Int
        let parsedBytes: Int64
        let fileBytes: Int64
    }

    // MARK: - Published state

    @Published private(set) var summaries: [SessionSummary] = [] {
        didSet { refreshRows() }
    }
    @Published private(set) var hits: [SessionSearchHit] = [] {
        didSet { refreshRows() }
    }
    /// Rows the whole index finds by label — title, id, project folder,
    /// harness, company — for the current search, beyond the page the list
    /// has loaded. The loaded page is filtered in memory on every keystroke;
    /// this is what makes an older session findable by the same fields.
    @Published private(set) var labelHits: [SessionSummary] = [] {
        didSet { refreshRows() }
    }
    @Published private(set) var indexProgress: IndexProgress?
    @Published private(set) var isIndexAvailable = true

    /// Derived once per input change rather than per render: the list is
    /// read from three views on the page, and re-sorting a few thousand
    /// sessions inside `body` is how a keystroke starts costing frames.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var groupedRows: [ProjectGroup] = []
    @Published private(set) var harnessCounts: [Harness: Int] = [:]
    @Published private(set) var totalSessionCount = 0
    @Published private(set) var isLoadingSummaries = false
    /// A rows build is in flight. The derivation moved off the main actor, so
    /// there is now a turn between "summaries arrived" and "rows published" —
    /// and an empty list during that turn is not the same thing as "nothing
    /// matches".
    @Published private(set) var isPreparingRows = false

    @Published var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearch()
            // Debounced: a keystroke used to re-filter, re-sort and re-group
            // every loaded summary synchronously on the main actor before the
            // character it typed was drawn.
            refreshRows(debounced: true)
        }
    }
    @Published var searchScopes = SessionSearchScope.defaultScopes {
        didSet {
            guard oldValue != searchScopes else { return }
            rerunSearch()
            refreshRows()
        }
    }
    @Published var directoryIncludeText = "" {
        didSet { scheduleDirectoryFilter() }
    }
    @Published var directoryExcludeText = "" {
        didSet { scheduleDirectoryFilter() }
    }

    /// Which harnesses the list is narrowed to: `nil` for all of them, `[]`
    /// for none — see `HarnessSelection`, which owns the chip arithmetic.
    ///
    /// The filter axis is the harness rather than the `SessionProvider`,
    /// because a Codex rollout tree holds both Codex and ChatGPT Work
    /// sessions and only the harness stamp tells them apart (AGENTS.md
    /// § 7.1).
    @Published var harnessFilter: Set<Harness>? {
        didSet {
            reloadSummaryPage(reset: true)
            rerunSearch()
            refreshRows()
        }
    }
    @Published var dateRange: DateRange = .all {
        didSet {
            reloadSummaryPage(reset: true)
            refreshRows()
        }
    }
    @Published var sortOrder: SortOrder = .recentFirst {
        didSet { reloadSummaryPage(reset: true) }
    }
    @Published var groupByProject = false {
        didSet { refreshRows() }
    }

    @Published private(set) var selection: SessionSummary?
    /// Message the transcript should open on, when the row was picked out of
    /// a full-text result. Cleared by the pane once it has scrolled.
    @Published private(set) var focusSeq: Int?
    @Published private(set) var transcript: TranscriptDocument?
    @Published private(set) var transcriptError: String?
    @Published private(set) var isLoadingTranscript = false
    /// Non-nil while the open transcript is a head window of a larger file.
    @Published private(set) var transcriptTruncation: TranscriptTruncation?

    @Published var isDeleteMode = false {
        didSet {
            guard !isDeleteMode else { return }
            checkedIDs.removeAll()
        }
    }
    @Published var checkedIDs: Set<String> = []
    @Published private(set) var pendingDeletion: [SessionSummary]?
    @Published private(set) var toast: String?

    struct IndexProgress: Equatable {
        let done: Int
        let total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(done) / Double(total))
        }
    }

    // MARK: - Dependencies

    private let settingsStore: SettingsStore
    private let homeDirectory: String
    private let registry: SessionProviderRegistry
    private let deleter: SessionDeleter
    private let index: SharedSessionIndex

    private var store: SessionIndexStore? { index.store }
    private var service: SessionIndexService? { index.service }

    private var searchTask: Task<Void, Never>?
    private var directoryFilterTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var rowsTask: Task<Void, Never>?
    /// The parse behind the open transcript. Held so a second click cancels
    /// the first: three 1 GB sessions in a row used to mean three concurrent
    /// full parses, of which two were discarded on arrival by a generation
    /// check that had already let them allocate everything.
    private var transcriptTask: Task<Void, Never>?
    private var transcriptGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var summaryGeneration: UInt64 = 0
    private var lastScanFinishedAt: Date?
    private var reviewSummariesByParent: [String: [SessionSummary]] = [:]
    private var relatedHitByParent: [String: SessionSummary] = [:]
    /// Bumped whenever the index's contents can have moved (a completed
    /// refresh, a rebuild, a delete). Everything derived from a whole-index
    /// query — the review children and the harness chip counts — is fetched
    /// once per value of this rather than on every filter change.
    private var indexGeneration: UInt64 = 0
    private var indexDerivedGeneration: UInt64?
    /// Parent rows already resolved for auto-review hits, valid for one
    /// `indexGeneration`.
    private var parentSummaryCache: [String: SessionSummary] = [:]

    /// Floor between two activation sweeps.
    ///
    /// This used to be 30 seconds, which made every Workbench tab click cost
    /// a full walk of every provider's session tree — 11 000 files on a busy
    /// Mac. Re-opening the window after a while still rescans (the CLIs were
    /// writing the whole time it was shut); moving between pages does not.
    /// The Refresh button ignores this entirely.
    private static let rescanMinimumInterval: TimeInterval = 10 * 60

    /// Long enough that a fast typist never pays for an intermediate query,
    /// short enough that pausing to read the list feels like it already ran.
    private static let searchDebounce = Duration.milliseconds(250)
    /// The label scan walks the index in these pages and stops at this many
    /// matches — the same ceiling the full-text search has.
    private nonisolated static let labelScanPageSize = 1_000
    private nonisolated static let labelHitLimit = 200
    /// The index reports per file; publishing every one of those would put
    /// thousands of main-actor hops between the user and a scroll.
    private nonisolated static let progressStride = 250
    private static let summaryPageSize = 250
    /// Ceiling on how many summaries the page keeps loaded.
    ///
    /// The list is a `LazyVStack`, which builds rows lazily but never
    /// releases them, so "scroll to the bottom of 11 000 sessions" is a
    /// promise to hold 11 000 built rows — each with its own hover state and
    /// up to four `.help()` strings. Eight pages is more than anyone reads in
    /// one sitting, and the filters and full-text search are the way to reach
    /// the rest.
    static let maximumLoadedSummaries = 2_000

    var hasMoreSummaries: Bool {
        summaries.count < min(totalSessionCount, Self.maximumLoadedSummaries)
    }

    /// True when the list stops short of the index because of the ceiling
    /// above rather than because that is all there is.
    var isSummaryListCapped: Bool {
        totalSessionCount > Self.maximumLoadedSummaries
            && summaries.count >= Self.maximumLoadedSummaries
    }

    init(
        settingsStore: SettingsStore,
        index: SharedSessionIndex,
        homeDirectory: String = RealHomeDirectory.path
    ) {
        self.settingsStore = settingsStore
        self.homeDirectory = homeDirectory
        // The raw registry, deliberately: the transcript viewer and the
        // deleter must see whole sessions. The *indexing* registry is the
        // bounded one and lives on `SharedSessionIndex`.
        self.registry = SessionProviderRegistry.standard(homeDirectory: homeDirectory)
        self.deleter = SessionDeleter(homeDirectory: homeDirectory)
        self.index = index
        self.isIndexAvailable = index.store != nil
    }

    // MARK: - Lifecycle

    /// Cached rows first, disk second — and the two are never sequenced.
    ///
    /// The summary query answers from the last scan and paints immediately;
    /// the scan, when one is due at all, runs behind it and re-queries when
    /// it lands. Re-opening the window after a while re-scans, since the CLIs
    /// have been writing sessions the whole time it was shut, but switching
    /// between Workbench pages must not.
    func activate() {
        reloadSummaryPage(reset: true)
        guard refreshTask == nil else { return }
        if let last = lastScanFinishedAt, Date().timeIntervalSince(last) < Self.rescanMinimumInterval {
            return
        }
        refreshIndex()
    }

    /// Wind down everything this page has in flight.
    ///
    /// Cancelling the tasks is only half of it: each of them owns a piece of
    /// published "…in progress" state that its completion path would have
    /// cleared, and a cancelled task never reaches that path. Leaving them
    /// set is what would make a reopened Workbench sit on "Reading the
    /// session log…" or a permanent scan bar for a task that no longer
    /// exists, until the user happened to click something.
    func stop() {
        searchTask?.cancel()
        directoryFilterTask?.cancel()
        refreshTask?.cancel()
        toastTask?.cancel()
        rowsTask?.cancel()
        cancelTranscriptParse()
        searchTask = nil
        directoryFilterTask = nil
        refreshTask = nil
        toastTask = nil
        rowsTask = nil

        isLoadingTranscript = false
        isPreparingRows = false
        isLoadingSummaries = false
        indexProgress = nil
    }

    // MARK: - Index

    func refreshIndex() {
        guard let service else { return }
        refreshTask?.cancel()
        indexProgress = IndexProgress(done: 0, total: 0)
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard done == total || done % Self.progressStride == 0 else { return }
            guard let self else { return }
            Task { @MainActor in
                self.indexProgress = IndexProgress(done: done, total: total)
            }
        }
        refreshTask = Task { [weak self] in
            // Wait out a compaction pass rather than fighting it for the
            // write lock; `SessionIndexMaintenanceGate` explains the split.
            // The wait is cancellable, and it claims nothing when it throws,
            // so the closing Workbench does not leave the gate held.
            let gate = SessionIndexMaintenanceGate.shared
            do {
                try await gate.acquire()
            } catch {
                await MainActor.run { self?.indexProgress = nil }
                return
            }
            // Cancelled while queued: hand the gate straight back rather than
            // starting an 11 000-file sweep for a window that is closing.
            guard !Task.isCancelled else {
                await gate.release()
                await MainActor.run { self?.indexProgress = nil }
                return
            }
            await service.refreshIndex(progress: progress)
            await gate.release()
            guard let self, !Task.isCancelled else { return }
            self.indexProgress = nil
            self.refreshTask = nil
            self.lastScanFinishedAt = Date()
            self.invalidateIndexDerivedState()
            self.reloadSummaryPage(reset: true)
            self.rerunSearch()
            // A refresh is when churn lands in the index, so it is the
            // natural moment to ask for maintenance. The compactor
            // throttles itself; most calls return without touching SQLite.
            Task.detached(priority: .utility) {
                await SessionIndexCompactor.standard.compactIfDue()
            }
        }
    }

    /// Everything derived from a whole-index query is stale now.
    private func invalidateIndexDerivedState() {
        indexGeneration &+= 1
        parentSummaryCache.removeAll(keepingCapacity: true)
    }

    /// Throw the index away and rebuild it from disk. The escape hatch for a
    /// stale or half-written database — nothing here touches a session file.
    func rebuildIndex() {
        guard let store else { return }
        refreshTask?.cancel()
        indexProgress = IndexProgress(done: 0, total: 0)
        Task { [weak self] in
            let cleared = (try? await store.eraseAll()) != nil
            guard let self else { return }
            if !cleared { self.show(toast: L10n.Workbench.Sessions.Toast.indexNotCleared) }
            self.invalidateIndexDerivedState()
            self.summaries = []
            self.hits = []
            self.labelHits = []
            self.totalSessionCount = 0
            self.refreshIndex()
        }
    }

    func loadMoreSummaries() {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hasMoreSummaries,
              !isLoadingSummaries
        else { return }
        reloadSummaryPage(reset: false)
    }

    private func reloadSummaryPage(reset: Bool) {
        guard let service else { return }
        summaryGeneration &+= 1
        let generation = summaryGeneration
        // No harness selected queries nothing. Asking the index for an empty
        // harness list would be reading its "no filter" convention as the
        // opposite of what the user just said.
        if HarnessSelection.isNothing(harnessFilter) {
            summaries = []
            isLoadingSummaries = false
            reconcileSelection()
            return
        }
        let offset = reset ? 0 : summaries.count
        let harnesses = harnessFilter.map { Array($0).sorted { $0.rawValue < $1.rawValue } }
        let since = dateRange.start()
        let order = summaryOrder
        // Chip counts and the Auto Review children are whole-index facts:
        // they do not depend on the harness, date, sort or directory filter
        // that triggered this reload. Re-asking for up to 2 000 review
        // summaries on every chip click was the page's most expensive habit.
        let currentIndexGeneration = indexGeneration
        let needsIndexDerived = reset && indexDerivedGeneration != currentIndexGeneration
        let includes = directoryIncludes
        let excludes = directoryExcludes
        isLoadingSummaries = true
        Task { [weak self] in
            let page = try? await service.summaryPage(
                harnesses: harnesses,
                since: since,
                projectIncludes: includes,
                projectExcludes: excludes,
                excludingProviderVariantPrefix: CodexSessionAdapter.autoReviewVariantPrefix,
                order: order,
                offset: offset,
                limit: Self.summaryPageSize
            )
            let counts = needsIndexDerived ? (try? await service.harnessCounts()) : nil
            let reviews = needsIndexDerived ? (try? await service.summaries(
                provider: .codex,
                providerVariantPrefix: CodexSessionAdapter.autoReviewVariantPrefix
            )) : nil
            guard let self, generation == self.summaryGeneration else { return }
            if needsIndexDerived, counts != nil || reviews != nil {
                self.indexDerivedGeneration = currentIndexGeneration
            }
            self.isLoadingSummaries = false
            guard let page else { return }
            if reset {
                self.summaries = Array(page.summaries.prefix(Self.maximumLoadedSummaries))
            } else {
                let existing = Set(self.summaries.map(\.id))
                let room = max(0, Self.maximumLoadedSummaries - self.summaries.count)
                self.summaries.append(contentsOf: page.summaries
                    .filter { !existing.contains($0.id) }
                    .prefix(room))
            }
            self.totalSessionCount = page.totalCount
            // A demo launch opens the newest session so the transcript pane
            // is populated in a capture; a real launch leaves the choice to
            // the user.
            if DemoMode.isEnabled, self.selection == nil, let first = page.summaries.first {
                self.select(first)
            }
            if var counts {
                for review in reviews ?? [] {
                    let harness = review.effectiveHarness
                    counts[harness] = max(0, (counts[harness] ?? 0) - 1)
                }
                self.harnessCounts = counts
            }
            if let reviews {
                self.reviewSummariesByParent = Dictionary(grouping: reviews) {
                    CodexSessionAdapter.autoReviewParentSessionID(providerVariant: $0.providerVariant) ?? ""
                }
                self.reviewSummariesByParent.removeValue(forKey: "")
                self.refreshRows()
            }
            self.reconcileSelection()
        }
    }

    /// A rebuild or a delete can retire the selected row; keep the transcript
    /// pane pointed at something that still exists.
    private func reconcileSelection() {
        guard let selection else { return }
        guard !summaries.contains(where: { $0.id == selection.id }) else { return }
        select(nil)
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            relatedHitByParent = [:]
            hits = []
            labelHits = []
            return
        }
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            await self?.runSearch(needle, generation: generation)
        }
    }

    private func rerunSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scheduleSearch()
    }

    private func runSearch(_ needle: String, generation: UInt64) async {
        guard let service else { return }
        guard !HarnessSelection.isNothing(harnessFilter) else {
            if generation == searchGeneration {
                hits = []
                labelHits = []
            }
            return
        }
        let harnesses = harnessFilter.map { Array($0).sorted { $0.rawValue < $1.rawValue } }
        // Two passes over the index at once: what was said inside sessions,
        // and what the rows are labelled with. The index only searches text
        // it has tokenised (titles and messages), so folder, harness and
        // company matches come from walking its summaries.
        async let fullText = service.search(
            needle,
            harnesses: harnesses,
            // Titles are always in: the scope menu offers only message roles.
            scopes: searchScopes.union([.title]),
            projectIncludes: directoryIncludes,
            projectExcludes: directoryExcludes,
            limit: Self.labelHitLimit
        )
        async let labels = Self.scanLabels(
            service: service,
            needle: needle,
            harnesses: harnesses,
            since: dateRange.start(),
            projectIncludes: directoryIncludes,
            projectExcludes: directoryExcludes,
            order: summaryOrder
        )
        let found = (try? await fullText) ?? []
        let labelled = await labels
        guard generation == searchGeneration else { return }
        labelHits = labelled

        // Resolve every Auto Review child to its parent in one hop.
        //
        // This used to be one `await service.summary(...)` per hit inside the
        // loop: up to 200 main-actor → index-actor → main-actor round trips
        // for a single search, most of them asking for a parent the last hit
        // had already fetched. agent-session-kit 0.7.0 has no `IN`-list
        // lookup (`summaries(provider:)` only takes a variant prefix), so the
        // batching is host-side: dedupe the ids, answer what the loaded page
        // and the per-generation cache already know, and ask the index only
        // for the remainder — from a single detached task, so the main actor
        // is entered once rather than 200 times.
        var wanted: [String] = []
        var seenWanted: Set<String> = []
        for hit in found {
            guard let parentID = CodexSessionAdapter.autoReviewParentSessionID(
                providerVariant: hit.summary.providerVariant
            ) else { continue }
            guard parentSummaryCache[parentID] == nil, seenWanted.insert(parentID).inserted else {
                continue
            }
            wanted.append(parentID)
        }
        if !wanted.isEmpty {
            let fetched = await Self.resolveParentSummaries(service: service, sessionIDs: wanted)
            guard generation == searchGeneration else { return }
            parentSummaryCache.merge(fetched) { _, new in new }
        }

        var resolved: [SessionSearchHit] = []
        var seen: Set<String> = []
        var relatedHits: [String: SessionSummary] = [:]
        for hit in found {
            if let parentID = CodexSessionAdapter.autoReviewParentSessionID(
                providerVariant: hit.summary.providerVariant
            ), let parent = parentSummaryCache[parentID] {
                guard seen.insert(parent.id).inserted else { continue }
                relatedHits[parent.id] = hit.summary
                resolved.append(SessionSearchHit(
                    summary: parent,
                    snippet: hit.snippet,
                    matchedSeq: hit.matchedSeq
                ))
            } else {
                guard seen.insert(hit.summary.id).inserted else { continue }
                resolved.append(hit)
            }
        }
        guard generation == searchGeneration else { return }
        relatedHitByParent = relatedHits
        hits = resolved
    }

    private var summaryOrder: SessionSummaryOrder {
        switch sortOrder {
        case .recentFirst: .recentFirst
        case .oldestFirst: .oldestFirst
        case .byProject: .byProject
        }
    }

    /// Walks the index's summaries, under the same filters and order as the
    /// list, and keeps the ones `matches` finds — so a session older than the
    /// loaded page is still found by its folder or harness. Detached, because
    /// a needle that matches nothing reads every summary there is; the pages
    /// are large so that is a dozen round trips, not fifty.
    private nonisolated static func scanLabels(
        service: SessionIndexService,
        needle: String,
        harnesses: [Harness]?,
        since: Date?,
        projectIncludes: [String],
        projectExcludes: [String],
        order: SessionSummaryOrder
    ) async -> [SessionSummary] {
        await Task.detached(priority: .userInitiated) {
            var out: [SessionSummary] = []
            var offset = 0
            while out.count < labelHitLimit, !Task.isCancelled {
                guard let page = try? await service.summaryPage(
                    harnesses: harnesses,
                    since: since,
                    projectIncludes: projectIncludes,
                    projectExcludes: projectExcludes,
                    excludingProviderVariantPrefix: CodexSessionAdapter.autoReviewVariantPrefix,
                    order: order,
                    offset: offset,
                    limit: labelScanPageSize
                ) else { break }
                for summary in page.summaries where matches(summary, needle: needle) {
                    out.append(summary)
                    if out.count >= labelHitLimit { break }
                }
                offset += page.summaries.count
                if page.summaries.isEmpty || offset >= page.totalCount { break }
            }
            return out
        }.value
    }

    /// One detached pass over the deduped parent ids. Cancellation is checked
    /// per id so an abandoned search stops paying immediately.
    private nonisolated static func resolveParentSummaries(
        service: SessionIndexService,
        sessionIDs: [String]
    ) async -> [String: SessionSummary] {
        await Task.detached(priority: .userInitiated) {
            var out: [String: SessionSummary] = [:]
            for sessionID in sessionIDs {
                guard !Task.isCancelled else { return out }
                if let parent = try? await service.summary(provider: .codex, sessionID: sessionID) {
                    out[sessionID] = parent
                }
            }
            return out
        }.value
    }

    private func scheduleDirectoryFilter() {
        directoryFilterTask?.cancel()
        directoryFilterTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard let self, !Task.isCancelled else { return }
            self.reloadSummaryPage(reset: true)
            self.rerunSearch()
        }
    }

    private var directoryIncludes: [String] { Self.pathTerms(directoryIncludeText) }
    private var directoryExcludes: [String] { Self.pathTerms(directoryExcludeText) }

    private static func pathTerms(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == ";" || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Rows

    /// What the list shows.
    ///
    /// The in-memory filter runs on every keystroke so typing never waits on
    /// SQLite; the debounced full-text pass replaces it once it lands, because
    /// only that one can match on what was said inside a session. An empty
    /// full-text result falls back rather than blanking the list — the
    /// substring filter also matches session ids, which the index does not.
    private func refreshRows(debounced: Bool = false) {
        rowsTask?.cancel()
        let input = RowInput(
            summaries: summaries,
            hits: hits,
            labelHits: labelHits,
            relatedHitByParent: relatedHitByParent,
            reviewCounts: reviewSummariesByParent.reduce(into: [String: Int]()) {
                $0[$1.key] = $1.value.count
            },
            needle: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: searchScopes,
            harnessFilter: harnessFilter,
            since: dateRange.start(),
            sortOrder: sortOrder,
            groupByProject: groupByProject
        )
        isPreparingRows = true
        rowsTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.searchDebounce)
                guard !Task.isCancelled else { return }
            }
            let output = await Self.buildRows(input)
            guard let self, !Task.isCancelled else { return }
            self.rows = output.rows
            self.groupedRows = output.groupedRows
            self.isPreparingRows = false
        }
    }

    /// Everything `buildRows` needs, copied so it can run away from the main
    /// actor. Value types throughout: the alternative is reading `@Published`
    /// state from another executor while SwiftUI is drawing from it.
    private struct RowInput: Sendable {
        let summaries: [SessionSummary]
        let hits: [SessionSearchHit]
        let labelHits: [SessionSummary]
        let relatedHitByParent: [String: SessionSummary]
        let reviewCounts: [String: Int]
        let needle: String
        let scopes: Set<SessionSearchScope>
        let harnessFilter: Set<Harness>?
        let since: Date?
        let sortOrder: SortOrder
        let groupByProject: Bool
    }

    private struct RowOutput: Sendable {
        let rows: [Row]
        let groupedRows: [ProjectGroup]
    }

    /// The list, derived off the main actor.
    ///
    /// A keystroke on a page holding a couple of thousand summaries used to
    /// run this synchronously inside a `didSet`: a case- and
    /// diacritic-insensitive `range(of:)` over two fields of every summary,
    /// then a sort, then a grouping pass, then two `@Published` writes — all
    /// before the character appeared in the field.
    private nonisolated static func buildRows(_ input: RowInput) async -> RowOutput {
        await Task.detached(priority: .userInitiated) {
            // Both kinds of hit, together: what the index found inside
            // sessions (with a snippet), then every loaded row whose own
            // label matches and the index did not already return. Full-text
            // hits used to replace the label matches outright, so typing
            // "codex" found messages that said codex and lost the Codex
            // sessions themselves.
            let hitRows = input.needle.isEmpty ? [] : input.hits.map {
                Row(
                    summary: $0.summary,
                    snippet: $0.snippet,
                    matchedSeq: $0.matchedSeq,
                    matchedRelated: input.relatedHitByParent[$0.summary.id],
                    reviewCount: input.reviewCounts[$0.summary.sessionID] ?? 0
                )
            }
            let hitIDs = Set(hitRows.map(\.id))
            let labelRows = filteredSummaries(input)
                .filter { !hitIDs.contains($0.id) }
                .map {
                    Row(
                        summary: $0,
                        snippet: nil,
                        matchedSeq: nil,
                        matchedRelated: nil,
                        reviewCount: input.reviewCounts[$0.sessionID] ?? 0
                    )
                }
            let base = hitRows + labelRows
            let rows = input.needle.isEmpty
                ? base
                : sorted(base.filter { passesFilters($0, input) }, order: input.sortOrder)
            return RowOutput(
                rows: rows,
                groupedRows: input.groupByProject ? grouped(rows) : []
            )
        }.value
    }

    private nonisolated static func grouped(_ rows: [Row]) -> [ProjectGroup] {
        var order: [ProjectBucket] = []
        var buckets: [ProjectBucket: [Row]] = [:]
        for row in rows {
            let key = projectBucket(for: row.summary)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(row)
        }
        return order.map { ProjectGroup(project: $0, rows: buckets[$0] ?? []) }
    }

    nonisolated static func projectBucket(_ projectDir: String?) -> ProjectBucket {
        guard let projectDir, !projectDir.isEmpty else { return .noProject }
        return .named(URL(fileURLWithPath: projectDir).lastPathComponent)
    }

    nonisolated static func projectBucket(for summary: SessionSummary) -> ProjectBucket {
        if summary.provider == .codex, isGeneratedProjectlessPath(summary.projectDir) {
            return .projectless
        }
        return projectBucket(summary.projectDir)
    }

    nonisolated static func projectTitle(for summary: SessionSummary) -> String {
        projectBucket(for: summary).title
    }

    /// Codex Desktop creates a dated scratch cwd for a projectless task. The
    /// state database has no `project_id` column, so this stable path shape is
    /// the only on-disk distinction; the real cwd remains available in Details
    /// and resume commands.
    nonisolated static func isGeneratedProjectlessPath(_ path: String?) -> Bool {
        guard let path else { return false }
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let codex = components.lastIndex(of: "Codex"), components.count == codex + 3 else {
            return false
        }
        let date = components[codex + 1].split(separator: "-", omittingEmptySubsequences: false)
        return date.count == 3 && date[0].count == 4 && date[1].count == 2 && date[2].count == 2
            && date.allSatisfy { Int($0) != nil }
    }

    /// The loaded page filtered in memory — instant, on every keystroke —
    /// followed by what the index-wide label scan added once it landed.
    private nonisolated static func filteredSummaries(_ input: RowInput) -> [SessionSummary] {
        guard !input.needle.isEmpty else { return input.summaries }
        var seen: Set<String> = []
        var out: [SessionSummary] = []
        for summary in input.summaries where matches(summary, needle: input.needle) {
            if seen.insert(summary.id).inserted { out.append(summary) }
        }
        for summary in input.labelHits where seen.insert(summary.id).inserted {
            out.append(summary)
        }
        return out
    }

    /// Whether a row is found by what it shows: its title, its id, its
    /// project folder (the last path component and the whole path), and the
    /// harness and company it is labelled with. Not gated on a scope — the
    /// scopes choose which *messages* the index searches; a search that
    /// cannot find "codex" or a folder name that is right there on the row
    /// is the one nobody trusts.
    nonisolated static func matches(_ summary: SessionSummary, needle: String) -> Bool {
        let harness = summary.effectiveHarness
        let fields: [String?] = [
            summary.title,
            summary.sessionID,
            summary.projectDir,
            projectBucket(for: summary).title,
            harness.displayName,
            harness.companyName,
        ]
        for field in fields {
            guard let field else { continue }
            if field.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    private nonisolated static func passesFilters(_ row: Row, _ input: RowInput) -> Bool {
        if let filter = input.harnessFilter, !filter.contains(row.summary.effectiveHarness) {
            return false
        }
        guard let start = input.since else { return true }
        let stamp = row.summary.lastActiveAt ?? row.summary.createdAt
        guard let stamp else { return false }
        return stamp >= start
    }

    private nonisolated static func sorted(_ rows: [Row], order: SortOrder) -> [Row] {
        switch order {
        case .recentFirst:
            return rows.sorted { activity($0) > activity($1) }
        case .oldestFirst:
            return rows.sorted { activity($0) < activity($1) }
        case .byProject:
            // Key first, compare second: a localized comparison inside the
            // predicate would re-derive both project names on every swap.
            return rows
                .map { (key: Self.projectTitle(for: $0.summary), row: $0) }
                .sorted {
                    if $0.key != $1.key {
                        return $0.key.localizedStandardCompare($1.key) == .orderedAscending
                    }
                    return Self.activity($0.row) > Self.activity($1.row)
                }
                .map(\.row)
        }
    }

    private nonisolated static func activity(_ row: Row) -> Date {
        row.summary.lastActiveAt ?? row.summary.createdAt ?? .distantPast
    }

    // MARK: - Filter mutation

    func toggleHarness(_ harness: Harness) {
        toggleHarnesses([harness])
    }

    /// ⌥-click on a harness chip: narrow the list to that harness alone.
    func soloHarness(_ harness: Harness) {
        setHarnessFilter(HarnessSelection.solo(harness, options: Harness.allCases))
    }

    /// What the "All" chip does: everything lit turns everything off,
    /// anything else turns everything back on.
    func toggleAllHarnesses() {
        setHarnessFilter(
            HarnessSelection.toggleAll(harnessFilter, options: Harness.allCases)
        )
    }

    func toggleHarnesses(_ harnesses: Set<Harness>) {
        setHarnessFilter(
            HarnessSelection.toggle(
                harnesses, in: harnessFilter, options: Harness.allCases
            )
        )
    }

    /// `nil` lists every harness; `[]` lists none. Both are real states — the
    /// All chip toggles between them — so an empty set is no longer folded
    /// back into "unfiltered".
    func setHarnessFilter(_ harnesses: Set<Harness>?) {
        harnessFilter = harnesses
    }

    func toggleSearchScope(_ scope: SessionSearchScope) {
        if searchScopes.contains(scope) {
            searchScopes.remove(scope)
        } else {
            searchScopes.insert(scope)
        }
    }

    func clearDirectoryFilters() {
        directoryIncludeText = ""
        directoryExcludeText = ""
    }

    // MARK: - Selection

    /// Selecting a full-text hit carries the matched message with it, so the
    /// transcript opens on the line that produced the snippet instead of at
    /// the top of a session the user then has to search again by hand.
    func select(_ row: Row) {
        select(
            row.summary,
            focusSeq: row.matchedSeq,
            focusedRelatedID: row.matchedRelated?.id
        )
    }

    func select(
        _ summary: SessionSummary?,
        focusSeq: Int? = nil,
        focusedRelatedID: String? = nil
    ) {
        load(
            summary,
            focusSeq: focusSeq,
            focusedRelatedID: focusedRelatedID,
            headByteLimit: SessionIndexingBounds.viewerHeadParseByteLimit
        )
    }

    /// Re-read the open session with no byte bound. Only ever reached from
    /// the banner the truncated read puts on screen: a 1.7 GB rollout parses
    /// into 1.5–1.9 GB of live objects, which is a thing to do because the
    /// user asked, never by default.
    func loadEntireTranscript() {
        guard let selection, transcriptTruncation != nil else { return }
        load(
            selection,
            focusSeq: focusSeq,
            focusedRelatedID: nil,
            headByteLimit: nil
        )
    }

    /// Abandon an in-flight transcript read.
    ///
    /// The row stays selected, so the way back is to click it again — said
    /// out loud, because a pane that simply goes blank reads as a failure
    /// rather than as the thing the user just asked for.
    func cancelTranscriptLoad() {
        guard isLoadingTranscript else { return }
        cancelTranscriptParse()
        isLoadingTranscript = false
        transcriptError = Self.cancelledTranscriptMessage
    }

    /// Computed, and `nonisolated` so the detached parse can read it too: a
    /// `static let` would freeze the language it was first resolved in.
    nonisolated static var cancelledTranscriptMessage: String {
        L10n.Workbench.Sessions.Transcript.cancelled
    }

    /// Cancel the parse itself, not just the task waiting on it.
    ///
    /// `Task.detached` does not inherit cancellation, so cancelling the
    /// waiter alone left the parser allocating gigabytes in the background —
    /// and let a second selection start a second one beside it. The waiter
    /// forwards its cancellation to the detached handle through
    /// `withTaskCancellationHandler`; this is the one place that starts it.
    private func cancelTranscriptParse() {
        transcriptTask?.cancel()
        transcriptTask = nil
        transcriptGeneration &+= 1
    }

    private func load(
        _ summary: SessionSummary?,
        focusSeq: Int?,
        focusedRelatedID: String?,
        headByteLimit: Int64?
    ) {
        // Cancel first, and hold the new task: the generation check alone
        // only discarded a stale *result*, so clicking through three large
        // sessions ran three full parses side by side and paid for all of
        // them.
        cancelTranscriptParse()
        selection = summary
        self.focusSeq = focusSeq
        transcript = nil
        transcriptError = nil
        transcriptTruncation = nil
        guard let summary else {
            isLoadingTranscript = false
            return
        }
        guard let adapter = registry.adapter(for: summary.provider) else {
            isLoadingTranscript = false
            transcriptError = L10n.Workbench.Sessions.Transcript.noReader(
                provider: summary.provider.displayName
            )
            return
        }
        let generation = transcriptGeneration
        let url = URL(fileURLWithPath: summary.sourcePath)
        let related = reviewSummariesByParent[summary.sessionID] ?? []
        let scratch = VibeBarLocalStore.sessionIndexScratchDirectoryURL(homeDirectory: homeDirectory)
        isLoadingTranscript = true
        transcriptTask = Task { [weak self] in
            let parsed = await Self.parse(
                adapter: adapter,
                url: url,
                related: related,
                requestedFocusSeq: focusSeq,
                focusedRelatedID: focusedRelatedID,
                headByteLimit: headByteLimit,
                scratchDirectory: scratch
            )
            guard let self, !Task.isCancelled, generation == self.transcriptGeneration else { return }
            self.transcriptTask = nil
            self.isLoadingTranscript = false
            self.focusSeq = parsed.focusSeq
            self.transcript = parsed.document
            self.transcriptError = parsed.errorMessage
            self.transcriptTruncation = parsed.truncation
        }
    }

    func clearFocus() {
        focusSeq = nil
    }

    private struct ParsedTranscript: Sendable {
        let document: TranscriptDocument?
        let errorMessage: String?
        let focusSeq: Int?
        let truncation: TranscriptTruncation?
    }

    /// `nonisolated` so the parse runs off the main actor — a long rollout is
    /// megabytes of JSONL and the window has to stay interactive through it.
    ///
    /// `headByteLimit` is the memory bound. `range:` is not one: every kit
    /// adapter materializes the whole document before slicing it, so the only
    /// place a limit can be applied is the bytes handed to the parser.
    ///
    /// The detached task's handle is held and cancelled with the caller.
    /// `Task.detached` deliberately inherits nothing — including
    /// cancellation — so without this forwarding, cancelling the waiter left
    /// the parser running: an unbounded "Load entire transcript" kept
    /// allocating after the pane had moved on, and each further selection
    /// stacked another parse beside it.
    private nonisolated static func parse(
        adapter: any SessionProviderAdapter,
        url: URL,
        related: [SessionSummary],
        requestedFocusSeq: Int?,
        focusedRelatedID: String?,
        headByteLimit: Int64?,
        scratchDirectory: URL
    ) async -> ParsedTranscript {
        let handle = Task.detached(priority: .userInitiated) {
            do {
                let read = try SessionIndexingBounds.readTranscript(
                    adapter: adapter,
                    fileURL: url,
                    headByteLimit: headByteLimit,
                    scratchDirectory: scratchDirectory
                )
                let root = read.document
                let truncation = read.isHeadTruncated
                    ? TranscriptTruncation(
                        shownMessages: root.messages.count,
                        parsedBytes: headByteLimit ?? read.fileByteSize,
                        fileBytes: read.fileByteSize
                    )
                    : nil
                // A truncated parent already spends the budget; loading its
                // Auto Review children on top would double it for no gain,
                // since the pane cannot show the parent's tail either.
                guard !related.isEmpty, truncation == nil else {
                    return ParsedTranscript(
                        document: root,
                        errorMessage: nil,
                        focusSeq: requestedFocusSeq,
                        truncation: truncation
                    )
                }
                var messages = root.messages
                var translatedFocus = focusedRelatedID == nil ? requestedFocusSeq : nil
                var childTruncated = false
                for review in related.sorted(by: {
                    ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                }) {
                    try Task.checkCancellation()
                    // Children are bounded on the same terms as the parent.
                    guard let child = try? SessionIndexingBounds.readTranscript(
                        adapter: adapter,
                        fileURL: URL(fileURLWithPath: review.sourcePath),
                        headByteLimit: headByteLimit,
                        scratchDirectory: scratchDirectory
                    ) else { continue }
                    let document = child.document
                    childTruncated = childTruncated || child.isHeadTruncated
                    messages.append(SessionMessage(
                        seq: messages.count,
                        role: .system,
                        text: L10n.Workbench.Sessions.Transcript.autoReviewDivider,
                        timestamp: review.createdAt
                    ))
                    let childStart = messages.count
                    messages.append(contentsOf: document.messages)
                    if review.id == focusedRelatedID,
                       let requestedFocusSeq,
                       let childIndex = document.messages.firstIndex(where: { $0.seq == requestedFocusSeq }) {
                        translatedFocus = childStart + childIndex
                    }
                }
                // Resequencing allocates a second copy of every message, so
                // it is worth not starting on a result nobody will read.
                try Task.checkCancellation()
                let resequenced = messages.enumerated().map { index, message in
                    SessionMessage(
                        seq: index,
                        role: message.role,
                        text: message.text,
                        timestamp: message.timestamp
                    )
                }
                return ParsedTranscript(
                    document: TranscriptDocument(
                        messages: resequenced,
                        totalMessageCount: resequenced.count,
                        truncated: childTruncated
                    ),
                    errorMessage: nil,
                    focusSeq: translatedFocus,
                    truncation: nil
                )
            } catch is CancellationError {
                // Not a read failure. The waiter normally drops this on its
                // own cancellation check; the message is here for the race
                // where the parse gave up first.
                return ParsedTranscript(
                    document: nil,
                    errorMessage: cancelledTranscriptMessage,
                    focusSeq: nil,
                    truncation: nil
                )
            } catch {
                return ParsedTranscript(
                    document: nil,
                    errorMessage: (error as? LocalizedError)?.errorDescription
                        ?? L10n.Workbench.Sessions.Transcript.readFailed,
                    focusSeq: nil,
                    truncation: nil
                )
            }
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    // MARK: - Resume

    /// `nil` when the provider has no command-line entry point for this
    /// session — AntiGravity's IDE surfaces, most notably.
    func resumeCommand(for summary: SessionSummary) -> String? {
        try? SessionResumeCommandBuilder.command(
            provider: summary.provider,
            sessionID: summary.sessionID,
            variant: summary.providerVariant
        )
    }

    func resumeShellLine(for summary: SessionSummary) -> String? {
        guard let command = resumeCommand(for: summary) else { return nil }
        return SessionResumeCommandBuilder.shellLine(cwd: summary.projectDir, command: command)
    }

    func copyResumeCommand(for summary: SessionSummary) {
        guard let line = resumeShellLine(for: summary) else {
            show(toast: L10n.Workbench.Sessions.Toast.noResumeCommand)
            return
        }
        Task { [weak self] in
            let result = await TerminalLauncher.launch(shellLine: line, preferred: .copyOnly)
            guard let self else { return }
            self.report(result)
        }
    }

    func resumeInTerminal(_ summary: SessionSummary) {
        guard let line = resumeShellLine(for: summary) else {
            show(toast: L10n.Workbench.Sessions.Toast.noResumeCommand)
            return
        }
        let preferred = settingsStore.settings.preferredTerminal
        Task { [weak self] in
            let result = await TerminalLauncher.launch(shellLine: line, preferred: preferred)
            guard let self else { return }
            self.report(result)
        }
    }

    private func report(_ result: TerminalLauncher.Result) {
        switch result {
        case let .launched(target):
            show(toast: L10n.Workbench.Sessions.Toast.openedIn(terminal: target.displayName))
        case let .copiedToClipboard(reason):
            show(toast: reason.map { L10n.Workbench.Sessions.Toast.copiedWithReason(reason: $0) }
                ?? L10n.Workbench.Sessions.Toast.copied)
        case let .failed(message):
            show(toast: message)
        }
    }

    func copyToClipboard(_ text: String, note: String) {
        Task { [weak self] in
            let result = await TerminalLauncher.launch(shellLine: text, preferred: .copyOnly)
            guard let self else { return }
            if case .copiedToClipboard = result {
                self.show(toast: note)
            } else {
                self.report(result)
            }
        }
    }

    // MARK: - Deletion

    /// AntiGravity, Cursor, and Claude Cowork all keep their stores under
    /// another running app, so their adapters refuse to plan a delete.
    /// Filtering those rows out here keeps the confirmation sheet from
    /// promising something that will fail — the fact itself lives in Core so
    /// the gate and the adapters cannot drift apart.
    static func isDeletable(_ summary: SessionSummary) -> Bool {
        summary.provider.supportsDeletion
    }

    var checkedSummaries: [SessionSummary] {
        rows.map(\.summary).filter { checkedIDs.contains($0.id) }
    }

    func toggleChecked(_ summary: SessionSummary) {
        guard Self.isDeletable(summary) else { return }
        if checkedIDs.contains(summary.id) {
            checkedIDs.remove(summary.id)
        } else {
            checkedIDs.insert(summary.id)
        }
    }

    func requestDelete(_ summaries: [SessionSummary]) {
        let deletable = summaries.filter(Self.isDeletable)
        guard !deletable.isEmpty else {
            // One refusal reason per provider, so the toast says which app
            // owns the store rather than a generic "not supported".
            let refused = summaries.first?.provider ?? .antigravity
            show(toast: SessionDeleteError.providerIsReadOnly(refused).message)
            return
        }
        pendingDeletion = deletable
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    func confirmDelete() {
        guard let targets = pendingDeletion else { return }
        pendingDeletion = nil
        let deleter = self.deleter
        let registry = self.registry
        Task { [weak self] in
            let outcomes = await Self.performDelete(deleter: deleter, registry: registry, targets: targets)
            guard let self else { return }
            await self.finish(outcomes)
        }
    }

    private nonisolated static func performDelete(
        deleter: SessionDeleter,
        registry: SessionProviderRegistry,
        targets: [SessionSummary]
    ) async -> [SessionDeleteOutcome] {
        deleter.delete(targets, registry: registry)
    }

    private func finish(_ outcomes: [SessionDeleteOutcome]) async {
        let removed = outcomes.filter(\.success).map(\.summary)
        // The index is a cache of the filesystem, so the rows go now rather
        // than waiting for the next scan's prune pass to notice.
        if let store, !removed.isEmpty {
            try? await store.removeSessions(sourcePathIn: removed.map(\.sourcePath))
            invalidateIndexDerivedState()
        }
        checkedIDs.subtract(removed.map(\.id))
        reloadSummaryPage(reset: true)

        let failures = outcomes.filter { !$0.success }
        if failures.isEmpty {
            show(toast: L10n.Workbench.Sessions.Toast.deleted(count: removed.count))
        } else if let first = failures.first?.failureReason {
            show(toast: removed.isEmpty
                ? first.message
                : L10n.Workbench.Sessions.Toast.deletedPartial(
                    deleted: removed.count,
                    kept: failures.count,
                    reason: first.message
                ))
        }
    }

    // MARK: - Options

    var preferredTerminal: PreferredTerminal {
        settingsStore.settings.preferredTerminal
    }

    func setPreferredTerminal(_ terminal: PreferredTerminal) {
        settingsStore.settings.preferredTerminal = terminal
    }

    var isBodyIndexingEnabled: Bool {
        settingsStore.settings.sessionBodyIndexingEnabled
    }

    /// Turning bodies off drops what is already stored immediately, rather
    /// than at the next scan: the point of the switch is that the excerpts
    /// stop being on disk.
    func setBodyIndexing(_ enabled: Bool) {
        guard enabled != settingsStore.settings.sessionBodyIndexingEnabled else { return }
        settingsStore.settings.sessionBodyIndexingEnabled = enabled
        index.bodyIndexing.set(enabled)
        guard let store else { return }
        if enabled {
            refreshIndex()
            return
        }
        hits = []
        labelHits = []
        Task { [weak self] in
            var dropped = false
            do {
                try await store.dropBodyIndex()
                try await store.setBodyIndexingMode(false)
                dropped = true
            } catch {
                dropped = false
            }
            guard let self else { return }
            self.show(toast: dropped
                ? L10n.Workbench.Sessions.Toast.bodyIndexDropped
                : L10n.Workbench.Sessions.Toast.bodyIndexDropFailed)
        }
    }

    // MARK: - Toast

    private static let toastDuration = Duration.seconds(4)

    private func show(toast message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }
}

/// The app's one connection to `~/.vibebar/session_index.sqlite3`.
///
/// Three components used to open their own: the Workbench's Sessions page,
/// `MCPController` (on the first `sessions.*` call), and
/// `SessionIndexCompactor`. Nothing coordinated them, so an MCP backfill and
/// a Workbench refresh could run two full 11 000-file passes over the same
/// 1 GB database at once, each waiting out the other's busy timeout. Two
/// connections to one WAL database are legal; two *indexers* are just twice
/// the work.
///
/// The compactor still keeps its own handle — it runs once a day, needs raw
/// SQLite, and is fenced by `SessionIndexMaintenanceGate` instead.
@MainActor
final class SharedSessionIndex {
    /// `nil` when the database would not open. Same shape as the usage
    /// ledger in `AppEnvironment`: that costs the Sessions page its index,
    /// not the app its launch.
    let store: SessionIndexStore?
    let service: SessionIndexService?
    /// The privacy switch, mirrored where the index actor can read it
    /// without a main-actor hop — and, unlike a captured `Bool`, re-read on
    /// every pass. Following the setting for the life of the app is what
    /// makes "Index message text" reach the MCP surface too.
    let bodyIndexing: BodyIndexingFlag

    private var cancellables: Set<AnyCancellable> = []

    init(settingsStore: SettingsStore, homeDirectory: String = RealHomeDirectory.path) {
        let flag = BodyIndexingFlag(settingsStore.settings.sessionBodyIndexingEnabled)
        self.bodyIndexing = flag

        let opened: SessionIndexStore?
        do {
            opened = try SessionIndexStore(url: VibeBarLocalStore.sessionIndexURL)
        } catch {
            SafeLog.warn("Opening the session index failed: \(SafeLog.sanitize(error.localizedDescription))")
            opened = nil
        }
        self.store = opened
        self.service = opened.map {
            SessionIndexService(
                homeDirectory: homeDirectory,
                store: $0,
                // The indexer gets the bounded adapters: oversized rollouts
                // are parsed from a head copy (memory) and excerpts are
                // pre-trimmed to the host policy (index size). The raw
                // registry stays with the transcript viewer and the deleter,
                // which must see whole sessions.
                registry: SessionIndexingBounds.boundedRegistry(
                    SessionProviderRegistry.standard(homeDirectory: homeDirectory),
                    scratchDirectory: VibeBarLocalStore
                        .sessionIndexScratchDirectoryURL(homeDirectory: homeDirectory)
                ),
                bodyIndexing: { flag.current }
            )
        }

        settingsStore.$settings
            .map(\.sessionBodyIndexingEnabled)
            .removeDuplicates()
            .sink { enabled in flag.set(enabled) }
            .store(in: &cancellables)
    }
}
