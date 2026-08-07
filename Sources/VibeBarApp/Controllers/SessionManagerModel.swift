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
            case .all:   "Any time"
            case .today: "Today"
            case .week:  "7 days"
            case .month: "30 days"
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
            case .recentFirst: "Newest first"
            case .oldestFirst: "Oldest first"
            case .byProject:   "By project"
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
    struct Row: Identifiable, Hashable {
        let summary: SessionSummary
        let snippet: String?
        let matchedSeq: Int?

        var id: String { summary.id }
    }

    struct ProjectGroup: Identifiable {
        let title: String
        let rows: [Row]

        var id: String { title }
    }

    // MARK: - Published state

    @Published private(set) var summaries: [SessionSummary] = [] {
        didSet { refreshRows() }
    }
    @Published private(set) var hits: [SessionSearchHit] = [] {
        didSet { refreshRows() }
    }
    @Published private(set) var indexProgress: IndexProgress?
    @Published private(set) var isIndexAvailable = true

    /// Derived once per input change rather than per render: the list is
    /// read from three views on the page, and re-sorting a few thousand
    /// sessions inside `body` is how a keystroke starts costing frames.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var groupedRows: [ProjectGroup] = []
    @Published private(set) var providerCounts: [SessionProvider: Int] = [:]

    @Published var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearch()
            refreshRows()
        }
    }

    @Published var providerFilter: Set<SessionProvider>? {
        didSet { refreshRows() }
    }
    @Published var dateRange: DateRange = .all {
        didSet { refreshRows() }
    }
    @Published var sortOrder: SortOrder = .recentFirst {
        didSet { refreshRows() }
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
    private let store: SessionIndexStore?
    private let service: SessionIndexService?
    private let bodyIndexing: BodyIndexingFlag

    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var transcriptGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var hasActivated = false
    private var lastScanFinishedAt: Date?

    /// Floor between two automatic sweeps. A manual refresh ignores it.
    private static let rescanMinimumInterval: TimeInterval = 30

    /// Long enough that a fast typist never pays for an intermediate query,
    /// short enough that pausing to read the list feels like it already ran.
    private static let searchDebounce = Duration.milliseconds(250)
    /// The index reports per file; publishing every one of those would put
    /// thousands of main-actor hops between the user and a scroll.
    private nonisolated static let progressStride = 25

    /// `AppSettings.sessionBodyIndexingEnabled`, readable from the index
    /// actor's executor. The setting lives on the main actor and the scan
    /// does not, so the value is mirrored instead of hopping mid-pass.
    private final class BodyIndexingFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(_ value: Bool) { self.value = value }

        var current: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    init(settingsStore: SettingsStore, homeDirectory: String = RealHomeDirectory.path) {
        let registry = SessionProviderRegistry.standard(homeDirectory: homeDirectory)
        self.settingsStore = settingsStore
        self.homeDirectory = homeDirectory
        self.registry = registry
        self.deleter = SessionDeleter(homeDirectory: homeDirectory)
        let flag = BodyIndexingFlag(settingsStore.settings.sessionBodyIndexingEnabled)
        self.bodyIndexing = flag

        // Same shape as the usage ledger in `AppEnvironment`: a database that
        // will not open costs this page its index, not the app.
        let opened: SessionIndexStore?
        do {
            opened = try SessionIndexStore()
        } catch {
            SafeLog.warn("Opening the session index failed: \(SafeLog.sanitize(error.localizedDescription))")
            opened = nil
        }
        self.store = opened
        self.isIndexAvailable = opened != nil
        self.service = opened.map {
            SessionIndexService(
                homeDirectory: homeDirectory,
                store: $0,
                registry: registry,
                bodyIndexing: { flag.current }
            )
        }
    }

    // MARK: - Lifecycle

    /// Cached rows first, disk second. Re-opening the window re-scans, since
    /// the CLIs have been writing sessions the whole time it was shut — but
    /// switching between Workbench pages re-runs this too, and a full sweep
    /// of every provider's logs is not what a tab click should cost.
    func activate() {
        loadSummaries()
        guard refreshTask == nil else { return }
        if let last = lastScanFinishedAt, Date().timeIntervalSince(last) < Self.rescanMinimumInterval {
            return
        }
        hasActivated = true
        refreshIndex()
    }

    func stop() {
        searchTask?.cancel()
        refreshTask?.cancel()
        toastTask?.cancel()
        searchTask = nil
        refreshTask = nil
        toastTask = nil
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
            await service.refreshIndex(progress: progress)
            guard let self, !Task.isCancelled else { return }
            self.indexProgress = nil
            self.refreshTask = nil
            self.lastScanFinishedAt = Date()
            self.loadSummaries()
            self.rerunSearch()
        }
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
            if !cleared { self.show(toast: "The session index could not be cleared.") }
            self.summaries = []
            self.hits = []
            self.refreshIndex()
        }
    }

    private func loadSummaries() {
        guard let service else { return }
        Task { [weak self] in
            let loaded = (try? await service.allSummaries()) ?? []
            guard let self else { return }
            self.summaries = loaded
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
            hits = []
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
        let providers = providerFilter.map { Array($0).sorted { $0.rawValue < $1.rawValue } }
        let found = (try? await service.search(needle, providers: providers, limit: 200)) ?? []
        guard generation == searchGeneration else { return }
        hits = found
    }

    // MARK: - Rows

    /// What the list shows.
    ///
    /// The in-memory filter runs on every keystroke so typing never waits on
    /// SQLite; the debounced full-text pass replaces it once it lands, because
    /// only that one can match on what was said inside a session. An empty
    /// full-text result falls back rather than blanking the list — the
    /// substring filter also matches session ids, which the index does not.
    private func refreshRows() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [Row]
        if !needle.isEmpty, !hits.isEmpty {
            base = hits.map { Row(summary: $0.summary, snippet: $0.snippet, matchedSeq: $0.matchedSeq) }
        } else {
            base = filteredSummaries(matching: needle).map {
                Row(summary: $0, snippet: nil, matchedSeq: nil)
            }
        }
        rows = sorted(base.filter(passesFilters))
        groupedRows = groupByProject ? Self.grouped(rows) : []

        var counts: [SessionProvider: Int] = [:]
        for summary in summaries {
            counts[summary.provider, default: 0] += 1
        }
        providerCounts = counts
    }

    private static func grouped(_ rows: [Row]) -> [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [Row]] = [:]
        for row in rows {
            let key = projectTitle(row.summary.projectDir)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(row)
        }
        return order.map { ProjectGroup(title: $0, rows: buckets[$0] ?? []) }
    }

    static func projectTitle(_ projectDir: String?) -> String {
        guard let projectDir, !projectDir.isEmpty else { return "No project" }
        return URL(fileURLWithPath: projectDir).lastPathComponent
    }

    private func filteredSummaries(matching needle: String) -> [SessionSummary] {
        guard !needle.isEmpty else { return summaries }
        return summaries.filter { Self.matches($0, needle: needle) }
    }

    /// Case- and diacritic-insensitive substring match across everything a
    /// row shows plus the session id, which is what someone pasting an id
    /// from a CLI log is searching for.
    static func matches(_ summary: SessionSummary, needle: String) -> Bool {
        let fields = [summary.title, summary.summary, summary.projectDir, summary.sessionID]
        for field in fields {
            guard let field else { continue }
            if field.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    private func passesFilters(_ row: Row) -> Bool {
        if let providerFilter, !providerFilter.contains(row.summary.provider) { return false }
        guard let start = dateRange.start() else { return true }
        let stamp = row.summary.lastActiveAt ?? row.summary.createdAt
        guard let stamp else { return false }
        return stamp >= start
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        switch sortOrder {
        case .recentFirst:
            return rows.sorted { Self.activity($0) > Self.activity($1) }
        case .oldestFirst:
            return rows.sorted { Self.activity($0) < Self.activity($1) }
        case .byProject:
            // Key first, compare second: a localized comparison inside the
            // predicate would re-derive both project names on every swap.
            return rows
                .map { (key: Self.projectTitle($0.summary.projectDir), row: $0) }
                .sorted {
                    if $0.key != $1.key {
                        return $0.key.localizedStandardCompare($1.key) == .orderedAscending
                    }
                    return Self.activity($0.row) > Self.activity($1.row)
                }
                .map(\.row)
        }
    }

    private static func activity(_ row: Row) -> Date {
        row.summary.lastActiveAt ?? row.summary.createdAt ?? .distantPast
    }

    // MARK: - Filter mutation

    func toggleProvider(_ provider: SessionProvider) {
        var next = providerFilter ?? Set(SessionProvider.allCases)
        if next.contains(provider) { next.remove(provider) } else { next.insert(provider) }
        // Everything selected is the same statement as no filter, and saying
        // it that way keeps the chip row and the FTS query in agreement.
        setProviderFilter(next.count == SessionProvider.allCases.count ? nil : next)
    }

    func setProviderFilter(_ providers: Set<SessionProvider>?) {
        providerFilter = (providers?.isEmpty ?? true) ? nil : providers
        rerunSearch()
    }

    // MARK: - Selection

    /// Selecting a full-text hit carries the matched message with it, so the
    /// transcript opens on the line that produced the snippet instead of at
    /// the top of a session the user then has to search again by hand.
    func select(_ row: Row) {
        select(row.summary, focusSeq: row.matchedSeq)
    }

    func select(_ summary: SessionSummary?, focusSeq: Int? = nil) {
        selection = summary
        self.focusSeq = focusSeq
        transcript = nil
        transcriptError = nil
        transcriptGeneration &+= 1
        guard let summary else {
            isLoadingTranscript = false
            return
        }
        guard let adapter = registry.adapter(for: summary.provider) else {
            isLoadingTranscript = false
            transcriptError = "No reader is registered for \(summary.provider.displayName)."
            return
        }
        let generation = transcriptGeneration
        let url = URL(fileURLWithPath: summary.sourcePath)
        isLoadingTranscript = true
        Task { [weak self] in
            let parsed = await Self.parse(adapter: adapter, url: url)
            guard let self, generation == self.transcriptGeneration else { return }
            self.isLoadingTranscript = false
            self.transcript = parsed.document
            self.transcriptError = parsed.errorMessage
        }
    }

    func clearFocus() {
        focusSeq = nil
    }

    private struct ParsedTranscript: Sendable {
        let document: TranscriptDocument?
        let errorMessage: String?
    }

    /// `nonisolated` so the parse runs off the main actor — a long rollout is
    /// megabytes of JSONL and the window has to stay interactive through it.
    private nonisolated static func parse(
        adapter: any SessionProviderAdapter,
        url: URL
    ) async -> ParsedTranscript {
        do {
            return ParsedTranscript(document: try adapter.parseTranscript(fileURL: url), errorMessage: nil)
        } catch {
            return ParsedTranscript(
                document: nil,
                errorMessage: (error as? LocalizedError)?.errorDescription
                    ?? "This session's log could not be read."
            )
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
            show(toast: "This session has no resume command.")
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
            show(toast: "This session has no resume command.")
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
            show(toast: "Opened in \(target.displayName).")
        case let .copiedToClipboard(reason):
            show(toast: reason.map { "Copied to the clipboard. \($0)" } ?? "Copied to the clipboard.")
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

    /// AntiGravity holds live SQLite handles on its conversation databases,
    /// so its adapter refuses to plan a delete. Filtering those rows out here
    /// keeps the confirmation sheet from promising something that will fail.
    static func isDeletable(_ summary: SessionSummary) -> Bool {
        summary.provider != .antigravity
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
            show(toast: "AntiGravity sessions are managed by the IDE.")
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
        }
        checkedIDs.subtract(removed.map(\.id))
        loadSummaries()

        let failures = outcomes.filter { !$0.success }
        if failures.isEmpty {
            show(toast: removed.count == 1
                ? "Deleted 1 session."
                : "Deleted \(removed.count) sessions.")
        } else if let first = failures.first?.failureReason {
            show(toast: removed.isEmpty
                ? first.message
                : "Deleted \(removed.count), kept \(failures.count): \(first.message)")
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
        bodyIndexing.set(enabled)
        guard let store else { return }
        if enabled {
            refreshIndex()
            return
        }
        hits = []
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
                ? "Indexed message text removed."
                : "Clearing the indexed message text failed.")
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
