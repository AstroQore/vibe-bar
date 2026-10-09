import AppKit
import XCTest
@testable import VibeBarCore

/// `SessionConversationModel` against a synthetic source: tail-first
/// opening, paging, the windowed read path, outline jumps, the Markdown
/// cache and subagent navigation.
@MainActor
final class SessionConversationModelTests: XCTestCase {
    /// Hands out a synthetic structure and records what was asked for.
    final class FakeSource: SessionConversationSource, @unchecked Sendable {
        let structure: SessionStructure
        let size: Int64
        let fullParseLimitBytes: Int64 = 1_000
        var verdicts: [String: [SessionStructure.GuardianVerdict]] = [:]
        var reviewCount = 0
        var children: [String: SessionSummary] = [:]
        private let lock = NSLock()
        private var _turnReads: [Int] = []
        private var _fullReads = 0

        init(turns: Int, size: Int64 = 500, extraSteps: Int = 0) {
            var built: [SessionStructure.Turn] = []
            for index in 0..<turns {
                let extra = (0..<extraSteps).map { SessionStructure.Step(kind: .command, name: "command", argsSummary: "ls \($0)") }
                built.append(SessionStructure.Turn(
                    index: index,
                    turnID: "t\(index)",
                    status: .completed,
                    prompt: SessionStructure.Prompt(origin: .human, text: "Question \(index)", preview: "Question \(index)"),
                    steps: [
                        SessionStructure.Step(kind: .command, name: "command", argsSummary: "echo \(index)"),
                        SessionStructure.Step(kind: .subagent, name: "spawn_agent", argsSummary: "Task \(index)", childSessionID: "child-\(index)"),
                    ] + extra,
                    counts: SessionStructure.TurnCounts(steps: 2 + extraSteps, commands: 1 + extraSteps, subagents: 1),
                    // Every third answer repeats, so the cache has something to hit.
                    finalAnswer: "Answer **\(index % 3)**",
                    model: "gpt-5"
                ))
            }
            var stats = SessionStats(promptCount: turns, turnCount: turns, models: ["gpt-5"])
            stats.title = "Synthetic"
            structure = SessionStructure(provider: .codex, sessionID: "s", sourcePath: "/Users/example/s.jsonl", detail: .full, turns: built, stats: stats)
            self.size = size
        }

        var turnReads: [Int] { lock.withLock { _turnReads } }
        var fullReads: Int { lock.withLock { _fullReads } }

        func supports(_ provider: SessionProvider) -> Bool { provider == .codex || provider == .claude }
        func fileSize(of summary: SessionSummary) async -> Int64? { size }
        func outline(for summary: SessionSummary) async -> SessionStructure? { structure.outlineOnly }
        func fullStructure(for summary: SessionSummary) async -> SessionStructure? {
            lock.withLock { _fullReads += 1 }
            return structure
        }
        func turn(at index: Int, for summary: SessionSummary) async -> SessionStructure.Turn? {
            lock.withLock { _turnReads.append(index) }
            return structure.turns.indices.contains(index) ? structure.turns[index] : nil
        }
        func reviewVerdicts(for summary: SessionSummary) async -> SessionReviewVerdicts {
            SessionReviewVerdicts(reviewCount: reviewCount, byTurnID: verdicts)
        }
        func childSummary(childID: String, parent: SessionSummary) async -> SessionSummary? { children[childID] }
    }

    private func summary(_ id: String = "s", provider: SessionProvider = .codex) -> SessionSummary {
        SessionSummary(provider: provider, sessionID: id, sourcePath: "/Users/example/\(id).jsonl")
    }

    private func settle(_ model: SessionConversationModel, until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testOpensOnTheTailAndPagesEarlier() async throws {
        let source = FakeSource(turns: 25)
        let model = SessionConversationModel(source: source, pageSize: 10, initialTurns: 10, maxSpan: 30)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 10 }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.loadedTurnIndices, Array(15..<25))
        XCTAssertEqual(model.toc.count, 25)
        XCTAssertEqual(model.stats?.title, "Synthetic")
        XCTAssertEqual(model.items.first?.id, "earlier")
        // Published whole, so the view opens at the end by its initial
        // offset rather than by a scroll request.
        XCTAssertNil(model.scrollRequest)
        XCTAssertEqual(model.contentToken, 1)
        XCTAssertEqual(source.fullReads, 1)
        XCTAssertTrue(source.turnReads.isEmpty)
        XCTAssertEqual(model.subagentLinks.count, 25)

