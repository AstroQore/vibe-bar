import Foundation
import Observation

/// Where the Sessions page's conversation pane reads a session's structure
/// from. `SessionStructureConversationSource` is the app's; tests hand in
/// synthetic structures.
public protocol SessionConversationSource: Sendable {
    /// Files above this are read one turn window at a time.
    var fullParseLimitBytes: Int64 { get }
    func supports(_ provider: SessionProvider) -> Bool
    func fileSize(of summary: SessionSummary) async -> Int64?
    /// Outline detail: stats and every turn's boundaries, counts and preview.
    func outline(for summary: SessionSummary) async -> SessionStructure?
    /// Full detail, for a file at or under `fullParseLimitBytes`.
    func fullStructure(for summary: SessionSummary) async -> SessionStructure?
    /// One turn in full detail, read from its byte window.
    func turn(at index: Int, for summary: SessionSummary) async -> SessionStructure.Turn?
    /// The session's Auto Review count and their verdicts by the parent turn
    /// id each names.
    func reviewVerdicts(for summary: SessionSummary) async -> SessionReviewVerdicts
    /// The session a subagent step points at.
    func childSummary(childID: String, parent: SessionSummary) async -> SessionSummary?
}

/// A subagent the open conversation started, for the jump menu.
public struct SessionSubagentLink: Sendable, Hashable, Identifiable {
    public var childID: String
    public var turn: Int
    /// The task the agent was given, or the tool name.
    public var label: String

    public var id: String { childID }
}

/// State behind the Sessions page's conversation pane: one session, read as
/// turns and steps.
///
/// **Tail first.** A conversation opens on its last `pageSize` turns
/// (`SessionTurnWindow`); scrolling up pages earlier turns in, and the
/// outline can jump anywhere. The outline itself — every turn's boundaries,
/// counts and prompt preview — comes first and is cheap (the sidecar, or
/// one parse that also fills the in-memory cache), so the header, the
/// meta strip and the table of contents are on screen before any turn body
/// is.
///
/// **Two read paths.** A file up to `fullParseLimitBytes` is parsed whole
/// once and its turns are sliced from that. A larger one is never held
/// whole: each turn in the window is read from its own byte window
/// (`turn(at:)`), most recent first, and the pane shows progress and can be
/// stopped.
///
/// **Nothing is derived in a view.** Markdown is parsed off the main actor
/// into `SessionTurnPresentation`s, cached by text; the render list
/// (`items`) is rebuilt in one O(rows) pass whenever the window, an
/// expansion or a presentation changes, and every row carries the value it
/// draws so an unchanged row is never re-evaluated.
@MainActor
@Observable
public final class SessionConversationModel {
    public enum Phase: Sendable, Equatable {
        case idle
        /// No structure parser for this provider — the raw transcript is the
        /// view.
        case unsupported
        /// Waiting for the outline.
        case loading
        case ready
        case unreadable
        case cancelled
    }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    /// A scroll the view should perform. `token` makes two requests for the
    /// same row distinct.
    public struct ScrollRequest: Sendable, Equatable {
        public enum Anchor: Sendable, Equatable {
            /// The row's top at the top of the viewport (an outline jump).
            case top
            /// The row's bottom at the bottom of the viewport (the end of the
            /// conversation, once the first turns have arrived).
            case bottom
        }

        public var itemID: String
        public var anchor: Anchor
        public var token: Int
    }

    public struct VerdictTotals: Sendable, Equatable {
        /// Auto Reviews of this session — the list row's and MCP's number.
        public var reviews = 0
        public var allow = 0
        public var deny = 0
        public var total: Int { allow + deny }
    }

    public enum Notice: Sendable, Equatable {
        /// A subagent step's thread could not be found on disk or in the
        /// index.
        case childNotFound(String)
    }

    // MARK: Published

