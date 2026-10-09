import AppKit
import Combine
import Foundation
import Observation
import VibeBarCore

/// The Sessions page, as three narrow models over the one
/// `SessionManagerModel` that owns the index.
///
/// `SessionManagerModel` keeps everything it already did well — paging the
/// index, search, the label scan, deletion, resume — and the page's columns
/// read the parts they draw from models of their own: the harness column
/// from `SessionNavigationModel`, the list from `SessionListModel`, the
/// conversation from `SessionConversationModel` (Core). Each is
/// `@Observable`, so a scan's progress ticking in the toolbar no longer
/// re-evaluates the list, and a stats batch landing in the list no longer
/// re-evaluates the conversation.
@MainActor
@Observable
final class SessionsPageController {
    enum ViewMode: String, Hashable {
        case turns
        case raw
    }

    @ObservationIgnored let manager: SessionManagerModel
    @ObservationIgnored let structure: SessionStructureService
    let navigation: SessionNavigationModel
    let list: SessionListModel
    let conversation: SessionConversationModel

    /// Turns or the raw transcript. Sticky across sessions; a provider the
    /// turn view cannot read always shows the transcript.
    var viewMode: ViewMode = .turns {
        didSet {
            guard viewMode != oldValue, viewMode == .raw else { return }
            manager.loadTranscriptForSelection()
        }
    }

    /// The reader's own choice for the two side columns; nil follows the
    /// window width.
    var railCollapsedChoice: Bool?
    var outlineVisibleChoice: Bool?
    /// The page's last measured width, for the toolbar's outline button to
    /// decide between the column and a popover. Not observed: nothing draws
    /// from it.
    @ObservationIgnored var pageWidth: CGFloat = 0

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(manager: SessionManagerModel, structure: SessionStructureService) {
        self.manager = manager
        self.structure = structure
        self.navigation = SessionNavigationModel(structure: structure) { [weak manager] in
            await manager?.listedSourcePathsByHarness() ?? [:]
        }
        self.list = SessionListModel(structure: structure)
        self.conversation = SessionConversationModel(
            source: SessionStructureConversationSource(
                service: structure,
                reviews: { [weak manager] summary in
                    await manager?.reviews(for: summary) ?? .empty
                },
                indexedSummary: { [weak manager] provider, sessionID in
                    await manager?.indexedSummary(provider: provider, sessionID: sessionID)
                }
            )
        )
        manager.loadsTranscriptOnSelect = { [weak self] summary in
            guard let self else { return true }
            return self.viewMode == .raw || !SessionStructureService.supports(summary.provider)
        }
        list.onListingsChanged = { [weak self] in self?.navigation.scheduleThreadCountRefresh() }
        list.onRowsChanged = { [weak self] rows in self?.selectFirstRowInDemo(rows) }
        manager.selectsFirstSummaryInDemo = false
        wire()
    }

    private func wire() {
        manager.$rows
            .sink { [weak self] rows in self?.list.ingest(rows) }
            .store(in: &cancellables)
        manager.$groupByProject
            .removeDuplicates()
            .sink { [weak self] grouped in self?.list.setGrouped(grouped) }
            .store(in: &cancellables)
        manager.$harnessCounts
            .sink { [weak self] counts in
                self?.navigation.update(counts: counts)
                // New counts mean the index moved; so may the listed set.
                self?.navigation.invalidateListedPaths()
            }
            .store(in: &cancellables)
        manager.$harnessFilter
            .sink { [weak self] filter in self?.navigation.update(selection: filter) }
            .store(in: &cancellables)
        // `@Published` fires in `willSet`, before the manager has set the
        // focus that goes with the selection; one hop to the next turn of
        // the main queue reads both settled.
        manager.$selection
            .removeDuplicates { $0?.id == $1?.id }
            .receive(on: RunLoop.main)
            .sink { [weak self] selection in
                guard let self else { return }
                // A click on a Claude subagent row selects its parent and
                // opens the thread in the same turn; the parent arriving
                // here a turn later must not replace that thread.
                if let selection, self.conversation.trail.last?.id == selection.id { return }
                self.conversation.open(selection)
            }
            .store(in: &cancellables)
    }

    /// A demo launch opens the first listed session once its stats have
    /// folded the list, so a capture shows a conversation.
    private func selectFirstRowInDemo(_ rows: [SessionListModel.DisplayRow]) {
        guard DemoMode.isEnabled, manager.selection == nil, let first = rows.first,
              first.listing != nil || !SessionStructureService.supports(first.summary.provider)
        else { return }
        manager.select(first.row)
    }

