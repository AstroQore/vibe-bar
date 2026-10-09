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
    /// Changes whenever the turn list should be built anew rather than
    /// diffed: with `contentToken`, and on a jump out of the window, where
    /// replacing every row of the old window one by one cost more than a
    /// new list.
    public private(set) var listToken = 0
    public private(set) var subagentLinks: [SessionSubagentLink] = []
    public private(set) var verdictTotals = VerdictTotals()
    public private(set) var notice: Notice?

    // MARK: Configuration

    public let pageSize: Int
    /// Turns the conversation opens with. Smaller than a page on purpose:
    /// landing on the end of a lazy list lays out every row between, so the
    /// first window is what opening a session costs.
    public let initialTurns: Int
    /// Of those, the turns the first frame draws; the rest follow a frame
    /// later, above them.
    public let firstFrameTurns: Int
    public let maxSpan: Int
    public let markdown: SessionMarkdownCache
    /// The sizes turn text is built at; the pane sets its density's.
    @ObservationIgnored public private(set) var textStyle = SessionRichTextStyle()
    /// What turn text and contents previews are drawn with.
    public let rendering: SessionConversationRendering
    @ObservationIgnored private let source: any SessionConversationSource
    /// Told after the pane switches sessions — the selection's, or a thread
    /// opened from it — so what follows the pane (the Raw transcript) can.
    @ObservationIgnored public var onShow: (@MainActor (SessionSummary?) -> Void)?

    // MARK: Private state

    @ObservationIgnored private var outlineTurns: [SessionTurnOutline] = []
    @ObservationIgnored private var fullTurns: [SessionStructure.Turn]?
    @ObservationIgnored private var presentations: [Int: SessionTurnPresentation] = [:]
    @ObservationIgnored private var unavailableTurns: Set<Int> = []
    @ObservationIgnored private var expandedTurns: Set<Int> = []
    @ObservationIgnored private var expandedSteps: Set<String> = []
    @ObservationIgnored private var stepLimits: [Int: Int] = [:]
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
        firstFrameTurns: Int = 1,
        maxSpan: Int = 60,
        markdown: SessionMarkdownCache = SessionMarkdownCache(),
        rendering: SessionConversationRendering = .none
    ) {
        self.source = source
        self.pageSize = max(1, pageSize)
        self.initialTurns = max(1, min(initialTurns, pageSize))
        self.firstFrameTurns = max(1, firstFrameTurns)
        self.maxSpan = max(pageSize, maxSpan)
        self.markdown = markdown
        self.rendering = rendering
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
        defer { onShow?(summary) }
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
        // A session the turn view cannot read shows the raw transcript over
        // the (hidden) turn list, so its rows can wait there too: tearing them
        // down in the click's frame only made opening the raw view slower.
        if summary == nil {
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
        stepLimits = [:]
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
        let toc = await contents(of: outline.outline)
        guard generation == self.generation, !Task.isCancelled else { return }
        adopt(outline, toc: toc)
        window = .tail(total: outlineTurns.count, pageSize: pageSize, maxSpan: maxSpan, initial: initialTurns)
        phase = .ready
        rebuildItems()
        if summary.provider == .codex { loadVerdicts(summary, generation: generation) }
        enqueueTurns(window.range)
    }

    /// A file within the full-parse limit is read, sliced and presented
    /// before anything is published, and then published in three frames,
    /// none of which lays out more than its share:
    ///
    /// 1. the masthead's facts and the contents column;
    /// 2. the last `firstFrameTurns` turns, in a scroll view built on them
    ///    so it opens at the end of the conversation without a
    ///    scroll-to-end pass;
    /// 3. the rest of the first window, a turn a frame, above them.
    ///
    /// (The outline call above already parsed the file in full and left it
    /// in the service's cache, so this read is a cache hit.)
    private func loadWhole(_ summary: SessionSummary, outline: SessionStructure, generation: UInt64) async -> Bool {
        guard let full = await source.fullStructure(for: summary), full.detail == .full else { return false }
        guard generation == self.generation, !Task.isCancelled else { return true }
        let tail = SessionTurnWindow.tail(total: full.turns.count, pageSize: pageSize, maxSpan: maxSpan, initial: initialTurns)
        let turns = tail.range.map { full.turns[$0] }
        async let presented = Self.present(turns, markdown: markdown, style: textStyle, render: rendering.text)
        let toc = await contents(of: full.outline)
        let built = await presented
        guard generation == self.generation, !Task.isCancelled else { return true }

        fullTurns = full.turns
        adopt(full, toc: toc)
        update(\.subagentLinks, Self.subagentLinks(in: full.turns))
        await Self.nextFrame()
        guard generation == self.generation, !Task.isCancelled else { return true }

        let first = SessionTurnWindow.tail(
            total: full.turns.count, pageSize: pageSize, maxSpan: maxSpan,
            initial: min(firstFrameTurns, initialTurns)
        )
        update(\.window, first)
        for index in first.range {
            if let presentation = built[index] { presentations[index] = presentation } else { unavailableTurns.insert(index) }
        }
        update(\.phase, .ready)
        rebuildItems()
        initialScrollPending = false
        contentToken &+= 1
        listToken &+= 1

        // The rest of the first window, a turn a frame, above what is on
        // screen. The view rests on the end of the conversation, which a
        // scroll view keeps still while content grows above it.
        var window = first
        while window.range.lowerBound > tail.range.lowerBound {
            await Self.nextFrame()
            // Not if the reader has moved the window meanwhile (a jump from
            // the contents, a page): the window is theirs now.
            guard generation == self.generation, !Task.isCancelled, self.window == window else { return true }
            window = SessionTurnWindow(
                total: window.total,
                lowerBound: window.range.lowerBound - 1,
                upperBound: window.range.upperBound,
                pageSize: pageSize,
                maxSpan: maxSpan
            )
            let index = window.range.lowerBound
            if let presentation = built[index] { presentations[index] = presentation } else { unavailableTurns.insert(index) }
            update(\.window, window)
            rebuildItems()
        }
        return true
    }

    /// The contents column's entries, measured off the main actor.
    func contents(of outline: [SessionTurnOutline]) async -> [SessionConversationTOCEntry] {
        let measure = rendering.previewWidth
        return await Task.detached(priority: .userInitiated) {
            SessionConversationTOCEntry.measuredEntries(from: outline, measure: measure)
        }.value
    }

    /// Let the run loop draw what was just published before publishing more.
    static func nextFrame() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func adopt(_ structure: SessionStructure, toc: [SessionConversationTOCEntry]? = nil) {
        update(\.stats, structure.stats)
        outlineTurns = structure.outline
        update(\.toc, toc ?? SessionConversationTOCEntry.measuredEntries(from: outlineTurns, measure: rendering.previewWidth))
        update(\.tocTotals, SessionConversationTOCEntry.totals(self.toc))
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
                let built = await Self.present(turns, markdown: markdown, style: textStyle, render: rendering.text)
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
                let built = await Self.present([turn], markdown: markdown, style: textStyle, render: rendering.text)
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
        markdown: SessionMarkdownCache,
        style: SessionRichTextStyle,
        render: (@Sendable (SessionMarkdownDocument, CGFloat) -> AnyObject)?
    ) async -> [Int: SessionTurnPresentation] {
        guard !turns.isEmpty else { return [:] }
        let handle = Task.detached(priority: .userInitiated) { () -> [Int: SessionTurnPresentation] in
            var out: [Int: SessionTurnPresentation] = [:]
            for turn in turns {
                if Task.isCancelled { break }
                out[turn.index] = SessionTurnPresentation.make(turn, markdown: markdown, style: style, render: render)
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
        if !isWindowed, fullTurns != nil {
            var page = window
            grow(page.extendEarlier(), earlier: true)
            return
        }
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
        if !isWindowed, fullTurns != nil {
            var page = window
            grow(page.extendLater(), earlier: false)
            return
        }
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

    /// A page of a file held in memory: presented off the main actor while
    /// the edge row shows it is coming, then let into the window a turn a
    /// frame, the one next to what is on screen first — a page at once was
    /// forty rows for one frame to lay out.
    private func grow(_ added: Range<Int>, earlier: Bool) {
        guard let fullTurns, !added.isEmpty else { return }
        if earlier { isLoadingEarlier = true } else { isLoadingLater = true }
        rebuildItems()
        let turns = added.filter { fullTurns.indices.contains($0) }.map { fullTurns[$0] }
        let order = earlier ? Array(added.reversed()) : Array(added)
        let generation = self.generation
        let previous = turnsTask
        turnsTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            let built = await Self.present(turns, markdown: self.markdown, style: self.textStyle, render: self.rendering.text)
            for (position, index) in order.enumerated() {
                if position > 0 { await Self.nextFrame() }
                guard !Task.isCancelled, generation == self.generation else { return }
                // A jump from the contents replaced the window meanwhile:
                // the rest of this page is no longer next to it.
                guard index == (earlier ? self.window.range.lowerBound - 1 : self.window.range.upperBound) else { break }
                if earlier { self.window.extendEarlier(by: 1) } else { self.window.extendLater(by: 1) }
                if let presentation = built[index] { self.presentations[index] = presentation } else { self.unavailableTurns.insert(index) }
                self.trimPresentations()
                self.rebuildItems()
            }
            if earlier { self.isLoadingEarlier = false } else { self.isLoadingLater = false }
            self.rebuildItems()
        }
    }

    /// Bring `turn` into the window and ask the view to scroll to it.
    public func reveal(turn: Int) {
        guard phase == .ready, outlineTurns.indices.contains(turn) else { return }
        if !window.contains(turn) {
            if !isWindowed, let fullTurns {
                jump(to: turn, in: fullTurns)
            } else {
                let added = window.reveal(turn)
                trimPresentations()
                rebuildItems()
                enqueueTurns(added)
            }
        }
        initialScrollPending = false
        currentTurn = turn
        requestScroll(to: SessionConversationItem.headerID(turn), anchor: .top)
    }

    /// A jump out of the window of a file held in memory. The window starts
    /// over at the turn — drawn first, at the top — and the page under it
    /// joins a turn a frame; the turns before it page in as the reader
    /// scrolls up. A whole page replaced in one frame was the slowest thing
    /// the contents column could ask for.
    private func jump(to turn: Int, in fullTurns: [SessionStructure.Turn]) {
        let upper = min(outlineTurns.count, turn + pageSize)
        window = SessionTurnWindow(total: outlineTurns.count, lowerBound: turn, upperBound: turn + 1, pageSize: pageSize, maxSpan: maxSpan)
        trimPresentations()
        isLoadingEarlier = false
        isLoadingLater = upper > turn + 1
        rebuildItems()
        listToken &+= 1
        let turns = (turn..<upper).filter { fullTurns.indices.contains($0) }.map { fullTurns[$0] }
        let generation = self.generation
        let previous = turnsTask
        turnsTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            let built = await Self.present(turns, markdown: self.markdown, style: self.textStyle, render: self.rendering.text)
            for index in turn..<upper {
                if index > turn { await Self.nextFrame() }
                guard !Task.isCancelled, generation == self.generation else { return }
                if index > turn {
                    // Another jump or a page moved the window meanwhile.
                    guard index == self.window.range.upperBound else { break }
                    self.window.extendLater(by: 1)
                } else if !self.window.contains(index) {
                    break
                }
                if let presentation = built[index] { self.presentations[index] = presentation } else { self.unavailableTurns.insert(index) }
                self.trimPresentations()
                self.rebuildItems()
            }
            self.isLoadingLater = false
            self.rebuildItems()
        }
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

    /// Steps an opening process lists in its first frame; the rest follow
    /// in the next, so opening one never lays out a screenful of rows at
    /// once.
    public static let firstFrameSteps = 6

    public func toggleProcess(turn: Int) {
        let opening = expandedTurns.remove(turn) == nil
        if opening { expandedTurns.insert(turn) }
        let staged = opening && (presentations[turn]?.steps.count ?? 0) > Self.firstFrameSteps
        if staged { stepLimits[turn] = Self.firstFrameSteps } else { stepLimits[turn] = nil }
        rebuildItems()
        // Opening a process brings its row to the top with the steps under
        // it. Left alone, a view resting at the end of the conversation
        // keeps its bottom still and pushes the row it just opened upward.
        if opening { requestScroll(to: "x\(turn)", anchor: .top) }
        guard staged else { return }
        let generation = self.generation
        Task { [weak self] in
            await Self.nextFrame()
            guard let self, generation == self.generation, self.stepLimits[turn] != nil else { return }
            self.stepLimits[turn] = nil
            self.rebuildItems()
        }
    }

    public func isProcessExpanded(turn: Int) -> Bool { expandedTurns.contains(turn) }

    // MARK: - Text style

    /// Build turn text at `style` from now on. The turns already presented
    /// are built again at it (a density change; the first call, made before
    /// anything opens, costs nothing).
    public func setTextStyle(_ style: SessionRichTextStyle) {
        guard style != textStyle else { return }
        textStyle = style
        guard phase == .ready, !presentations.isEmpty else { return }
        presentations = [:]
        rebuildItems()
        enqueueTurns(window.range)
    }

    public func toggleStep(turn: Int, position: Int) {
        let key = SessionConversationLayout.stepKey(turn: turn, position: position)
        if expandedSteps.remove(key) == nil { expandedSteps.insert(key) }
        rebuildItems()
    }

    /// Expand or collapse every loaded turn's process at once.
    public func setAllProcesses(expanded: Bool) {
        expandedTurns = expanded ? Set(presentations.keys) : []
        stepLimits = [:]
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
            stepLimits: stepLimits,
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