    public private(set) var summary: SessionSummary?
    public private(set) var phase: Phase = .idle
    public private(set) var stats: SessionStats?
    public private(set) var toc: [SessionConversationTOCEntry] = []
    /// `toc`'s sums, kept with it (`SessionConversationTOCEntry.totals`).
    public private(set) var tocTotals = SessionConversationTOCEntry.Totals()
    public private(set) var items: [SessionConversationItem] = []
    public private(set) var window: SessionTurnWindow
    /// Turn reads still to come, for a windowed file.
    public private(set) var progress: Progress?
    /// The file is above the full-parse limit and is read turn by turn.
    public private(set) var isWindowed = false
    /// The turn at the top of the viewport.
    public private(set) var currentTurn: Int?
    /// Sessions opened before this one through a subagent step, oldest
    /// first; `back()` returns to the last.
    public private(set) var trail: [SessionSummary] = []
    public private(set) var scrollRequest: ScrollRequest?
    /// Changes when a session's first content is published in one piece. A
    /// view that keys its scroll view on this gets a fresh one built on the
    /// final content, which can open at the bottom by its initial offset —
    /// no scroll-to-end, which on a lazy list measures every row between.
    public private(set) var contentToken = 0
    public private(set) var subagentLinks: [SessionSubagentLink] = []
    public private(set) var verdictTotals = VerdictTotals()
    public private(set) var notice: Notice?

    // MARK: Configuration

    public let pageSize: Int
    /// Turns the conversation opens with. Smaller than a page on purpose:
    /// landing on the end of a lazy list lays out every row between, so the
    /// first window is what opening a session costs.
    public let initialTurns: Int
    public let maxSpan: Int
    public let markdown: SessionMarkdownCache
    @ObservationIgnored private let source: any SessionConversationSource

    // MARK: Private state

    @ObservationIgnored private var outlineTurns: [SessionTurnOutline] = []
    @ObservationIgnored private var fullTurns: [SessionStructure.Turn]?
    @ObservationIgnored private var presentations: [Int: SessionTurnPresentation] = [:]
    @ObservationIgnored private var unavailableTurns: Set<Int> = []
    @ObservationIgnored private var expandedTurns: Set<Int> = []
    @ObservationIgnored private var expandedSteps: Set<String> = []
    @ObservationIgnored private var verdictsByTurnID: [String: [SessionStructure.GuardianVerdict]] = [:]
    @ObservationIgnored private var showsModelPerTurn = false
    @ObservationIgnored private var isLoadingEarlier = false
    @ObservationIgnored private var isLoadingLater = false
    @ObservationIgnored private var pendingState: SessionTurnPending.State = .loading
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var scrollToken = 0
    /// The first window's turns have not been shown yet; when they are, the
    /// view is asked to settle on the end of the conversation.
    @ObservationIgnored private var initialScrollPending = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var turnsTask: Task<Void, Never>?
    @ObservationIgnored private var verdictTask: Task<Void, Never>?
    @ObservationIgnored private var childTask: Task<Void, Never>?

    public init(
        source: any SessionConversationSource,
        pageSize: Int = 10,
        initialTurns: Int = 4,
        maxSpan: Int = 60,
        markdown: SessionMarkdownCache = SessionMarkdownCache()
    ) {
        self.source = source
        self.pageSize = max(1, pageSize)
        self.initialTurns = max(1, min(initialTurns, pageSize))
        self.maxSpan = max(pageSize, maxSpan)
        self.markdown = markdown
        self.window = .tail(total: 0, pageSize: pageSize, maxSpan: maxSpan)
    }

    // MARK: - Opening

    /// Show `summary`, or nothing. Re-opening the session already shown is a
    /// no-op unless it failed or was stopped.
    public func open(_ summary: SessionSummary?) {
        if let summary, summary.id == self.summary?.id, trail.isEmpty,
           phase == .ready || phase == .loading || phase == .unsupported {
            return
        }
        show(summary, trail: [])
    }

    /// Read the open session again from scratch.
    public func reload() {
        show(summary, trail: trail)
    }

    /// Open the thread a subagent step started; `back()` returns here.
    public func openChild(_ childID: String) {
        guard let parent = summary else { return }
        childTask?.cancel()
        let generation = self.generation
        let trail = self.trail
        childTask = Task { [weak self, source] in
            let child = await source.childSummary(childID: childID, parent: parent)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            guard let child else {
                self.notice = .childNotFound(childID)
                return
            }
            self.show(child, trail: trail + [parent])
        }
    }

    /// Open a thread that has no row of its own in the list — a Claude
    /// subagent transcript — with `parent` on the trail.
    public func openThread(_ child: SessionSummary, from parent: SessionSummary) {
        show(child, trail: [parent])
    }

    public func back() {
        guard let parent = trail.last else { return }
        show(parent, trail: Array(trail.dropLast()))
    }

    public func clearNotice() { notice = nil }