    func activate() {
        manager.activate()
        navigation.scheduleThreadCountRefresh(immediately: true)
    }

    func stop() {
        list.stop()
        conversation.stop()
        navigation.stop()
    }

    /// The session the conversation pane shows — the list highlights it.
    var displayedID: String? { conversation.summary?.id }

    func select(_ row: SessionListModel.DisplayRow) {
        guard ClaudeSubagentFiles.isSubagentSummary(row.summary) else {
            switch SessionRowClick.route(rowID: row.id, selectedID: manager.selection?.id, shownID: displayedID) {
            case .select:
                manager.select(row.row)
            case .reopen:
                // The pane shows a thread opened from this session; the
                // selection is already this row, so it will not fire again.
                conversation.open(manager.selection ?? row.summary)
            }
            return
        }
        // Not an indexed session: the pane opens it as a thread of its
        // parent, and the list selection stays where it was.
        guard let parent = list.parent(of: row) else { return }
        if manager.selection?.id != parent.id { manager.select(parent) }
        conversation.openThread(row.summary, from: parent)
    }

    // MARK: Harness column

    /// A plain click shows one harness (or every harness again, when it was
    /// the only one shown); ⌘-click adds or removes it.
    func selectHarness(_ harness: Harness, extending: Bool) {
        if extending {
            manager.toggleHarness(harness)
        } else if manager.harnessFilter == [harness] {
            manager.setHarnessFilter(nil)
        } else {
            manager.setHarnessFilter([harness])
        }
    }

    func selectAllHarnesses() {
        manager.setHarnessFilter(nil)
    }

    // MARK: Conversation actions

    /// A full-text hit opened this session; the hit is a message of the raw
    /// transcript, so that is where it can be shown.
    var hasSearchFocus: Bool { manager.focusSeq != nil }

    func showSearchHit() {
        viewMode = .raw
    }
}

// MARK: - Harness column

@MainActor
@Observable
final class SessionNavigationModel {
    struct Entry: Identifiable, Equatable {
        let harness: Harness
        let count: Int
        /// Subagent, fork and agent threads among `count`, as far as the
        /// structure sidecar has parsed.
        let threads: Int

        var id: String { harness.rawValue }
    }

    private(set) var entries: [Entry] = []
    private(set) var total = 0
    private(set) var threadTotal = 0
    /// Mirrors `SessionManagerModel.harnessFilter`: nil is every harness.
    private(set) var selection: Set<Harness>?

    @ObservationIgnored private let structure: SessionStructureService
    /// The index's listed logs by harness, the set thread counts are taken
    /// within. Read once per index generation.
    @ObservationIgnored private let listedPaths: @Sendable () async -> [Harness: Set<String>]
    @ObservationIgnored private var listedPathsCache: [Harness: Set<String>]?
    @ObservationIgnored private var counts: [Harness: Int] = [:]
    @ObservationIgnored private var threadCounts: [Harness: Int] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(structure: SessionStructureService, listedPaths: @escaping @Sendable () async -> [Harness: Set<String>]) {
        self.structure = structure
        self.listedPaths = listedPaths
    }

    func invalidateListedPaths() {
        listedPathsCache = nil
        scheduleThreadCountRefresh()
    }

    func update(counts: [Harness: Int]) {
        self.counts = counts
        rebuild()
    }

    func update(selection: Set<Harness>?) {
        guard selection != self.selection else { return }
        self.selection = selection
    }

    func isSelected(_ harness: Harness) -> Bool {
        guard let selection else { return false }
        return selection.contains(harness)
    }

    var isAllSelected: Bool { selection == nil }

