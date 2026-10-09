import XCTest
@testable import VibeBarCore

/// The Sessions page's pure building blocks: Markdown blocks and their
/// cache, the turn window, thread folding, the outline and render list.
/// Synthetic data throughout.
final class SessionWorkbenchTests: XCTestCase {
    // MARK: - Markdown

    func testMarkdownSplitsBlocks() {
        let text = """
        # Title
        Intro line one
        line two

        - first
          continued
        - second
            - nested
        1. one
        2) two

        > quoted
        > more

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        Tail with `code` and **bold**.
        """
        let blocks = SessionMarkdown.document(from: text).blocks
        guard blocks.count == 12 else { return XCTFail("blocks: \(blocks)") }
        XCTAssertEqual(blocks[0], .heading(level: 1, text: AttributedString("Title")))
        if case let .paragraph(intro) = blocks[1] {
            XCTAssertEqual(String(intro.characters), "Intro line one\nline two")
        } else { XCTFail("intro") }
        if case let .listItem(ordinal, depth, text) = blocks[2] {
            XCTAssertNil(ordinal)
            XCTAssertEqual(depth, 0)
            XCTAssertEqual(String(text.characters), "first\ncontinued")
        } else { XCTFail("first item") }
        if case let .listItem(_, depth, _) = blocks[4] { XCTAssertEqual(depth, 2) } else { XCTFail("nested") }
        if case let .listItem(ordinal, _, _) = blocks[5] { XCTAssertEqual(ordinal, 1) } else { XCTFail("ordered") }
        if case let .listItem(ordinal, _, _) = blocks[6] { XCTAssertEqual(ordinal, 2) } else { XCTFail("paren") }
        if case let .quote(quote) = blocks[7] {
            XCTAssertEqual(String(quote.characters), "quoted\nmore")
        } else { XCTFail("quote") }
        XCTAssertEqual(blocks[8], .code(language: "swift", text: "let x = 1"))
        XCTAssertEqual(blocks[9], .table(
            header: [AttributedString("a"), AttributedString("b")],
            rows: [[AttributedString("1"), AttributedString("2")]]
        ))
        XCTAssertEqual(blocks[10], .rule)
        guard case let .paragraph(tail) = blocks[11] else { return XCTFail("tail: \(blocks[11])") }
        let codeRuns = tail.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(codeRuns.count, 1)
        let strongRuns = tail.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(strongRuns.count, 1)
    }