    /// Stop everything in flight. Turns already on screen stay.
    public func stop() {
        loadTask?.cancel()
        turnsTask?.cancel()
        verdictTask?.cancel()
        childTask?.cancel()
        loadTask = nil
        turnsTask = nil
        verdictTask = nil
        childTask = nil
        progress = nil
        if phase == .loading { phase = .cancelled }
        if isLoadingEarlier || isLoadingLater || items.contains(where: Self.isLoadingPlaceholder) {
            isLoadingEarlier = false
            isLoadingLater = false
            pendingState = .stopped
            rebuildItems()
        }
    }

    /// The user's "stop": the same as `stop()`, said from the pane.
    public func cancelLoading() { stop() }

    /// Pick up a stopped window read where it left off.
    public func resumeLoading() {
        guard phase == .ready else {
            if phase == .cancelled { reload() }
            return
        }
        pendingState = .loading
        rebuildItems()
        enqueueTurns(window.range)
    }

    private func show(_ summary: SessionSummary?, trail: [SessionSummary]) {
        loadTask?.cancel()
        turnsTask?.cancel()
        verdictTask?.cancel()
        childTask?.cancel()
        generation &+= 1
        // Each assignment to an observed property notifies every view that
        // read it, changed or not — so a reset only writes what differs.
        update(\.summary, summary)
        update(\.trail, trail)
        update(\.stats, nil)
        update(\.toc, [])
        update(\.tocTotals, SessionConversationTOCEntry.Totals())
        // The previous conversation's rows stay until this one's replace
        // them (the pane covers them while it loads): clearing them here
        // tore the old list down in the click's frame and built the new one
        // in the next — two expensive frames where one suffices. Nothing
        // else of the old session survives: the masthead and contents show
        // only the new one's facts.
        if summary == nil || !source.supports(summary!.provider) {
            update(\.items, [])
        }
        update(\.progress, nil)
        update(\.isWindowed, false)
        update(\.currentTurn, nil)
        update(\.subagentLinks, [])
        update(\.verdictTotals, VerdictTotals())
        update(\.notice, nil)
        outlineTurns = []
        fullTurns = nil
        presentations = [:]
        unavailableTurns = []
        expandedTurns = []
        expandedSteps = []
        verdictsByTurnID = [:]
        showsModelPerTurn = false
        isLoadingEarlier = false
        isLoadingLater = false
        pendingState = .loading
        initialScrollPending = true
        update(\.window, .tail(total: 0, pageSize: pageSize, maxSpan: maxSpan))
        guard let summary else {
            update(\.phase, .idle)
            return
        }
        guard source.supports(summary.provider) else {
            update(\.phase, .unsupported)
            return
        }
        update(\.phase, .loading)
        let generation = self.generation
        loadTask = Task { [weak self] in
            await self?.loadOutline(summary, generation: generation)
        }
    }

    private func loadOutline(_ summary: SessionSummary, generation: UInt64) async {
        let size = await source.fileSize(of: summary)
        guard generation == self.generation, !Task.isCancelled else { return }
        let outline = await source.outline(for: summary)
        guard generation == self.generation, !Task.isCancelled else { return }
        guard let outline else {
            phase = .unreadable
            return
        }
        isWindowed = (size ?? 0) > source.fullParseLimitBytes
        if !isWindowed, await loadWhole(summary, outline: outline, generation: generation) {
            if summary.provider == .codex { loadVerdicts(summary, generation: generation) }
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        adopt(outline)
        window = .tail(total: outlineTurns.count, pageSize: pageSize, maxSpan: maxSpan, initial: initialTurns)
        phase = .ready
        rebuildItems()
        if summary.provider == .codex { loadVerdicts(summary, generation: generation) }
        enqueueTurns(window.range)
    }

    /// A file within the full-parse limit is read, sliced and presented
    /// before anything is published, and then published in one assignment:
    /// the pane's first layout is its final one, so it opens at the end of
    /// the conversation instead of settling there through a placeholder
    /// pass. (The outline call above already parsed the file in full and
    /// left it in the service's cache, so this read is a cache hit.)
    private func loadWhole(_ summary: SessionSummary, outline: SessionStructure, generation: UInt64) async -> Bool {
        guard let full = await source.fullStructure(for: summary), full.detail == .full else { return false }
        guard generation == self.generation, !Task.isCancelled else { return true }
        let tail = SessionTurnWindow.tail(total: full.turns.count, pageSize: pageSize, maxSpan: maxSpan, initial: initialTurns)
        let turns = tail.range.map { full.turns[$0] }
        let built = await Self.present(turns, markdown: markdown)
        guard generation == self.generation, !Task.isCancelled else { return true }
        fullTurns = full.turns
        adopt(full)
        update(\.subagentLinks, Self.subagentLinks(in: full.turns))
        update(\.window, tail)
        presentations = built
        for index in tail.range where built[index] == nil { unavailableTurns.insert(index) }
        update(\.phase, .ready)
        rebuildItems()
        initialScrollPending = false
        contentToken &+= 1
        return true
    }

    private func adopt(_ structure: SessionStructure) {
        update(\.stats, structure.stats)
        outlineTurns = structure.outline
        update(\.toc, SessionConversationTOCEntry.entries(from: outlineTurns))
        update(\.tocTotals, SessionConversationTOCEntry.totals(toc))
        showsModelPerTurn = Set(outlineTurns.compactMap(\.model)).count > 1
    }

    // MARK: - Turn bodies

    /// Turn reads run one after another, in request order, so a page asked
    /// for while the first window is still loading waits behind it instead
    /// of racing it for the same file.
    private func enqueueTurns(_ range: Range<Int>, onFinish: (@MainActor () -> Void)? = nil) {
        guard let summary else { return }
        let previous = turnsTask
        let generation = self.generation
        turnsTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            await self.loadTurns(range, summary: summary, generation: generation)
            guard !Task.isCancelled, generation == self.generation else { return }
            onFinish?()
        }
    }