    /// Thread counts come from the sidecar, which the list fills as it
    /// reads stats; re-reading it is one grouped query, debounced so a
    /// stream of stats batches costs one.
    func scheduleThreadCountRefresh(immediately: Bool = false) {
        if !immediately, refreshTask != nil { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, structure, listedPaths] in
            if !immediately { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled, let self else { return }
            let listed: [Harness: Set<String>]
            if let cached = self.listedPathsCache {
                listed = cached
            } else {
                listed = await listedPaths()
                guard !Task.isCancelled else { return }
                self.listedPathsCache = listed
            }
            let threads = await structure.threadCounts(visiblePaths: listed)
            guard !Task.isCancelled else { return }
            self.refreshTask = nil
            guard threads != self.threadCounts else { return }
            self.threadCounts = threads
            self.rebuild()
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func rebuild() {
        let present = Harness.allCases.filter { (counts[$0] ?? 0) > 0 }
        let next = present.map { harness in
            Entry(
                harness: harness,
                count: counts[harness] ?? 0,
                // Counted within the same listed rows as `count`.
                threads: min(threadCounts[harness] ?? 0, counts[harness] ?? 0)
            )
        }
        if next != entries { entries = next }
        let sum = next.reduce(0) { $0 + $1.count }
        if sum != total { total = sum }
        let threads = next.reduce(0) { $0 + $1.threads }
        if threads != threadTotal { threadTotal = threads }
    }
}

// MARK: - Session list

/// The rows the Sessions list draws: the manager's rows, with each one's
/// stats (tokens, cost, kind, parent) filled in from the structure sidecar
/// in the background, and threads folded under the session that started
/// them (`SessionThreadTree`).
///
/// Stats arrive in two passes per batch of rows — whatever the sidecar
/// already holds (one query, no parse), then a bounded parse of the misses
/// in small chunks — and each landing is coalesced into one rebuild, which
/// runs off the main actor. A row whose stats never arrive (an unsupported
/// provider, a file over the batch limit) simply shows none.
@MainActor
@Observable
final class SessionListModel {
    struct DisplayRow: Identifiable, Equatable {
        let row: SessionManagerModel.Row
        let listing: SessionStructureListing?
        /// 0 for a session of its own, ≥ 1 for a folded thread.
        let depth: Int
        /// Threads folded under this row (0 when none).
        let threadCount: Int
        let isExpanded: Bool
        /// A thread whose parent is not in the list.
        let isOrphanThread: Bool
        let isLoadingThreads: Bool
        /// The row this one is folded under.
        let parentID: String?
        /// Where the session ran, when it was not simply here (cloud-run,
        /// cloud-controlled, delegated). Unset for every row today — the slot
        /// a non-local source fills, with `cloudLink`, so such a row joins
        /// this list instead of needing a list of its own. Such a row still
        /// comes as a `SessionManagerModel.Row`: its summary's `sourcePath`
        /// may be a locator rather than a file, as Devin's already is.
        var origin: SessionRowOrigin? = nil
        /// The session on the service that ran it, for a row with no local
        /// transcript.
        var cloudLink: URL? = nil

        var id: String { row.id }
        var summary: SessionSummary { row.summary }
        var kind: SessionStructureKind? { listing?.stats.kind }
    }

    struct Group: Identifiable, Equatable {
        let bucket: SessionManagerModel.ProjectBucket
        let rows: [DisplayRow]

        var id: String { bucket.id }
    }

    private(set) var rows: [DisplayRow] = []
    private(set) var groups: [Group] = []
    private(set) var isGrouped = false
    /// Loaded rows the thread filters leave out, by kind.
    private(set) var hiddenCounts: [SessionStructureKind: Int] = [:]
    private(set) var expanded: Set<String> = []
    /// Whether any loaded row has threads to fold.
    private(set) var hasThreads = false

    var showsExec = false {
        didSet { if showsExec != oldValue { rebuild() } }
    }
    var showsAutomation = false {
        didSet { if showsAutomation != oldValue { rebuild() } }
    }

    @ObservationIgnored var onListingsChanged: (() -> Void)?
    @ObservationIgnored var onRowsChanged: (([DisplayRow]) -> Void)?
    @ObservationIgnored private let structure: SessionStructureService
    @ObservationIgnored private var source: [SessionManagerModel.Row] = []
    @ObservationIgnored private var listings: [String: SessionStructureListing] = [:]
    /// Claude subagent transcripts by parent row id, listed on expansion.
    @ObservationIgnored private var claudeChildren: [String: [SessionSummary]] = [:]
    @ObservationIgnored private var loadingChildren: Set<String> = []
    /// What has been asked of the sidecar and what is waiting.
    @ObservationIgnored private var requests = SessionListingRequests()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private var parentByID: [String: SessionSummary] = [:]

    /// Rows looked up in the sidecar per query, and rows parsed per refresh.
    private static let lookupBatch = 200
    private static let parseChunk = 12

    init(structure: SessionStructureService) {
        self.structure = structure
    }

    func ingest(_ rows: [SessionManagerModel.Row]) {
        source = rows
        rebuild()
        enqueue(rows.map(\.summary), atFront: true)
    }

    func setGrouped(_ grouped: Bool) {
        guard grouped != isGrouped else { return }
        isGrouped = grouped
        rebuild()
    }

    func stop() {
        worker?.cancel()
        worker = nil
        rebuildTask?.cancel()
        coalesceTask?.cancel()
        coalesceTask = nil
        // What was queued or being read, and not answered, is asked for
        // again next time — the batch in flight included.
        requests.cancel()
    }

    func listing(for summary: SessionSummary) -> SessionStructureListing? {
        listings[summary.sourcePath]
    }

    func parent(of row: DisplayRow) -> SessionSummary? {
        parentByID[row.id]
    }

    // MARK: Expansion

    func toggleExpanded(_ row: DisplayRow) {
        if expanded.remove(row.id) == nil {
            expanded.insert(row.id)
            if row.summary.provider == .claude, claudeChildren[row.id] == nil {
                loadClaudeChildren(of: row)
            }
        }
        rebuild()
    }

    func setAllExpanded(_ open: Bool) {
        expanded = open ? Set(rows.filter { $0.depth == 0 && $0.threadCount > 0 }.map(\.id)) : []
        for row in rows where open && row.summary.provider == .claude && row.threadCount > 0 && claudeChildren[row.id] == nil {
            loadClaudeChildren(of: row)
        }
        rebuild()
    }

    private func loadClaudeChildren(of row: DisplayRow) {
        let parent = row.summary
        let id = row.id
        loadingChildren.insert(id)
        Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                ClaudeSubagentFiles.list(parentLog: parent.sourcePath)
            }.value
            guard let self else { return }
            let children = entries.map { ClaudeSubagentFiles.summary(for: $0, parent: parent) }
            self.claudeChildren[id] = children
            self.loadingChildren.remove(id)
            self.rebuild()
            self.enqueue(children, atFront: true)
        }
    }

