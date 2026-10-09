import XCTest
@testable import VibeBarCore

/// One synthetic Codex home, read by every surface that states a number
/// about it: the harness column, the list row, the conversation masthead,
/// its contents column and MCP's `sessions.list` / `sessions.transcript`.
/// They must agree, because they are read from the same index and the same
/// structure sidecar by the same rules.
@MainActor
final class SessionCountsConsistencyTests: XCTestCase {
    private var directory: URL!
    private var home: URL { directory.appendingPathComponent("home", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("session_index.sqlite3") }
    private var structureURL: URL { directory.appendingPathComponent("session_structure.sqlite3") }

    private let parentID = "0199bbbb-0000-7000-8000-000000000001"
    private let childID = "0199bbbb-0000-7000-8000-000000000002"
    private let execID = "0199bbbb-0000-7000-8000-000000000003"
    private let reviewIDs = ["0199bbbb-0000-7000-8000-000000000004", "0199bbbb-0000-7000-8000-000000000005"]

    override func setUpWithError() throws {
        directory = try SessionStructureFixtures.temporaryDirectory("consistency")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ builder: CodexRolloutBuilder, id: String, minute: Int) throws {
        let url = home.appendingPathComponent(
            String(format: ".codex/sessions/2026/05/01/rollout-2026-05-01T10-%02d-00-", minute) + id + ".jsonl"
        )
        try SessionStructureFixtures.write(builder.lines, to: url)
    }

    private func writeHome() throws {
        let parent = CodexRolloutBuilder().meta(id: parentID)
        for turn in 0..<3 {
            parent.taskStarted("turn-\(turn)").turnContext(model: "gpt-5", turnID: "turn-\(turn)")
                .prompt("Question \(turn)", turnID: "turn-\(turn)")
                .functionCall("exec_command", callID: "c\(turn)a", arguments: ["cmd": "ls"])
                .stringOutput(callID: "c\(turn)a", text: "Exit code: 0\nWall time: 0.1 seconds\nOutput:\nok\n")
                .functionCall("exec_command", callID: "c\(turn)b", arguments: ["cmd": "false"])
                .stringOutput(callID: "c\(turn)b", text: "Exit code: \(turn == 1 ? 1 : 0)\nWall time: 0.1 seconds\nOutput:\n\n")
                .tokenCount(input: 1_000, cached: 400, output: 120)
                .assistant("Answer \(turn)").taskComplete("turn-\(turn)")
        }
        try write(parent, id: parentID, minute: 0)

        let child = CodexRolloutBuilder()
            .meta(id: childID, sessionID: parentID, parentThreadID: parentID,
                  source: ["subagent": ["thread_spawn": ["parent_thread_id": parentID]]], threadSource: "subagent")
            .taskStarted("x").turnContext(model: "gpt-5-mini").userResponseItem("Look at the tests")
            .tokenCount(input: 100, cached: 0, output: 10).assistant("Done").taskComplete("x")
        try write(child, id: childID, minute: 1)

        let exec = CodexRolloutBuilder().meta(id: execID, source: "exec", threadSource: nil)
            .taskStarted("e").turnContext(model: "gpt-5").prompt("Summarize", turnID: "e")
            .tokenCount(input: 50, cached: 0, output: 5).assistant("Summary").taskComplete("e")
        try write(exec, id: execID, minute: 2)

        for (offset, id) in reviewIDs.enumerated() {
            let review = CodexRolloutBuilder()
                .meta(id: id, sessionID: parentID, parentThreadID: parentID,
                      source: ["subagent": ["other": "guardian"]], threadSource: "guardian_review")
                .taskStarted("r")
                .userResponseItem("Excerpt", metadata: [
                    "guardian_sources": [["complete": true, "id": ["message_id": "m", "turn_id": "turn-\(offset)", "role": "assistant"]]]
                ])
                .userMessageItem("Review the command", turnID: "r")
                .assistant(#"{"risk_level":"low","outcome":"\#(offset == 0 ? "allow" : "deny")","rationale":"synthetic"}"#)
                .taskComplete("r")
            try write(review, id: id, minute: 3 + offset)
        }
    }

    func testEverySurfaceStatesTheSameNumbers() async throws {
        try writeHome()
        let store = try SessionIndexStore(url: indexURL)
        let registry = SessionIndexingBounds.boundedRegistry(
            SessionProviderRegistry(adapters: [CodexSessionAdapter(homeDirectory: home.path)]),
            scratchDirectory: directory.appendingPathComponent("scratch", isDirectory: true)
        )
        let index = SessionIndexService(homeDirectory: home.path, store: store, registry: registry, bodyIndexing: { true })
        await index.refreshIndex()
        let reviews = SessionReviewIndex(databaseURL: indexURL)
        let structure = SessionStructureService(store: SessionStructureStore(url: structureURL))

        // Harness column = `sessions.list` (`SessionVisibleRows`): the index
        // counts less the Auto Review rows it hides.
        let page = try await SessionVisibleRows.page(index, limit: 100)
        let overview = try await reviews.overview()
        let harnessCounts = try await store.harnessCounts()
        let railCodex = (harnessCounts[.codex] ?? 0) - (overview.hiddenRowsByHarness[.codex] ?? 0)
        let listed = try await SessionVisibleRows.page(index, harnesses: [.codex], limit: 100)
        XCTAssertEqual(railCodex, listed.totalCount)
        XCTAssertEqual(railCodex, 3, "parent, subagent, headless run; the two reviews are not rows")
        let summaries = page.summaries
        let parent = try XCTUnwrap(summaries.first { $0.sessionID == parentID })

        // The list fills its rows' stats in the background, as the page does.
        _ = await structure.refresh(summaries: summaries)
        let listings = await structure.listings(for: summaries)
        XCTAssertEqual(listings.count, 3)

        // "Includes N threads" is counted within the listed rows, and is the
        // number of rows the list folds.
        var paths: [Harness: Set<String>] = [:]
        for summary in summaries { paths[summary.effectiveHarness, default: []].insert(summary.sourcePath) }
        let threads = await structure.threadCounts(visiblePaths: paths)
        let tree = SessionThreadTree(entries: summaries.map {
            SessionThreadTree.Entry(
                id: $0.id, sessionID: $0.sessionID,
                kind: listings[$0.sourcePath]?.stats.kind, parentID: listings[$0.sourcePath]?.stats.parentID
            )
        })
        XCTAssertEqual(threads[.codex], 1)
        XCTAssertEqual(tree.roots.first { $0.id == parent.id }?.descendants.count, threads[.codex])
        XCTAssertEqual(tree.hiddenCounts[.exec], 1)

        // List row and masthead: the same stats for the same file.
        let rowStats = try XCTUnwrap(listings[parent.sourcePath]?.stats)
        let source = SessionStructureConversationSource(
            service: structure,
            reviews: { summary in await reviews.reviewSet(for: summary, limit: 500) },
            indexedSummary: { provider, id in try? await index.summary(provider: provider, sessionID: id) }
        )
        let model = SessionConversationModel(source: source)
        model.open(parent)
        let deadline = Date().addingTimeInterval(5)
        while (model.phase != .ready || model.verdictTotals.reviews == 0), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let meta = try XCTUnwrap(model.stats)
        XCTAssertEqual(meta.totalTokens, rowStats.totalTokens)
        XCTAssertEqual(meta.estimatedCostUSD, rowStats.estimatedCostUSD)
        XCTAssertEqual(meta.promptCount, rowStats.promptCount)
        XCTAssertEqual(meta.toolCallCount, rowStats.toolCallCount)
        XCTAssertEqual(meta.failedToolCount, rowStats.failedToolCount)
        XCTAssertEqual(meta, rowStats)

        // Contents column = masthead.
        XCTAssertEqual(model.tocTotals.turns, meta.turnCount)
        XCTAssertEqual(model.tocTotals.prompts, meta.promptCount)
        XCTAssertEqual(model.tocTotals.steps, meta.toolCallCount)
        XCTAssertEqual(model.tocTotals.failed, meta.failedToolCount)
        XCTAssertEqual(model.toc.count, 3)
        XCTAssertEqual(meta.promptCount, 3)
        XCTAssertEqual(meta.toolCallCount, 6)
        XCTAssertEqual(meta.failedToolCount, 1)

        // Auto Reviews: list row (grouped overview) = masthead =
        // `sessions.transcript` (`reviewSet`, what MCP reports).
        let transcriptCount = await reviews.reviewSet(for: parent, limit: SessionTranscriptResult.autoReviewListLimit).count
        XCTAssertEqual(overview.countsByParent[parentID], 2)
        XCTAssertEqual(transcriptCount, 2)
        XCTAssertEqual(model.verdictTotals.reviews, 2)
        XCTAssertEqual(model.verdictTotals.allow + model.verdictTotals.deny, 2)
    }
}