    private func loadTurns(_ range: Range<Int>, summary: SessionSummary, generation: UInt64) async {
        let wanted = range.filter { presentations[$0] == nil && window.contains($0) }
        guard !wanted.isEmpty else { return }
        pendingState = .loading
        if !isWindowed {
            if fullTurns == nil {
                let full = await source.fullStructure(for: summary)
                guard generation == self.generation, !Task.isCancelled else { return }
                if let full, full.detail == .full {
                    fullTurns = full.turns
                    if full.turns.count != outlineTurns.count {
                        // The file moved between the two reads; the full
                        // parse is the newer reading.
                        adopt(full)
                        window.resize(total: outlineTurns.count)
                    }
                    subagentLinks = Self.subagentLinks(in: full.turns)
                } else {
                    // Grew past the limit since the outline was read.
                    isWindowed = true
                }
            }
            if let fullTurns {
                let turns = wanted.filter { fullTurns.indices.contains($0) }.map { fullTurns[$0] }
                let built = await Self.present(turns, markdown: markdown)
                guard generation == self.generation, !Task.isCancelled else { return }
                for (index, presentation) in built { presentations[index] = presentation }
                for index in wanted where built[index] == nil { unavailableTurns.insert(index) }
                rebuildItems()
                settleInitialScroll()
                return
            }
        }
        // Windowed: newest first, so the bottom of the pane fills first.
        progress = Progress(done: 0, total: wanted.count)
        for index in wanted.reversed() {
            guard !Task.isCancelled, generation == self.generation else { return }
            let turn = await source.turn(at: index, for: summary)
            guard !Task.isCancelled, generation == self.generation else { return }
            if let turn {
                let built = await Self.present([turn], markdown: markdown)
                guard generation == self.generation else { return }
                if let presentation = built.values.first {
                    var placed = presentation
                    placed.index = index
                    presentations[index] = placed
                    mergeSubagentLinks(from: turn, index: index)
                }
            } else {
                unavailableTurns.insert(index)
            }
            progress?.done += 1
            rebuildItems()
            settleInitialScroll()
        }
        progress = nil
    }

    private func settleInitialScroll() {
        guard initialScrollPending, let last = items.last else { return }
        initialScrollPending = false
        requestScroll(to: last.id, anchor: .bottom)
    }