        model.loadEarlier()
        try await settle(model) { model.loadedTurnIndices.count == 20 }
        XCTAssertEqual(model.window.range, 5..<25)
        model.loadEarlier()
        try await settle(model) { model.loadedTurnIndices.first == 0 }
        // maxSpan 30 kept the window to 25 turns here; nothing was dropped.
        XCTAssertEqual(model.window.range, 0..<25)
        XCTAssertFalse(model.items.contains { $0.id == "earlier" })
        XCTAssertEqual(source.fullReads, 1, "pages are sliced from the one full parse")
    }

    func testTheFirstWindowIsSmallerThanAPage() async throws {
        let source = FakeSource(turns: 30)
        let model = SessionConversationModel(source: source, pageSize: 10, initialTurns: 4)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 4 }
        XCTAssertEqual(model.window.range, 26..<30)
        model.loadEarlier()
        try await settle(model) { model.loadedTurnIndices.count == 14 }
        XCTAssertEqual(model.window.range, 16..<30)
    }

    func testLargeFilesAreReadTurnByTurnNewestFirst() async throws {
        let source = FakeSource(turns: 30, size: 5_000)
        let model = SessionConversationModel(source: source, pageSize: 4, initialTurns: 4)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 4 }
        XCTAssertTrue(model.isWindowed)
        XCTAssertEqual(source.turnReads, [29, 28, 27, 26])
        XCTAssertEqual(model.scrollRequest?.anchor, .bottom, "a windowed read settles on the end once its newest turn lands")
        XCTAssertEqual(source.fullReads, 0)
        XCTAssertNil(model.progress)

        // A jump far outside the window replaces it.
        model.reveal(turn: 3)
        try await settle(model) { model.loadedTurnIndices == [1, 2, 3, 4] }
        XCTAssertEqual(model.window.range, 1..<5)
        XCTAssertEqual(model.currentTurn, 3)
        XCTAssertEqual(model.scrollRequest?.itemID, "h3")
        XCTAssertEqual(model.scrollRequest?.anchor, .top)
    }

    func testMarkdownIsParsedOncePerText() async throws {
        let source = FakeSource(turns: 9)
        let cache = SessionMarkdownCache()
        let model = SessionConversationModel(source: source, pageSize: 9, initialTurns: 9, markdown: cache)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 9 }
        // 9 distinct prompts + 3 distinct answers parsed; 6 answers hit.
        XCTAssertEqual(cache.counters.misses, 12)
        XCTAssertEqual(cache.counters.hits, 6)
        model.reload()
        try await settle(model) { model.phase == .ready && model.loadedTurnIndices.count == 9 }
        XCTAssertEqual(cache.counters.misses, 12, "a re-read parses nothing again")
    }

    func testExpansionAndVerdictsReachTheRenderList() async throws {
        let source = FakeSource(turns: 3)
        source.verdicts = ["t1": [SessionStructure.GuardianVerdict(outcome: "deny", riskLevel: "high")]]
        source.reviewCount = 1
        let model = SessionConversationModel(source: source)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 3 && model.verdictTotals.deny == 1 }
        XCTAssertEqual(model.verdictTotals.reviews, 1)
        XCTAssertEqual(model.window.range, 0..<3)
        XCTAssertFalse(model.items.contains { $0.id.hasPrefix("s") })
        model.toggleProcess(turn: 1)
        XCTAssertEqual(model.items.filter { $0.id.hasPrefix("s1.") }.count, 2)
        XCTAssertEqual(model.scrollRequest?.itemID, "x1", "an opened process comes to the top")
        XCTAssertEqual(model.scrollRequest?.anchor, .top)
        model.toggleStep(turn: 1, position: 0)
        let step = model.items.first { $0.id == "s1.0" }
        if case let .step(value) = step { XCTAssertTrue(value.isExpanded) } else { XCTFail() }
        let header = model.items.first { $0.id == "h1" }
        if case let .header(value) = header { XCTAssertEqual(value.verdicts.first?.isDenied, true) } else { XCTFail() }

        model.noteVisible(["x2", "a1", "h1"])
        XCTAssertEqual(model.currentTurn, 1)
    }

    func testTheFirstTurnsArriveOneFrameAtATime() async throws {
        let source = FakeSource(turns: 12)
        let model = SessionConversationModel(source: source, pageSize: 10, initialTurns: 4, firstFrameTurns: 1)
        model.open(summary())
        // The masthead and the contents come first, the conversation still
        // covered by its loading state.
        try await settle(model) { !model.toc.isEmpty }
        XCTAssertEqual(model.toc.count, 12)
        XCTAssertNotNil(model.stats)
        // Then the newest turn alone, in a scroll view built on it...
        try await settle(model) { model.phase == .ready }
        XCTAssertEqual(model.window.range, 11..<12)
        XCTAssertEqual(model.contentToken, 1)
        // ...and the rest of the first window above it, a turn a frame.
        var seen: Set<Int> = [model.window.count]
        try await settle(model) {
            seen.insert(model.window.count)
            return model.window.count == 4
        }
        XCTAssertEqual(model.window.range, 8..<12)
        XCTAssertEqual(model.loadedTurnIndices, [8, 9, 10, 11])
        XCTAssertTrue(seen.isSubset(of: [1, 2, 3, 4]))
        XCTAssertEqual(model.contentToken, 1, "growing the window keeps the scroll view")
        XCTAssertNil(model.scrollRequest, "the view stays on the end without being asked")
    }

    func testAPageArrivesATurnAtATimeNearestFirst() async throws {
        let source = FakeSource(turns: 20)
        let model = SessionConversationModel(source: source, pageSize: 5, initialTurns: 2, firstFrameTurns: 2)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices == [18, 19] }
        model.loadEarlier()
        XCTAssertTrue(model.items.first.map { if case let .earlier(edge) = $0 { edge.isLoading } else { false } } ?? false,
                      "the edge row says a page is coming")
        var lowerBounds: [Int] = []
        try await settle(model) {
            if lowerBounds.last != model.window.range.lowerBound { lowerBounds.append(model.window.range.lowerBound) }
            return model.window.range == 13..<20 && !model.items.contains(where: Self.isLoadingEdge)
        }
        XCTAssertEqual(lowerBounds.first, 18)
        XCTAssertEqual(lowerBounds, lowerBounds.sorted(by: >), "turns join next to what is on screen first")
        XCTAssertEqual(model.loadedTurnIndices, Array(13..<20))
        XCTAssertFalse(model.items.contains { if case .pending = $0 { true } else { false } }, "no placeholders for a file held in memory")
    }

    func testAJumpStartsAtItsTurnAndFillsTheTurnsUnderIt() async throws {
        let source = FakeSource(turns: 30)
        let model = SessionConversationModel(source: source, pageSize: 6, initialTurns: 2)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices == [28, 29] }
        let tokens = (content: model.contentToken, list: model.listToken)
        model.reveal(turn: 5)
        XCTAssertEqual(model.window.range, 5..<6, "the turn alone first")
        XCTAssertEqual(model.listToken, tokens.list + 1, "a new list rather than every old row replaced")
        XCTAssertEqual(model.contentToken, tokens.content, "the same session: the contents column stays put")
        XCTAssertEqual(model.currentTurn, 5)
        XCTAssertEqual(model.scrollRequest?.itemID, "h5")
        XCTAssertEqual(model.scrollRequest?.anchor, .top)
        try await settle(model) { model.window.range == 5..<11 && !model.items.contains(where: Self.isLoadingLaterEdge) }
        XCTAssertEqual(model.loadedTurnIndices, Array(5..<11))
        XCTAssertEqual(source.fullReads, 1)
    }

    private static func isLoadingLaterEdge(_ item: SessionConversationItem) -> Bool {
        if case let .later(edge) = item { return edge.isLoading }
        return false
    }

    private static func isLoadingEdge(_ item: SessionConversationItem) -> Bool {
        if case let .earlier(edge) = item { return edge.isLoading }
        return false
    }

    func testAnOpeningProcessListsItsFirstStepsFirst() async throws {
        let source = FakeSource(turns: 2, extraSteps: 10)
        let model = SessionConversationModel(source: source)
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 2 }
        model.toggleProcess(turn: 1)
        XCTAssertEqual(model.items.filter { $0.id.hasPrefix("s1.") }.count, SessionConversationModel.firstFrameSteps)
        try await settle(model) { model.items.filter { $0.id.hasPrefix("s1.") }.count == 12 }
        model.toggleProcess(turn: 1)
        XCTAssertFalse(model.items.contains { $0.id.hasPrefix("s1.") })
        // Expand all lists every step at once.
        model.setAllProcesses(expanded: true)
        XCTAssertEqual(model.items.filter { $0.id.hasPrefix("s1.") }.count, 12)
    }

    func testTurnTextIsBuiltAtThePanesSizes() async throws {
        let source = FakeSource(turns: 2)
        let model = SessionConversationModel(source: source)
        model.setTextStyle(SessionRichTextStyle(promptSize: 12, answerSize: 15))
        model.open(summary())
        try await settle(model) { model.loadedTurnIndices.count == 2 }
        func answerSize() -> CGFloat? {
            for item in model.items {
                if case let .answer(answer) = item, let text = answer.text {
                    return (text.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
                }
            }
            return nil
        }
        XCTAssertEqual(answerSize(), 15)
        model.setTextStyle(SessionRichTextStyle(promptSize: 12, answerSize: 17))
        try await settle(model) { answerSize() == 17 }
        XCTAssertEqual(model.loadedTurnIndices, [0, 1])
    }

    func testUnsupportedProvidersAndChildNavigation() async throws {
        let source = FakeSource(turns: 2)
        source.children["child-1"] = summary("child")
        let model = SessionConversationModel(source: source)
        model.open(summary("g", provider: .gemini))
        XCTAssertEqual(model.phase, .unsupported)

        model.open(summary())
        try await settle(model) { model.phase == .ready && model.loadedTurnIndices.count == 2 }
        model.openChild("child-1")
        try await settle(model) { model.summary?.sessionID == "child" }
        XCTAssertEqual(model.trail.map(\.sessionID), ["s"])
        model.back()
        XCTAssertEqual(model.summary?.sessionID, "s")
        XCTAssertTrue(model.trail.isEmpty)

        model.openChild("missing")
        try await settle(model) { model.notice != nil }
        XCTAssertEqual(model.notice, .childNotFound("missing"))
    }
}