    // MARK: Stats

    private func enqueue(_ summaries: [SessionSummary], atFront: Bool) {
        guard requests.enqueue(summaries, atFront: atFront) else { return }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            // A stopped worker leaves the slot alone: `stop()` cleared it,
            // and a newer worker may hold it by now.
            guard let self, !Task.isCancelled else { return }
            self.worker = nil
        }
    }

    private func drain() async {
        while !Task.isCancelled, requests.hasQueued {
            let batch = requests.takeBatch(limit: Self.lookupBatch)
            let cached = await structure.listings(for: batch)
            guard !Task.isCancelled else { return }
            merge(cached)
            let misses = batch.filter { cached[$0.sourcePath] == nil }
            var start = 0
            while start < misses.count {
                guard !Task.isCancelled else { return }
                let chunk = Array(misses[start..<min(misses.count, start + Self.parseChunk)])
                start += chunk.count
                _ = await structure.refresh(summaries: chunk)
                guard !Task.isCancelled else { return }
                merge(await structure.listings(for: chunk))
                // A fresher page asked for its rows first; serve it.
                if let next = requests.queue.first, !batch.contains(where: { $0.sourcePath == next.sourcePath }) {
                    requests.requeue(Array(misses[start...]))
                    break
                }
            }
            requests.finishBatch()
        }
    }

    private func merge(_ found: [String: SessionStructureListing]) {
        var changed = false
        for (path, listing) in found where listings[path] != listing {
            listings[path] = listing
            changed = true
        }
        guard changed else { return }
        onListingsChanged?()
        // Batches land in bursts; one rebuild covers a burst.
        guard coalesceTask == nil else { return }
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.coalesceTask = nil
            self.rebuild()
        }
    }

    // MARK: Rebuild

    private struct BuildInput: Sendable {
        let rows: [SessionManagerModel.Row]
        let listings: [String: SessionStructureListing]
        let claudeChildren: [String: [SessionSummary]]
        let loadingChildren: Set<String>
        let expanded: Set<String>
        let showing: Set<SessionStructureKind>
        let grouped: Bool
    }

    private struct BuildOutput: Sendable {
        let rows: [DisplayRow]
        let groups: [Group]
        let hidden: [SessionStructureKind: Int]
        let parents: [String: SessionSummary]
        let hasThreads: Bool
    }

    private func rebuild() {
        var showing: Set<SessionStructureKind> = []
        if showsExec { showing.insert(.exec) }
        if showsAutomation { showing.insert(.automation) }
        let input = BuildInput(
            rows: source,
            listings: listings,
            claudeChildren: claudeChildren,
            loadingChildren: loadingChildren,
            expanded: expanded,
            showing: showing,
            grouped: isGrouped
        )
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { Self.build(input) }.value
            guard let self, !Task.isCancelled else { return }
            if self.rows != output.rows {
                self.rows = output.rows
                self.onRowsChanged?(output.rows)
            }
            if self.groups != output.groups { self.groups = output.groups }
            if self.hiddenCounts != output.hidden { self.hiddenCounts = output.hidden }
            if self.hasThreads != output.hasThreads { self.hasThreads = output.hasThreads }
            self.parentByID = output.parents
        }
    }

    private nonisolated static func build(_ input: BuildInput) -> BuildOutput {
        let entries = input.rows.map { row -> SessionThreadTree.Entry in
            let stats = input.listings[row.summary.sourcePath]?.stats
            return SessionThreadTree.Entry(
                id: row.id,
                sessionID: row.summary.sessionID,
                kind: stats?.kind,
                parentID: stats?.parentID
            )
        }
        let tree = SessionThreadTree(entries: entries, showing: input.showing)
        var byID: [String: SessionManagerModel.Row] = [:]
        byID.reserveCapacity(input.rows.count)
        for row in input.rows { byID[row.id] = row }

        var out: [DisplayRow] = []
        out.reserveCapacity(tree.roots.count)
        var parents: [String: SessionSummary] = [:]
        var rootsInOrder: [(root: DisplayRow, children: [DisplayRow])] = []
        var hasThreads = false
        for node in tree.roots {
            guard let row = byID[node.id] else { continue }
            let listing = input.listings[row.summary.sourcePath]
            let claudeKids = input.claudeChildren[node.id]
            var threadCount = node.descendants.count
            if row.summary.provider == .claude {
                threadCount += claudeKids?.count ?? (listing?.stats.subagentCount ?? 0)
            }
            if threadCount > 0 { hasThreads = true }
            let isExpanded = input.expanded.contains(node.id) && threadCount > 0
            let root = DisplayRow(
                row: row,
                listing: listing,
                depth: 0,
                threadCount: threadCount,
                isExpanded: isExpanded,
                isOrphanThread: node.isOrphanThread,
                isLoadingThreads: isExpanded && input.loadingChildren.contains(node.id),
                parentID: nil
            )
            var children: [DisplayRow] = []
            if isExpanded {
                for id in node.descendants {
                    guard let child = byID[id] else { continue }
                    children.append(DisplayRow(
                        row: child,
                        listing: input.listings[child.summary.sourcePath],
                        depth: tree.depth(of: id),
                        threadCount: 0,
                        isExpanded: false,
                        isOrphanThread: false,
                        isLoadingThreads: false,
                        parentID: node.id
                    ))
                    parents[id] = row.summary
                }
                for kid in claudeKids ?? [] {
                    let kidRow = SessionManagerModel.Row(
                        summary: kid, snippet: nil, matchedSeq: nil, matchedRelated: nil, reviewCount: 0
                    )
                    children.append(DisplayRow(
                        row: kidRow,
                        listing: input.listings[kid.sourcePath],
                        depth: 1,
                        threadCount: 0,
                        isExpanded: false,
                        isOrphanThread: false,
                        isLoadingThreads: false,
                        parentID: node.id
                    ))
                    parents[kidRow.id] = row.summary
                }
            }
            rootsInOrder.append((root, children))
            out.append(root)
            out.append(contentsOf: children)
        }

        var groups: [Group] = []
        if input.grouped {
            var order: [SessionManagerModel.ProjectBucket] = []
            var buckets: [SessionManagerModel.ProjectBucket: [DisplayRow]] = [:]
            for entry in rootsInOrder {
                let key = SessionManagerModel.projectBucket(for: entry.root.summary)
                if buckets[key] == nil {
                    buckets[key] = []
                    order.append(key)
                }
                buckets[key]?.append(entry.root)
                buckets[key]?.append(contentsOf: entry.children)
            }
            groups = order.map { Group(bucket: $0, rows: buckets[$0] ?? []) }
        }
        return BuildOutput(rows: out, groups: groups, hidden: tree.hiddenCounts, parents: parents, hasThreads: hasThreads)
    }
}