    nonisolated static func present(
        _ turns: [SessionStructure.Turn],
        markdown: SessionMarkdownCache
    ) async -> [Int: SessionTurnPresentation] {
        guard !turns.isEmpty else { return [:] }
        let handle = Task.detached(priority: .userInitiated) { () -> [Int: SessionTurnPresentation] in
            var out: [Int: SessionTurnPresentation] = [:]
            for turn in turns {
                if Task.isCancelled { break }
                out[turn.index] = SessionTurnPresentation.make(turn, markdown: markdown)
            }
            return out
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    static func subagentLinks(in turns: [SessionStructure.Turn]) -> [SessionSubagentLink] {
        var seen: Set<String> = []
        var out: [SessionSubagentLink] = []
        for turn in turns {
            for step in turn.steps where step.kind == .subagent {
                guard let child = step.childSessionID, seen.insert(child).inserted else { continue }
                out.append(SessionSubagentLink(childID: child, turn: turn.index, label: step.argsSummary ?? step.name))
            }
        }
        return out
    }

    private func mergeSubagentLinks(from turn: SessionStructure.Turn, index: Int) {
        var placed = turn
        placed.index = index
        let found = Self.subagentLinks(in: [placed])
        guard !found.isEmpty else { return }
        let known = Set(subagentLinks.map(\.childID))
        let merged = subagentLinks + found.filter { !known.contains($0.childID) }
        subagentLinks = merged.sorted { $0.turn < $1.turn }
    }

    private func loadVerdicts(_ summary: SessionSummary, generation: UInt64) {
        verdictTask = Task { [weak self, source] in
            let verdicts = await source.reviewVerdicts(for: summary)
            guard let self, !Task.isCancelled, generation == self.generation,
                  verdicts.reviewCount > 0 || !verdicts.byTurnID.isEmpty
            else { return }
            self.verdictsByTurnID = verdicts.byTurnID
            let all = verdicts.byTurnID.values.flatMap { $0 }
            self.update(\.verdictTotals, VerdictTotals(
                reviews: verdicts.reviewCount,
                allow: all.count(where: { !$0.isDenied }),
                deny: all.count(where: \.isDenied)
            ))
            self.rebuildItems()
        }
    }

    // MARK: - Paging

    public func loadEarlier() {
        guard phase == .ready, window.hasEarlier, !isLoadingEarlier else { return }
        let added = window.extendEarlier()
        trimPresentations()
        isLoadingEarlier = true
        rebuildItems()
        enqueueTurns(added) { [weak self] in
            guard let self else { return }
            self.isLoadingEarlier = false
            self.rebuildItems()
        }
    }

    public func loadLater() {
        guard phase == .ready, window.hasLater, !isLoadingLater else { return }
        let added = window.extendLater()
        trimPresentations()
        isLoadingLater = true
        rebuildItems()
        enqueueTurns(added) { [weak self] in
            guard let self else { return }
            self.isLoadingLater = false
            self.rebuildItems()
        }
    }

    /// Bring `turn` into the window and ask the view to scroll to it.
    public func reveal(turn: Int) {
        guard phase == .ready, outlineTurns.indices.contains(turn) else { return }
        if !window.contains(turn) {
            let added = window.reveal(turn)
            trimPresentations()
            rebuildItems()
            enqueueTurns(added)
        }
        initialScrollPending = false
        currentTurn = turn
        requestScroll(to: SessionConversationItem.headerID(turn), anchor: .top)
    }

    /// Back to the end of the conversation.
    public func revealLatest() {
        guard phase == .ready, let last = outlineTurns.indices.last else { return }
        reveal(turn: last)
    }

    /// Turns that left the window are dropped; a small file re-presents them
    /// from memory and a large one re-reads its window.
    private func trimPresentations() {
        let range = window.range
        presentations = presentations.filter { range.contains($0.key) }
        unavailableTurns = unavailableTurns.filter { range.contains($0) }
    }

    // MARK: - Expansion

    public func toggleProcess(turn: Int) {
        if expandedTurns.remove(turn) == nil { expandedTurns.insert(turn) }
        rebuildItems()
    }

    public func isProcessExpanded(turn: Int) -> Bool { expandedTurns.contains(turn) }

    public func toggleStep(turn: Int, position: Int) {
        let key = SessionConversationLayout.stepKey(turn: turn, position: position)
        if expandedSteps.remove(key) == nil { expandedSteps.insert(key) }
        rebuildItems()
    }

    /// Expand or collapse every loaded turn's process at once.
    public func setAllProcesses(expanded: Bool) {
        expandedTurns = expanded ? Set(presentations.keys) : []
        rebuildItems()
    }

    // MARK: - Viewport

    /// The rows currently on screen (`onScrollTargetVisibilityChange`). The
    /// earliest turn among them is the current one.
    public func noteVisible(_ ids: [String]) {
        let turn = ids.compactMap(SessionConversationItem.turnIndex(forID:)).min()
        guard let turn, turn != currentTurn else { return }
        currentTurn = turn
    }

    /// The turn being read, as the view measured it.
    public func noteCurrentTurn(_ turn: Int) {
        guard outlineTurns.indices.contains(turn), turn != currentTurn else { return }
        currentTurn = turn
    }

    private func requestScroll(to itemID: String, anchor: ScrollRequest.Anchor) {
        scrollToken &+= 1
        scrollRequest = ScrollRequest(itemID: itemID, anchor: anchor, token: scrollToken)
    }

    // MARK: - Render list

    private func rebuildItems() {
        update(\.items, SessionConversationLayout.items(SessionConversationLayoutInput(
            window: window,
            outline: outlineTurns,
            presentations: presentations,
            expandedTurns: expandedTurns,
            expandedSteps: expandedSteps,
            verdictsByTurnID: verdictsByTurnID,
            showsModelPerTurn: showsModelPerTurn,
            isLoadingEarlier: isLoadingEarlier,
            isLoadingLater: isLoadingLater,
            pendingState: pendingState,
            unavailableTurns: unavailableTurns
        )))
    }

    /// Assign only when the value moved: observation has no equality check
    /// of its own, and a no-op write still wakes every reader.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SessionConversationModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func isLoadingPlaceholder(_ item: SessionConversationItem) -> Bool {
        if case let .pending(pending) = item { return pending.state == .loading }
        return false
    }

    // MARK: - Introspection (tests, diagnostics)

    public var loadedTurnIndices: [Int] { presentations.keys.sorted() }
    public var turnCount: Int { outlineTurns.count }
    public func presentation(turn: Int) -> SessionTurnPresentation? { presentations[turn] }
}

// MARK: - Live source

/// The app's conversation source: `SessionStructureService` for the
/// structure, the session index for Codex threads and Auto Reviews, and the
/// parent log's own folder for Claude subagents.
public struct SessionStructureConversationSource: SessionConversationSource {
    public let service: SessionStructureService
    public let fullParseLimitBytes: Int64
    /// The Auto Review rollouts of a Codex session and their count
    /// (`SessionReviewIndex.reviewSet`).
    let reviews: @Sendable (SessionSummary) async -> SessionReviewSet
    /// An indexed session by provider and id.
    let indexedSummary: @Sendable (SessionProvider, String) async -> SessionSummary?