    func testMarkdownRuleAndUnclosedFence() {
        let blocks = SessionMarkdown.document(from: "a\n\n***\n\n```\nopen fence").blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .rule)
        XCTAssertEqual(blocks[2], .code(language: nil, text: "open fence"))
    }

    func testMarkdownKeepsOnlyWebLinks() {
        let blocks = SessionMarkdown.document(from: "[web](https://example.com) [file](file:///etc/hosts) [x](vibebar://open)").blocks
        guard case let .paragraph(text) = blocks.first else { return XCTFail() }
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testMarkdownCacheHitsAndEvicts() {
        let cache = SessionMarkdownCache(capacity: 2)
        let first = cache.document(for: "**a**")
        _ = cache.document(for: "**a**")
        XCTAssertEqual(cache.counters, .init(hits: 1, misses: 1))
        XCTAssertEqual(first, cache.document(for: "**a**"))
        _ = cache.document(for: "b")
        _ = cache.document(for: "c") // evicts "**a**", the least recently used
        XCTAssertEqual(cache.count, 2)
        _ = cache.document(for: "**a**")
        XCTAssertEqual(cache.counters.misses, 4)
        XCTAssertEqual(cache.counters.hits, 2)
    }

    // MARK: - Turn window

    func testWindowOpensOnTheTailAndPagesEarlier() {
        var window = SessionTurnWindow.tail(total: 35, pageSize: 10, maxSpan: 25)
        XCTAssertEqual(window.range, 25..<35)
        XCTAssertTrue(window.isAtTail)
        XCTAssertEqual(window.extendEarlier(), 15..<25)
        XCTAssertEqual(window.range, 15..<35)
        // Past maxSpan the far end gives way.
        XCTAssertEqual(window.extendEarlier(), 5..<15)
        XCTAssertEqual(window.range, 5..<30)
        XCTAssertEqual(window.laterCount, 5)
        XCTAssertEqual(window.extendEarlier(), 0..<5)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertEqual(window.extendLater(), 25..<35)
        XCTAssertEqual(window.range, 10..<35)
    }

    func testWindowRevealExtendsNearbyAndJumpsFar() {
        var window = SessionTurnWindow.tail(total: 100, pageSize: 10, maxSpan: 40)
        XCTAssertEqual(window.reveal(95), 0..<0)
        XCTAssertEqual(window.reveal(85), 85..<90)
        XCTAssertEqual(window.range, 85..<100)
        let jumped = window.reveal(20)
        XCTAssertEqual(jumped, 18..<28)
        XCTAssertEqual(window.range, 18..<28)
        XCTAssertEqual(window.reveal(500), 0..<0)
        XCTAssertEqual(SessionTurnWindow.tail(total: 0, pageSize: 10).range, 0..<0)
    }

    func testWindowResizeFollowsTheTail() {
        var window = SessionTurnWindow.tail(total: 12, pageSize: 10)
        window.resize(total: 15)
        XCTAssertEqual(window.range, 5..<15)
        var middle = SessionTurnWindow(total: 50, lowerBound: 10, upperBound: 20, pageSize: 10, maxSpan: 60)
        middle.resize(total: 15)
        XCTAssertEqual(middle.range, 10..<15)
    }

    // MARK: - Thread folding

    private func entry(_ id: String, kind: SessionStructureKind?, parent: String? = nil) -> SessionThreadTree.Entry {
        SessionThreadTree.Entry(id: "row-\(id)", sessionID: id, kind: kind, parentID: parent)
    }

    func testThreadTreeNestsSubagentsAndKeepsOrphans() {
        let tree = SessionThreadTree(entries: [
            entry("child-1", kind: .subagent, parent: "P"),
            entry("P", kind: .interactive),
            entry("grandchild", kind: .subagent, parent: "child-1"),
            entry("orphan", kind: .subagent, parent: "missing"),
            entry("fork", kind: .fork, parent: "p"), // ids compare case-insensitively
            entry("unknown", kind: nil),
        ])
        XCTAssertEqual(tree.roots.map(\.id), ["row-P", "row-orphan", "row-unknown"])
        XCTAssertEqual(tree.roots[0].descendants, ["row-child-1", "row-grandchild", "row-fork"])
        XCTAssertEqual(tree.depth(of: "row-grandchild"), 2)
        XCTAssertEqual(tree.depth(of: "row-fork"), 1)
        XCTAssertTrue(tree.roots[1].isOrphanThread)
        XCTAssertFalse(tree.roots[0].isOrphanThread)
        XCTAssertEqual(tree.visibleIDs(expanded: []), ["row-P", "row-orphan", "row-unknown"])
        XCTAssertEqual(tree.visibleIDs(expanded: ["row-P"]).count, 6)
    }

    func testThreadTreeFiltersHeadlessRuns() {
        let entries = [
            entry("exec", kind: .exec),
            entry("exec-child", kind: .subagent, parent: "exec"),
            entry("auto", kind: .automation),
            entry("review", kind: .guardian, parent: "gone"),
            entry("main", kind: .interactive),
        ]
        let hidden = SessionThreadTree(entries: entries)
        XCTAssertEqual(hidden.roots.map(\.id), ["row-main"])
        XCTAssertEqual(hidden.hiddenCounts[.exec], 2)
        XCTAssertEqual(hidden.hiddenCounts[.automation], 1)
        XCTAssertEqual(hidden.hiddenCounts[.guardian], 1)
        XCTAssertNil(hidden.children["row-exec-child"])

        let shown = SessionThreadTree(entries: entries, showing: [.exec])
        XCTAssertEqual(shown.roots.map(\.id), ["row-exec", "row-main"])
        XCTAssertEqual(shown.roots[0].descendants, ["row-exec-child"])
        XCTAssertNil(shown.hiddenCounts[.exec])
    }

    func testThreadTreeBreaksCycles() {
        let tree = SessionThreadTree(entries: [
            entry("a", kind: .subagent, parent: "b"),
            entry("b", kind: .subagent, parent: "a"),
        ])
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(tree.roots[0].descendants.count, 1)
        XCTAssertEqual(tree.visibleIDs(expanded: Set(tree.roots.map(\.id))).count, 2)
    }

    // MARK: - Outline & render list

    private func outlineTurn(
        _ index: Int,
        preview: String? = nil,
        origin: SessionStructure.PromptOrigin = .human,
        steps: Int = 2,
        failed: Int = 0,
        model: String? = "gpt-5"
    ) -> SessionStructure.Turn {
        SessionStructure.Turn(
            index: index,
            turnID: "turn-\(index)",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            status: .completed,
            prompt: SessionStructure.Prompt(origin: origin, preview: preview ?? "Prompt \(index)", injected: ["skill": 1]),
            counts: SessionStructure.TurnCounts(steps: steps, commands: 1, failed: failed),
            model: model,
            durationMs: 1_500
        )
    }

    func testTOCEntriesFollowTheOutline() {
        let outline = [
            SessionTurnOutline(turn: outlineTurn(0)),
            SessionTurnOutline(turn: outlineTurn(1, preview: "  ", origin: .automation, failed: 1)),
        ]
        let entries = SessionConversationTOCEntry.entries(from: outline)
        XCTAssertEqual(entries.map(\.ordinal), [1, 2])
        XCTAssertEqual(entries[0].preview, "Prompt 0")
        XCTAssertNil(entries[1].preview)
        XCTAssertEqual(entries[1].origin, .automation)
        XCTAssertEqual(entries[1].failed, 1)
    }

    func testLayoutListsStepsOnlyWhenExpanded() {
        var turn = outlineTurn(0)
        turn.steps = [
            SessionStructure.Step(kind: .command, name: "command", argsSummary: "ls"),
            SessionStructure.Step(kind: .note, name: "commentary"),
            SessionStructure.Step(kind: .thinking, name: "reasoning", thinkingCharacters: 120),
        ]
        turn.finalAnswer = "Done **now**"
        let presentation = SessionTurnPresentation.make(turn, markdown: SessionMarkdownCache())
        XCTAssertEqual(presentation.steps.map(\.position), [0, 2])
        let outline = [SessionTurnOutline(turn: outlineTurn(0)), SessionTurnOutline(turn: outlineTurn(1))]
        let window = SessionTurnWindow.tail(total: 2, pageSize: 10)
        var input = SessionConversationLayoutInput(window: window, outline: outline, presentations: [0: presentation])
        var ids = SessionConversationLayout.items(input).map(\.id)
        XCTAssertEqual(ids, ["h0", "p0", "x0", "a0", "h1", "p1", "w1"])
        input.expandedTurns = [0]
        input.expandedSteps = [SessionConversationLayout.stepKey(turn: 0, position: 2)]
        let items = SessionConversationLayout.items(input)
        ids = items.map(\.id)
        XCTAssertEqual(ids, ["h0", "p0", "x0", "s0.0", "s0.2", "a0", "h1", "p1", "w1"])
        if case let .step(step) = items[4] { XCTAssertTrue(step.isExpanded) } else { XCTFail() }
        XCTAssertEqual(SessionConversationItem.turnIndex(forID: "s12.4"), 12)
        XCTAssertNil(SessionConversationItem.turnIndex(forID: "earlier"))
    }

    // MARK: - Listing

    func testListingTitleFallsBackToFirstPrompt() {
        var stats = SessionStats()
        XCTAssertNil(SessionStructureListing(stats: stats, firstPromptPreview: "  ").title)
        XCTAssertEqual(SessionStructureListing(stats: stats, firstPromptPreview: "Fix the build").title, "Fix the build")
        stats.title = "Named"
        XCTAssertEqual(SessionStructureListing(stats: stats, firstPromptPreview: "Fix the build").title, "Named")
        stats.usageSource = .unavailable
        stats.totalTokens = 10
        XCTAssertNil(SessionStructureListing(stats: stats, firstPromptPreview: nil).displayTokens)
        stats.kind = .exec
        XCTAssertTrue(SessionStructureListing(stats: stats, firstPromptPreview: nil).isThread)
    }

    // MARK: - Service listing

    func testServiceListsCachedStatsAndThreadCounts() async throws {
        let directory = try SessionStructureFixtures.temporaryDirectory("listing")
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ id: String, source: Any = "cli", threadSource: String? = "user", parent: String? = nil) throws -> SessionSummary {
            let builder = CodexRolloutBuilder()
                .meta(id: id, parentThreadID: parent, source: source, threadSource: threadSource)
                .taskStarted("t0").turnContext(model: "gpt-5").prompt("Rename the cache", turnID: "t0")
                .tokenCount(input: 100, cached: 0, output: 20).assistant("Done").taskComplete("t0")
            let url = try SessionStructureFixtures.write(builder.lines, to: directory.appendingPathComponent("\(id).jsonl"))
            return SessionSummary(provider: .codex, sessionID: id, sourcePath: url.path)
        }
        let parent = try write("0190cccc-0000-7000-8000-000000000001")
        let child = try write("0190cccc-0000-7000-8000-000000000002",
                              source: ["subagent": ["thread_spawn": ["parent_thread_id": parent.sessionID]]],
                              threadSource: "subagent", parent: parent.sessionID)
        let exec = try write("0190cccc-0000-7000-8000-000000000003", source: "exec", threadSource: nil)
        let service = SessionStructureService(store: SessionStructureStore(url: directory.appendingPathComponent("s.sqlite3")))

        let empty = await service.listings(for: [parent, child, exec])
        XCTAssertTrue(empty.isEmpty, "listing never parses")
        let report = await service.refresh(summaries: [parent, child, exec])
        XCTAssertEqual(report.parsed, 3)

        let listings = await service.listings(for: [parent, child, exec])
        XCTAssertEqual(listings.count, 3)
        XCTAssertEqual(listings[parent.sourcePath]?.firstPromptPreview, "Rename the cache")
        XCTAssertEqual(listings[parent.sourcePath]?.title, "Rename the cache")
        XCTAssertEqual(listings[parent.sourcePath]?.displayTokens, 120)
        XCTAssertEqual(listings[child.sourcePath]?.stats.kind, .subagent)
        XCTAssertEqual(listings[child.sourcePath]?.stats.parentID, parent.sessionID)
        XCTAssertEqual(listings[exec.sourcePath]?.stats.kind, .exec)

        let counts = await service.threadKindCounts()
        XCTAssertEqual(counts[.codex]?[.subagent], 1)
        XCTAssertEqual(counts[.codex]?[.exec], 1)
        XCTAssertNil(counts[.codex]?[.interactive])

        // A file that moved is a miss until it is parsed again.
        try "\n".write(to: URL(fileURLWithPath: exec.sourcePath), atomically: true, encoding: .utf8)
        let after = await service.listings(for: [exec])
        XCTAssertNil(after[exec.sourcePath])
    }

    // MARK: - Claude subagent files

    func testClaudeSubagentFilesListBesideTheParent() throws {
        let directory = try SessionStructureFixtures.temporaryDirectory("subagents")
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLog = directory.appendingPathComponent("abc.jsonl")
        try "{}\n".write(to: parentLog, atomically: true, encoding: .utf8)
        let folder = try XCTUnwrap(ClaudeSubagentFiles.directory(forParentLog: parentLog.path))
        XCTAssertEqual(folder.path, directory.appendingPathComponent("abc/subagents").path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}\n".write(to: folder.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"Explore","description":"Find the cache"}"#.write(
            to: folder.appendingPathComponent("agent-a1.meta.json"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: folder.appendingPathComponent("agent-..%2F.jsonl"), atomically: true, encoding: .utf8)
        let entries = ClaudeSubagentFiles.list(parentLog: parentLog.path)
        XCTAssertEqual(entries.map(\.agentID), ["a1"])
        XCTAssertEqual(entries.first?.description, "Find the cache")
        let parent = SessionSummary(provider: .claude, sessionID: "abc", projectDir: "/Users/example/p", sourcePath: parentLog.path)
        let child = try XCTUnwrap(ClaudeSubagentFiles.summary(agentID: "a1", parent: parent))
        XCTAssertTrue(ClaudeSubagentFiles.isSubagentSummary(child))
        XCTAssertEqual(child.title, "Find the cache")
        XCTAssertNil(ClaudeSubagentFiles.summary(agentID: "../x", parent: parent))
        XCTAssertNil(ClaudeSubagentFiles.directory(forParentLog: folder.appendingPathComponent("agent-a1.jsonl").path))
    }

    // MARK: - List stats requests

    private func logSummary(_ name: String, size: Int64 = 100, provider: SessionProvider = .codex) -> SessionSummary {
        SessionSummary(provider: provider, sessionID: name, sourcePath: "/Users/example/\(name).jsonl", sizeBytes: size)
    }

    func testAStoppedBatchIsAskedForAgain() {
        var requests = SessionListingRequests()
        let rows = (0..<5).map { logSummary("s\($0)") }
        XCTAssertTrue(requests.enqueue(rows, atFront: true))
        XCTAssertFalse(requests.enqueue(rows, atFront: true), "asked once per size")
        let batch = requests.takeBatch(limit: 3)
        XCTAssertEqual(batch.map(\.sessionID), ["s0", "s1", "s2"])
        XCTAssertEqual(requests.inFlight.count, 3)
        XCTAssertEqual(requests.queue.count, 2)
        // The Workbench closes mid-batch: nothing of it was answered.
        requests.cancel()
        XCTAssertTrue(requests.queue.isEmpty)
        XCTAssertTrue(requests.inFlight.isEmpty)
        XCTAssertFalse(rows.contains(where: requests.isRequested))
        // Reopening asks for every row again, the in-flight ones included.
        XCTAssertTrue(requests.enqueue(rows, atFront: true))
        XCTAssertEqual(requests.queue.map(\.sessionID), ["s0", "s1", "s2", "s3", "s4"])
    }

    func testAnsweredRowsAreNotAskedAgainUntilTheyGrow() {
        var requests = SessionListingRequests()
        let rows = [logSummary("a"), logSummary("b"), logSummary("g", provider: .gemini)]
        requests.enqueue(rows, atFront: false)
        XCTAssertEqual(requests.queue.map(\.sessionID), ["a", "b"], "only what the sidecar can describe")
        _ = requests.takeBatch(limit: 10)
        requests.finishBatch()
        requests.cancel()
        XCTAssertFalse(requests.enqueue(rows, atFront: true), "an answered batch stays answered")
        XCTAssertTrue(requests.enqueue([logSummary("a", size: 200)], atFront: true), "a session that grew is asked again")
    }

    func testAFresherPageTakesTheRestOfABatchsPlace() {
        var requests = SessionListingRequests()
        requests.enqueue((0..<4).map { logSummary("old\($0)") }, atFront: false)
        let batch = requests.takeBatch(limit: 4)
        requests.enqueue([logSummary("new")], atFront: true)
        requests.requeue(Array(batch[2...]))
        XCTAssertEqual(requests.inFlight.map(\.sessionID), ["old0", "old1"])
        XCTAssertEqual(requests.queue.map(\.sessionID), ["new", "old2", "old3"])
        requests.finishBatch()
        requests.cancel()
        XCTAssertTrue(requests.isRequested(logSummary("old0")), "answered before the stop")
        XCTAssertFalse(requests.isRequested(logSummary("old2")), "handed back and never read")
    }

    // MARK: - Markdown fences

    func testALongerFenceHoldsAShorterOne() {
        let source = "````markdown\n```swift\nlet a = 1\n```\n````\nAfter."
        let blocks = SessionMarkdown.document(from: source).blocks
        XCTAssertEqual(blocks.count, 2)
        guard case let .code(language, text) = blocks.first else { return XCTFail("expected a code block") }
        XCTAssertEqual(language, "markdown")
        XCTAssertEqual(text, "```swift\nlet a = 1\n```")
        guard case .paragraph = blocks.last else { return XCTFail("the text after the fence is prose") }
    }

    func testFencesCloseOnARunAtLeastAsLong() {
        let tildes = SessionMarkdown.document(from: "~~~~\n~~~\n~~~~").blocks
        guard case let .code(_, inner) = tildes.first else { return XCTFail("expected a code block") }
        XCTAssertEqual(inner, "~~~")
        XCTAssertEqual(tildes.count, 1)
        let longerClose = SessionMarkdown.document(from: "```\ncode\n`````\nAfter").blocks
        XCTAssertEqual(longerClose.count, 2)
        guard case let .code(_, code) = longerClose.first else { return XCTFail("expected a code block") }
        XCTAssertEqual(code, "code")
        // Two backticks are inline code, not a fence.
        guard case .paragraph = SessionMarkdown.document(from: "``x``").blocks.first else { return XCTFail() }
    }

    // MARK: - List paging

    func testPagesTheFiltersHideEntirelyAskForTheNextOne() {
        var paging = SessionListAutoPaging()
        // A first page of exec runs only: nothing to show, so no row to come
        // into view.
        XCTAssertTrue(paging.shouldLoadMore(sourceCount: 250, visibleCount: 0, firstID: "a", hasMore: true))
        // Rebuilt for another reason (stats landed): nothing new arrived.
        XCTAssertFalse(paging.shouldLoadMore(sourceCount: 250, visibleCount: 0, firstID: "a", hasMore: true))
        // The next page is hidden too.
        XCTAssertTrue(paging.shouldLoadMore(sourceCount: 500, visibleCount: 0, firstID: "a", hasMore: true))
        // This one shows rows: from here the last row pages as usual.
        XCTAssertFalse(paging.shouldLoadMore(sourceCount: 750, visibleCount: 40, firstID: "a", hasMore: true))
        XCTAssertFalse(paging.shouldLoadMore(sourceCount: 750, visibleCount: 40, firstID: "a", hasMore: true))
        // A visible page followed by a hidden one asks again.
        XCTAssertTrue(paging.shouldLoadMore(sourceCount: 1_000, visibleCount: 40, firstID: "a", hasMore: true))
        // Nothing more in the index: done.
        XCTAssertFalse(paging.shouldLoadMore(sourceCount: 1_250, visibleCount: 40, firstID: "a", hasMore: false))
    }

    func testAutomaticPagingStopsAfterABoundedRun() {
        var paging = SessionListAutoPaging()
        var asked = 0
        for page in 1...20 where paging.shouldLoadMore(sourceCount: page * 250, visibleCount: 0, firstID: "a", hasMore: true) {
            asked += 1
        }
        XCTAssertEqual(asked, SessionListAutoPaging.maximumConsecutivePages)
    }

    func testANewQueryIsJudgedFromItsFirstPage() {
        var paging = SessionListAutoPaging()
        XCTAssertFalse(paging.shouldLoadMore(sourceCount: 500, visibleCount: 120, firstID: "a", hasMore: true))
        // The filter changed: a fresh first page, as long as the old list,
        // all of it hidden.
        XCTAssertTrue(paging.shouldLoadMore(sourceCount: 500, visibleCount: 0, firstID: "b", hasMore: true))
        // A shorter list is a new query too.
        XCTAssertFalse(paging.shouldLoadMore(sourceCount: 250, visibleCount: 30, firstID: "b", hasMore: true))
        XCTAssertTrue(paging.shouldLoadMore(sourceCount: 100, visibleCount: 0, firstID: "b", hasMore: true))
    }
}
