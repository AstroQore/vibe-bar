import AppKit
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
    // The label scan runs under the same date window and order as the
    // list, so both changes rerun the search as well as reloading the page.
    @Published var dateRange: DateRange = .all {
        didSet {
            reloadSummaryPage(reset: true)
            rerunSearch()
            refreshRows()
        }
    }
    @Published var sortOrder: SortOrder = .recentFirst {
        didSet {
            reloadSummaryPage(reset: true)
            rerunSearch()
        }
    }
    @Published var groupByProject = false {
        didSet { refreshRows() }
    }

    @Published private(set) var selection: SessionSummary?
    /// The session `transcript` is of. The selection, unless the
    /// conversation pane opened a thread from it (`loadTranscript(for:)`).
    @Published private(set) var transcriptSubject: SessionSummary?
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
    /// What the confirmation is asking about: the selection, plus the Auto
    /// Reviews that go with it.
    @Published private(set) var pendingDeletion: SessionDeletionCascade.Plan?
    @Published private(set) var toast: String?

    struct IndexProgress: Equatable {
        let done: Int
        let total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(done) / Double(total))
        }
    }

    /// Whether selecting a session also reads its flat transcript. The
    /// Sessions page answers no for a provider its turn view can read —
    /// that view parses the log its own way, and reading it twice would pay
    /// for the same file twice — and the transcript is then read only when
    /// the Raw view asks for it (`loadTranscript(for:)`).
    var loadsTranscriptOnSelect: @MainActor (SessionSummary) -> Bool = { _ in true }

    /// A demo launch opens a session so a capture has a conversation in it.
    /// The Sessions page turns this off and picks the first *listed* row
    /// itself: the newest index row can be a thread folded out of sight.
    var selectsFirstSummaryInDemo = true

    // MARK: - Dependencies

    private let settingsStore: SettingsStore
    private let homeDirectory: String
    /// Refreshed off the main actor with each full summary reload, so a
    /// model AntiGravity ships after launch names itself without a relaunch
    /// and no filter change waits on a disk read.
    @Published private(set) var antigravityModelLabels = AntigravityModelLabelStore()
    /// When the label file the published labels came from was last written.
    /// Ordering by the snapshot rather than by the read that asked for it:
    /// two detached reads can finish either way round, and can even read
    /// either way round, but the file's own timestamp says which of them
    /// saw the newer file.
    private var appliedLabelsWrittenAt: Date?
    private let registry: SessionProviderRegistry
    /// One for the page, so a double click on the row's menu and on the
    /// Details button is still one probe.
    private let revealer = SessionSourceRevealer { target in
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    private let deleter: SessionDeleter
    private let index: SharedSessionIndex

    private var store: SessionIndexStore? { index.store }
    private var service: SessionIndexService? { index.service }
    private var reviewIndex: SessionReviewIndex { index.reviews }

    private var searchTask: Task<Void, Never>?
    private var directoryFilterTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var rowsTask: Task<Void, Never>?
    /// Reads the reviews a deletion takes with it, before the confirmation
    /// is shown. Held so a second request (or Cancel) supersedes it.
    private var deletionPlanTask: Task<Void, Never>?
    /// The parse behind the open transcript. Held so a second click cancels
    /// the first: three 1 GB sessions in a row used to mean three concurrent
    /// full parses, of which two were discarded on arrival by a generation
    /// check that had already let them allocate everything.
    private var transcriptTask: Task<Void, Never>?
    /// What the open transcript was read for — kept so "Load entire
    /// transcript" re-reads it with the same focus.
    private var transcriptRequest: SessionTranscriptMerge.Request?
    /// What the selection asked for, kept apart from `transcriptRequest`:
    /// the transcript may be showing a thread opened from the selection.
    private var selectionRequest: SessionTranscriptMerge.Request?
    private var transcriptGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var summaryGeneration: UInt64 = 0
    private var lastScanFinishedAt: Date?
    /// Auto Reviews per parent session id — one small entry per parent, from
    /// `SessionReviewIndex.overview()`. The reviews themselves are read only
    /// when a transcript opens or a deletion is planned.
    private var reviewCountsByParent: [String: Int] = [:]
    private var relatedHitByParent: [String: SessionSummary] = [:]
    /// Bumped whenever the index's contents can have moved (a completed
    /// refresh, a rebuild, a delete). Everything derived from a whole-index
    /// query — the review counts and the harness chip counts — is fetched
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
    /// Most Auto Reviews one transcript merges. The busiest session on a
    /// heavy Mac has a few hundred; this only bounds a pathological one.
    private static let transcriptReviewLimit = 500
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
        refreshAntigravityModelLabels()
    }

    /// Off the actor: this is a file read, and every filter change asks for
    /// it. A row without its labels yet draws no chip, and gets one on the
    /// next render.
    ///
    /// Two reads can straddle a quota refresh that rewrites the file —
    /// `AntigravityQuotaAdapter` replaces a label whose value changed, so
    /// the file is not append-only — and neither the order they were asked
    /// for nor the order they finish in says which one read the newer file.
    /// Its modification date does, so each read carries it and an older
    /// snapshot is dropped.
    private func refreshAntigravityModelLabels() {
        let home = homeDirectory
        Task.detached(priority: .utility) {
            let url = AntigravityModelLabelStore.fileURL(homeDirectory: home)
            let store = AntigravityModelLabelStore.load(homeDirectory: home)
            let writtenAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let writtenAt, let applied = self.appliedLabelsWrittenAt, writtenAt < applied { return }
                self.appliedLabelsWrittenAt = writtenAt ?? self.appliedLabelsWrittenAt
                guard self.antigravityModelLabels != store else { return }
                self.antigravityModelLabels = store
            }
        }
    }

    /// The name AntiGravity's own status endpoint gives a model id, or nil
    /// when the id is still one of its internal enums and says nothing a
    /// reader can use.
    ///
    /// AntiGravity writes `MODEL_PLACEHOLDER_M318` into its transcripts and
    /// keeps the label — "Gemini 3.8 Flash (High)" — in the status response
    /// the quota adapter already harvests into
    /// `~/.vibebar/antigravity_model_labels.json`. The cost scanner has
    /// resolved through that file for as long as it has existed; the session
    /// list was reading the raw id and hiding the chip instead.
    func displayModel(for summary: SessionSummary) -> String? {
        UsageModelNaming.sessionChipLabel(model: summary.model, labels: antigravityModelLabels)
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
        deletionPlanTask?.cancel()
        cancelTranscriptParse()
        searchTask = nil
        directoryFilterTask = nil
        refreshTask = nil
        toastTask = nil
        rowsTask = nil
        deletionPlanTask = nil

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
        if reset { refreshAntigravityModelLabels() }
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
        // Chip counts and the Auto Review counts are whole-index facts: they
        // do not depend on the harness, date, sort or directory filter that
        // triggered this reload, so they are read once per index generation.
        // The review counts come grouped from SQLite — one entry per parent,
        // every review counted — rather than as a capped list of summaries.
        let currentIndexGeneration = indexGeneration
        let needsIndexDerived = reset && indexDerivedGeneration != currentIndexGeneration
        let includes = directoryIncludes
        let excludes = directoryExcludes
        let reviewIndex = self.reviewIndex
        isLoadingSummaries = true
        Task { [weak self] in
            let page = try? await SessionVisibleRows.page(
                service,
                harnesses: harnesses,
                since: since,
                projectIncludes: includes,
                projectExcludes: excludes,
                order: order,
                offset: offset,
                limit: Self.summaryPageSize
            )
            let counts = needsIndexDerived ? (try? await service.harnessCounts()) : nil
            let overview = needsIndexDerived ? (try? await reviewIndex.overview()) : nil
            guard let self, generation == self.summaryGeneration else { return }
            // Both or neither: chip counts that never had the hidden reviews
            // taken off would otherwise stick for the whole generation.
            if needsIndexDerived, counts != nil, overview != nil {
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
            if DemoMode.isEnabled, self.selectsFirstSummaryInDemo, self.selection == nil,
               let first = page.summaries.first {
                self.select(first)
            }
            if var counts {
                for (harness, hidden) in overview?.hiddenRowsByHarness ?? [:] {
                    counts[harness] = max(0, (counts[harness] ?? 0) - hidden)
                }
                self.harnessCounts = counts
            }
            if let overview {
                self.reviewCountsByParent = overview.countsByParent
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
        // Every change is a new generation, clearing included: a search
        // still in flight when the field empties must not publish afterwards.
        searchGeneration &+= 1
        let generation = searchGeneration
        guard !needle.isEmpty else {
            relatedHitByParent = [:]
            hits = []
            labelHits = []
            return
        }
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
        guard !Task.isCancelled, generation == searchGeneration else { return }
        labelHits = labelled

        // Resolve every Auto Review child to its parent in one hop, then fold
        // — the same rule `sessions.search` applies (`SessionVisibleRows`).
        //
        // The lookups are batched host-side: dedupe the ids, answer what the
        // per-generation cache already knows, and ask the index only for the
        // remainder — from a single detached task, so the main actor is
        // entered once rather than once per hit.
        let wanted = SessionVisibleRows.reviewParentIDs(in: found).filter { parentSummaryCache[$0] == nil }
        if !wanted.isEmpty {
            let fetched = await Self.resolveParentSummaries(service: service, sessionIDs: wanted)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            parentSummaryCache.merge(fetched) { _, new in new }
        }

        let folded = SessionVisibleRows.fold(found, parents: parentSummaryCache)
        var relatedHits: [String: SessionSummary] = [:]
        for entry in folded {
            if let review = entry.matchedReview { relatedHits[entry.hit.summary.id] = review }
        }
        guard !Task.isCancelled, generation == searchGeneration else { return }
        relatedHitByParent = relatedHits
        hits = folded.map(\.hit)
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
    /// loaded page is still found by its folder or harness. A needle that
    /// matches nothing reads every summary there is, so the pages are large
    /// — a dozen round trips, not fifty — and the walk is a structured child
    /// of the search (`async let`), so cancelling the search stops it at the
    /// next page instead of leaving it to contend with the search that
    /// replaced it. Nonisolated, so the matching never runs on the main actor.
    private nonisolated static func scanLabels(
        service: SessionIndexService,
        needle: String,
        harnesses: [Harness]?,
        since: Date?,
        projectIncludes: [String],
        projectExcludes: [String],
        order: SessionSummaryOrder
    ) async -> [SessionSummary] {
        var out: [SessionSummary] = []
        var offset = 0
        while out.count < labelHitLimit, !Task.isCancelled {
            guard let page = try? await SessionVisibleRows.page(
                service,
                harnesses: harnesses,
                since: since,
                projectIncludes: projectIncludes,
                projectExcludes: projectExcludes,
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
    }

    /// One detached pass over the deduped parent ids. Cancellation is checked
    /// per id so an abandoned search stops paying immediately.
    private nonisolated static func resolveParentSummaries(
        service: SessionIndexService,
        sessionIDs: [String]
    ) async -> [String: SessionSummary] {
        await Task.detached(priority: .userInitiated) {
            await SessionVisibleRows.resolveParents(service, ids: sessionIDs)
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
            reviewCounts: reviewCountsByParent,
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
        if isClaudeScratchWorkspacePath(summary.projectDir) {
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

    /// Claude Desktop and Cowork open a projectless task in a scratch
    /// workspace under the app's own support directory —
    /// `Claude/scratch-workspaces/<workspace>/<task>/scratch-<date>-<id>` —
    /// the same idea as Codex's dated scratch cwd. The path is what the
    /// session records as its cwd, and it is nobody's project.
    nonisolated static func isClaudeScratchWorkspacePath(_ path: String?) -> Bool {
        guard let path else { return false }
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let support = components.firstIndex(of: "Application Support"),
              components.count > support + 2,
              components[support + 1] == "Claude",
              components[support + 2] == "scratch-workspaces"
        else { return false }
        return true
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
            focusedRelated: row.matchedRelated
        )
    }

    /// `focusedRelated` is the Auto Review a search hit matched in, carried
    /// whole rather than by id: the transcript merges at most
    /// `transcriptReviewLimit` reviews, and this one has to be among them even
    /// when it falls past that bound.
    func select(
        _ summary: SessionSummary?,
        focusSeq: Int? = nil,
        focusedRelated: SessionSummary? = nil
    ) {
        load(summary.map {
            SessionTranscriptMerge.Request(
                summary: $0,
                focus: SessionTranscriptMerge.Focus(seq: focusSeq, review: focusedRelated),
                headByteLimit: SessionIndexingBounds.viewerHeadParseByteLimit
            )
        })
    }

    /// Re-read the open session with no byte bound. Only ever reached from
    /// the banner the truncated read puts on screen: a 1.7 GB rollout parses
    /// into 1.5–1.9 GB of live objects, which is a thing to do because the
    /// user asked, never by default.
    ///
    /// The selection's own request is re-run, focus included. The bounded
    /// read left the reviews out, so a hit inside one could not be shown yet;
    /// this is the read that can show it, and it has to know which review the
    /// hit's seq counts.
    func loadEntireTranscript() {
        guard let transcriptRequest, transcriptTruncation != nil else { return }
        let whole = transcriptRequest.wholeLog()
        if whole.summary.id == selectionRequest?.summary.id { selectionRequest = whole }
        read(whole, force: true)
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

    /// Select `request`'s session and read its transcript (when the page
    /// wants it on selection).
    private func load(_ request: SessionTranscriptMerge.Request?) {
        selectionRequest = request
        selection = request?.summary
        focusSeq = request?.focus.seq
        read(request, force: false)
    }

    /// Read `request`'s transcript; the selection is not touched.
    private func read(_ request: SessionTranscriptMerge.Request?, force: Bool) {
        // Cancel first, and hold the new task: the generation check alone
        // only discarded a stale *result*, so clicking through three large
        // sessions ran three full parses side by side and paid for all of
        // them.
        cancelTranscriptParse()
        transcriptRequest = request
        transcriptSubject = request?.summary
        transcript = nil
        transcriptError = nil
        transcriptTruncation = nil
        guard let request else {
            isLoadingTranscript = false
            return
        }
        guard force || loadsTranscriptOnSelect(request.summary) else {
            isLoadingTranscript = false
            return
        }
        let summary = request.summary
        let focus = request.focus
        let headByteLimit = request.headByteLimit
        guard let adapter = registry.adapter(for: summary.provider) else {
            isLoadingTranscript = false
            transcriptError = L10n.Workbench.Sessions.Transcript.noReader(
                provider: summary.provider.displayName
            )
            return
        }
        let generation = transcriptGeneration
        let url = URL(fileURLWithPath: summary.sourcePath)
        // A Codex session's Auto Reviews are read on selection, from the
        // review index's actor: always the current set, never a list the page
        // had to hold for every session in advance.
        let reviewParentID = summary.provider == .codex
            && SessionVisibleRows.reviewParentID(of: summary) == nil
            ? summary.sessionID : nil
        let reviewIndex = self.reviewIndex
        let scratch = VibeBarLocalStore.sessionIndexScratchDirectoryURL(homeDirectory: homeDirectory)
        isLoadingTranscript = true
        transcriptTask = Task { [weak self] in
            var related: [SessionSummary] = []
            if let reviewParentID {
                let fetched = (try? await reviewIndex.reviews(
                    forParents: [reviewParentID],
                    limit: Self.transcriptReviewLimit
                )) ?? []
                // The review the search hit is in rides along even past the
                // bound — otherwise its `matchedSeq` has nowhere to land.
                related = SessionVisibleRows.reviewsToMerge(
                    fetched,
                    parentID: reviewParentID,
                    focused: focus.review
                )
            }
            guard !Task.isCancelled else { return }
            let parsed = await Self.parse(
                adapter: adapter,
                url: url,
                related: related,
                focus: focus,
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

    /// Read the flat transcript of `shown` — the session the conversation
    /// pane shows — for the Raw view, unless it is already read or being
    /// read. For the selection that is the request it made, so a search hit
    /// still lands on its message; a thread opened from the selection (the
    /// selection stays put) is read for itself, not as its parent.
    func loadTranscript(for shown: SessionSummary) {
        if transcriptRequest?.summary.id == shown.id, transcript != nil || isLoadingTranscript { return }
        read(SessionTranscriptMerge.Request.forShown(
            shown,
            selection: selectionRequest,
            headByteLimit: SessionIndexingBounds.viewerHeadParseByteLimit
        ), force: true)
    }

    /// A Codex session's Auto Review rollouts and their count, for the
    /// masthead — counted the way the list row and `sessions.transcript`
    /// count them (`SessionReviewIndex.reviewSet`).
    func reviews(for summary: SessionSummary) async -> SessionReviewSet {
        await reviewIndex.reviewSet(for: summary, limit: Self.transcriptReviewLimit)
    }

    /// Every listed session's log, by harness — the rows the harness column
    /// counts (`SessionVisibleRows`, Auto Reviews excluded). Paged off the
    /// main actor; read once per index refresh by the harness column.
    func listedSourcePathsByHarness() async -> [Harness: Set<String>] {
        guard let service else { return [:] }
        var out: [Harness: Set<String>] = [:]
        var offset = 0
        while !Task.isCancelled {
            guard let page = try? await SessionVisibleRows.page(service, offset: offset, limit: 2_000) else { break }
            for summary in page.summaries { out[summary.effectiveHarness, default: []].insert(summary.sourcePath) }
            offset += page.summaries.count
            if page.summaries.isEmpty || offset >= page.totalCount { break }
        }
        return out
    }

    /// One indexed session by id — where a subagent step's thread is found.
    func indexedSummary(provider: SessionProvider, sessionID: String) async -> SessionSummary? {
        guard let service else { return nil }
        return try? await service.summary(provider: provider, sessionID: sessionID)
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
        focus: SessionTranscriptMerge.Focus,
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
                // since the pane cannot show the parent's tail either. A hit
                // inside a review then has nowhere to land until the whole log
                // is loaded, and `sessionOnly` does not pretend otherwise.
                guard !related.isEmpty, truncation == nil else {
                    let alone = SessionTranscriptMerge.sessionOnly(root, focus: focus)
                    return ParsedTranscript(
                        document: alone.document,
                        errorMessage: nil,
                        focusSeq: alone.focusSeq,
                        truncation: truncation
                    )
                }
                // Children are bounded on the same terms as the parent.
                let merged = try SessionTranscriptMerge.merged(
                    root: root,
                    reviews: related,
                    focus: focus,
                    dividerText: L10n.Workbench.Sessions.Transcript.autoReviewDivider
                ) { review in
                    guard let child = try? SessionIndexingBounds.readTranscript(
                        adapter: adapter,
                        fileURL: URL(fileURLWithPath: review.sourcePath),
                        headByteLimit: headByteLimit,
                        scratchDirectory: scratchDirectory
                    ) else { return nil }
                    return (child.document, child.isHeadTruncated)
                }
                return ParsedTranscript(
                    document: merged.document,
                    errorMessage: nil,
                    focusSeq: merged.focusSeq,
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
        // A Claude subagent transcript is not a session the CLI can resume;
        // its agent id would resume nothing, or the wrong thing.
        guard !ClaudeSubagentFiles.isSubagentSummary(summary) else { return nil }
        return try? SessionResumeCommandBuilder.command(
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
            guard let result = await TerminalLauncher.launch(shellLine: line, preferred: .copyOnly) else { return }
            guard let self else { return }
            self.report(result)
        }
    }

    /// The AppleScript runs on `TerminalLauncher`'s own queue, so the main
    /// actor only starts the launch and, later, shows how it went — it never
    /// waits on Terminal, or on the Automation prompt the first launch raises.
    /// A second click while the same launch is still running comes back `nil`
    /// and is dropped: one window, one toast.
    func resumeInTerminal(_ summary: SessionSummary) {
        guard let line = resumeShellLine(for: summary) else {
            show(toast: L10n.Workbench.Sessions.Toast.noResumeCommand)
            return
        }
        let preferred = settingsStore.settings.preferredTerminal
        Task { [weak self] in
            guard let result = await TerminalLauncher.launch(shellLine: line, preferred: preferred) else { return }
            guard let self else { return }
            self.report(result)
        }
    }

    /// The resume button's dropdown: run the line in one terminal this once,
    /// without changing the default the Options menu keeps.
    func resume(_ summary: SessionSummary, in terminal: PreferredTerminal) {
        guard let line = resumeShellLine(for: summary) else {
            show(toast: L10n.Workbench.Sessions.Toast.noResumeCommand)
            return
        }
        Task { [weak self] in
            guard let result = await TerminalLauncher.launch(shellLine: line, preferred: terminal) else { return }
            guard let self else { return }
            self.report(result)
        }
    }

    /// Select a folder (the session's working directory) in Finder, probed
    /// off the main actor like the log reveal.
    func revealFolder(_ path: String) {
        Task { [revealer] in await revealer.reveal(sourcePath: path) }
    }

    /// Open the session's working directory in Finder. The existence check
    /// runs off the main actor: a project on an unmounted volume must not
    /// stall the Workbench on a click.
    func openFolder(_ path: String) {
        Task {
            let exists = await Task.detached(priority: .userInitiated) {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.value
            guard exists else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    /// Show a short message at the foot of the page.
    func notify(_ message: String) {
        show(toast: message)
    }

    /// Select the session's log in Finder — or, when `sourcePath` is not a
    /// file of its own (a Devin locator) or has gone since the last sweep,
    /// the nearest folder or database that still exists. The path is probed
    /// off the main actor (a slow volume must not freeze the Workbench), and a
    /// second click while that probe runs is dropped.
    func revealInFinder(_ summary: SessionSummary) {
        let path = summary.sourcePath
        Task { [revealer] in await revealer.reveal(sourcePath: path) }
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
            guard let result = await TerminalLauncher.launch(shellLine: text, preferred: .copyOnly) else { return }
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
        // A subagent transcript goes with the session that wrote it.
        summary.provider.supportsDeletion && !ClaudeSubagentFiles.isSubagentSummary(summary)
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
        // A Codex session's Auto Reviews go with it (`SessionDeletionCascade`),
        // so the confirmation counts them before it is shown. One grouped
        // query on the review index's actor; the dialog waits for it rather
        // than promising a number it then changes.
        deletionPlanTask?.cancel()
        let reviewIndex = self.reviewIndex
        deletionPlanTask = Task { [weak self] in
            // A plan that could not collect every review is refused rather
            // than shown: confirming it would strand the reviews it missed.
            let plan: SessionDeletionCascade.Plan?
            let refusal: String?
            do {
                plan = try await SessionDeletionCascade.plan(selected: deletable, reviewIndex: reviewIndex)
                refusal = nil
            } catch {
                plan = nil
                refusal = (error as? SessionDeletionCascade.PlanError)?.message
                    ?? SessionDeletionCascade.PlanError.reviewLookupFailed.message
            }
            guard let self, !Task.isCancelled else { return }
            self.deletionPlanTask = nil
            if let plan {
                self.pendingDeletion = plan
            } else if let refusal {
                self.show(toast: refusal)
            }
        }
    }

    func cancelDelete() {
        deletionPlanTask?.cancel()
        deletionPlanTask = nil
        pendingDeletion = nil
    }

    func confirmDelete() {
        guard let plan = pendingDeletion else { return }
        pendingDeletion = nil
        let deleter = self.deleter
        let registry = self.registry
        if !plan.reviews.isEmpty {
            SafeLog.info(
                "Session delete: \(plan.selected.count) selected with \(plan.reviews.count) Auto Review(s), "
                    + "\(plan.totalBytes) bytes"
            )
        }
        Task { [weak self] in
            // Every file — review or not — through the deleter, so each one
            // gets the same containment, symlink and re-parsed-id checks; a
            // session whose review could not go is kept with it.
            let outcomes = await Self.performDelete(deleter: deleter, registry: registry, plan: plan)
            guard let self else { return }
            await self.finish(outcomes)
        }
    }

    private nonisolated static func performDelete(
        deleter: SessionDeleter,
        registry: SessionProviderRegistry,
        plan: SessionDeletionCascade.Plan
    ) async -> [SessionDeleteOutcome] {
        SessionDeletionCascade.execute(plan) { deleter.delete($0, registry: registry) }
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
    /// Auto Review rows by parent, on a read-only connection of its own —
    /// shared by the Sessions page and the MCP session tools so the two read
    /// the same answer. See `SessionReviewIndex`.
    let reviews = SessionReviewIndex(databaseURL: VibeBarLocalStore.sessionIndexURL)
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