    public init(
        service: SessionStructureService,
        reviews: @escaping @Sendable (SessionSummary) async -> SessionReviewSet,
        indexedSummary: @escaping @Sendable (SessionProvider, String) async -> SessionSummary?
    ) {
        self.service = service
        self.fullParseLimitBytes = service.configuration.fullParseLimitBytes
        self.reviews = reviews
        self.indexedSummary = indexedSummary
    }

    public func supports(_ provider: SessionProvider) -> Bool {
        SessionStructureService.supports(provider)
    }

    public func fileSize(of summary: SessionSummary) async -> Int64? {
        let path = summary.sourcePath
        return await Task.detached(priority: .userInitiated) {
            SessionFileFingerprint.of(path: path)?.size
        }.value
    }

    public func outline(for summary: SessionSummary) async -> SessionStructure? {
        await service.outline(for: summary)
    }

    public func fullStructure(for summary: SessionSummary) async -> SessionStructure? {
        await service.structure(for: summary, detail: .full)
    }

    public func turn(at index: Int, for summary: SessionSummary) async -> SessionStructure.Turn? {
        await service.turn(at: index, for: summary)
    }

    public func reviewVerdicts(for summary: SessionSummary) async -> SessionReviewVerdicts {
        let found = await reviews(summary)
        guard found.count > 0, !Task.isCancelled else { return .none }
        let verdicts = await service.reviewVerdicts(for: found.reviews)
        return SessionReviewVerdicts(reviewCount: found.count, byTurnID: verdicts)
    }

    public func childSummary(childID: String, parent: SessionSummary) async -> SessionSummary? {
        switch parent.provider {
        case .claude:
            let root = ClaudeSubagentFiles.isSubagentSummary(parent) ? nil : parent
            guard let root else { return nil }
            return await Task.detached(priority: .userInitiated) {
                ClaudeSubagentFiles.summary(agentID: childID, parent: root)
            }.value
        case .codex:
            return await indexedSummary(.codex, childID)
        default:
            return nil
        }
    }
}
