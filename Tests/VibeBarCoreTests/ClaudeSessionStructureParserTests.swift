import XCTest
@testable import VibeBarCore

final class ClaudeSessionStructureParserTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SessionStructureFixtures.temporaryDirectory("claude")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var mainURL: URL {
        directory.appendingPathComponent("-Users-example-project/\(SessionStructureFixtures.claudeSessionID).jsonl")
    }

    private func parse(_ builder: ClaudeLogBuilder, url: URL? = nil, detail: SessionStructure.Detail = .full) throws -> SessionStructure {
        let target = try SessionStructureFixtures.write(builder.lines, to: url ?? mainURL)
        return try XCTUnwrap(ClaudeSessionStructureParser.parse(fileURL: target, options: SessionStructureParseOptions(detail: detail)))
    }

    /// One turn: thinking, a failing Bash call, a Read call, an answer. The
    /// first response is split over three lines that repeat its usage.
    private func basicLog() -> ClaudeLogBuilder {
        let log = ClaudeLogBuilder()
        log.line(["type": "custom-title", "customTitle": "Structure work"], parent: .some(nil), chain: false)
        log.prompt("Run the tests and read the config", parent: .some(nil))
        log.assistant(messageID: "msg_1", requestID: "req_1", blocks: [["type": "thinking", "thinking": "I should run the tests first.", "signature": "sig"]],
                      extra: ["thinkingDurationMs": 900])
        log.assistant(messageID: "msg_1", requestID: "req_1", blocks: [["type": "text", "text": "Running the tests now."]])
        log.assistant(messageID: "msg_1", requestID: "req_1", blocks: [["type": "tool_use", "id": "toolu_bash", "name": "Bash",
                                                                          "input": ["command": "swift test --filter Structure", "description": "Run tests"]]],
                      usage: ["input_tokens": 10, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1_000, "output_tokens": 80])
        log.toolResult(id: "toolu_bash", content: "error: 2 tests failed", isError: true,
                       toolUseResult: ["stdout": "", "stderr": "error", "interrupted": false])
        log.assistant(messageID: "msg_2", requestID: "req_2", blocks: [["type": "tool_use", "id": "toolu_read", "name": "Read",
                                                                          "input": ["file_path": "/Users/example/project/config.json"]]],
                      usage: ["input_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 2_000, "output_tokens": 20])
        log.toolResult(id: "toolu_read", content: "{\"debug\": true}")
        log.assistant(messageID: "msg_3", requestID: "req_3", blocks: [["type": "text", "text": "Two tests fail; debug is on."]],
                      usage: ["input_tokens": 2, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 2_100, "output_tokens": 30],
                      stopReason: "end_turn")
        return log
    }

    func testTurnStepsPairingAndCounts() throws {
        let structure = try parse(basicLog())
        XCTAssertEqual(structure.sessionID, SessionStructureFixtures.claudeSessionID)
        XCTAssertEqual(structure.turns.count, 1)
        let turn = structure.turns[0]
        XCTAssertEqual(turn.status, .completed)
        XCTAssertEqual(turn.prompt.origin, .human)
        XCTAssertEqual(turn.prompt.text, "Run the tests and read the config")
        XCTAssertEqual(turn.finalAnswer, "Two tests fail; debug is on.")
        XCTAssertEqual(turn.model, "claude-sonnet-4-5")

        let thinking = try XCTUnwrap(turn.steps.first { $0.kind == .thinking })
        XCTAssertEqual(thinking.thinkingCharacters, "I should run the tests first.".count)
        XCTAssertEqual(thinking.durationMs, 900)

        let bash = try XCTUnwrap(turn.steps.first { $0.callID == "toolu_bash" })
        XCTAssertEqual(bash.kind, .command)
        XCTAssertEqual(bash.argsSummary, "swift test --filter Structure")
        XCTAssertTrue(bash.isError)
        XCTAssertEqual(bash.pairing, .paired)
        XCTAssertEqual(bash.durationMs, 2_000, "falls back to the timestamp gap")

        let read = try XCTUnwrap(turn.steps.first { $0.callID == "toolu_read" })
        XCTAssertEqual(read.kind, .toolCall)
        XCTAssertEqual(read.argsSummary, "/Users/example/project/config.json")
        XCTAssertFalse(read.isError)

        XCTAssertTrue(turn.steps.contains { $0.kind == .note && $0.resultSummary == "Running the tests now." })
        XCTAssertEqual(structure.stats.promptCount, 1)
        XCTAssertEqual(structure.stats.toolCallCount, 2)
        XCTAssertEqual(structure.stats.commandCount, 1)
        XCTAssertEqual(structure.stats.failedToolCount, 1)
        XCTAssertEqual(structure.stats.thinkingCount, 1)
        XCTAssertEqual(structure.stats.title, "Structure work")
        XCTAssertEqual(structure.stats.gitBranch, "feature/structure")
        XCTAssertEqual(structure.stats.kind, .interactive)
    }

    func testUsageIsDeduplicatedPerMessageAndRequest() throws {
        let structure = try parse(basicLog())
        // msg_1's usage appears on three lines; the last one counts once.
        let expected = SessionStructure.TokenUsage(input: 17, cacheWrite: 100, cacheRead: 5_100, output: 130)
        XCTAssertEqual(structure.stats.totalUsage, expected)
        XCTAssertEqual(structure.turns[0].usage, expected)
        XCTAssertEqual(structure.stats.totalTokens, expected.total)
        XCTAssertEqual(structure.stats.usageSource, .summedMessages)
        XCTAssertNotNil(structure.stats.estimatedCostUSD)
        XCTAssertFalse(structure.stats.hasUnpricedUsage)
    }

    func testUnknownModelHasNoCost() throws {
        let log = ClaudeLogBuilder()
        log.prompt("Hi", parent: .some(nil))
        log.assistant(messageID: "m", model: "synthetic-claude-zero", blocks: [["type": "text", "text": "Hello"]])
        let structure = try parse(log)
        XCTAssertNil(structure.stats.estimatedCostUSD)
        XCTAssertTrue(structure.stats.hasUnpricedUsage)
        XCTAssertEqual(structure.stats.models, ["synthetic-claude-zero"])
    }

    func testTaskToolBecomesSubagentStepWithAgentID() throws {
        let log = ClaudeLogBuilder()
        log.prompt("Audit the parser with a subagent", parent: .some(nil))
        log.assistant(messageID: "m1", blocks: [["type": "tool_use", "id": "toolu_task", "name": "Agent",
                                                  "input": ["description": "Audit parser", "subagent_type": "general-purpose", "prompt": "…"]]])
        log.toolResult(id: "toolu_task", content: "Audit complete", toolUseResult: [
            "agentId": "a1b2c3d4e5f6a7b8c", "status": "completed", "resolvedModel": "claude-sonnet-4-5", "totalDurationMs": 42_000
        ])
        log.assistant(messageID: "m2", blocks: [["type": "text", "text": "The audit found nothing."]], stopReason: "end_turn")
        let structure = try parse(log)
        let step = try XCTUnwrap(structure.turns[0].steps.first { $0.kind == .subagent })
        XCTAssertEqual(step.childSessionID, "a1b2c3d4e5f6a7b8c")
        XCTAssertEqual(step.durationMs, 42_000)
        XCTAssertEqual(step.argsSummary, "general-purpose: Audit parser")
        XCTAssertEqual(structure.stats.subagentCount, 1)
    }

    func testMCPToolNamesAreReadable() throws {
        let log = ClaudeLogBuilder()
        log.prompt("Look it up", parent: .some(nil))
        log.assistant(messageID: "m1", blocks: [["type": "tool_use", "id": "toolu_mcp", "name": "mcp__vibebar__quota_get", "input": ["tool": "codex"]]])
        log.toolResult(id: "toolu_mcp", content: "{}")
        let structure = try parse(log)
        let step = try XCTUnwrap(structure.turns[0].steps.first { $0.callID == "toolu_mcp" })
        XCTAssertEqual(step.kind, .mcpCall)
        XCTAssertEqual(step.name, "vibebar.quota_get")
        XCTAssertEqual(structure.stats.mcpCallCount, 1)
    }

    func testSidechainLinesRollUpInsteadOfJoiningTurns() throws {
        let log = ClaudeLogBuilder()
        let prompt = log.prompt("Use a subagent", parent: .some(nil))
        log.assistant(messageID: "m_main", blocks: [["type": "tool_use", "id": "toolu_task", "name": "Task", "input": ["description": "Sub"]]])
        log.line(["type": "user", "isSidechain": true, "agentId": "sc1", "message": ["role": "user", "content": "Sub task"]],
                 parent: .some(nil), chain: false)
        log.line(["type": "assistant", "isSidechain": true, "agentId": "sc1", "requestId": "req_sc",
                  "message": ["id": "m_sc", "role": "assistant", "model": "claude-haiku-4-5",
                              "content": [["type": "tool_use", "id": "toolu_sc", "name": "Grep", "input": ["pattern": "x"]]],
                              "usage": ["input_tokens": 3, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 40, "output_tokens": 7]]],
                 parent: .some(prompt), chain: false)
        log.line(["type": "user", "isSidechain": true, "agentId": "sc1",
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_sc", "content": "boom", "is_error": true]]]],
                 parent: .some(nil), chain: false)
        log.toolResult(id: "toolu_task", content: "Sub finished")
        log.assistant(messageID: "m_end", blocks: [["type": "text", "text": "Done"]], stopReason: "end_turn")
        let structure = try parse(log)

        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.stats.promptCount, 1, "the sidechain's own prompt is not the person's")
        XCTAssertEqual(structure.stats.toolCallCount, 1)
        XCTAssertEqual(structure.stats.failedToolCount, 0)
        let rollup = try XCTUnwrap(structure.sidechains.first)
        XCTAssertEqual(rollup.agentID, "sc1")
        XCTAssertEqual(rollup.lineCount, 3)
        XCTAssertEqual(rollup.toolCallCount, 1)
        XCTAssertEqual(rollup.failedToolCount, 1)
        XCTAssertEqual(rollup.usage.total, 50)
        XCTAssertEqual(rollup.models, ["claude-haiku-4-5"])
        XCTAssertEqual(structure.stats.sidechainUsage.total, 50)
        XCTAssertEqual(structure.stats.totalUsage.total, 50 + 2 * 1_160, "sidechain usage is part of the file's total")
        XCTAssertEqual(structure.turns[0].usage.total, 2 * 1_160)
    }

    func testInjectedContextSlashCommandsAndNotifications() throws {
        let log = ClaudeLogBuilder()
        log.prompt("<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>", parent: .some(nil))
        log.line(["type": "user", "message": ["role": "user", "content": "<local-command-stdout>Set model</local-command-stdout>"]])
        log.prompt("<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args>the parser change</command-args>")
        log.line(["type": "user", "isMeta": true, "message": ["role": "user", "content": [["type": "text", "text": "Skill body expanded here"]]]])
        log.line(["type": "attachment", "attachment": ["type": "todo_reminder"]])
        log.assistant(messageID: "m1", blocks: [["type": "text", "text": "Reviewing."]], stopReason: "end_turn")
        log.prompt("<task-notification><task-id>x</task-id><status>completed</status></task-notification>",
                   extra: ["origin": ["kind": "task-notification"]])
        log.assistant(messageID: "m2", blocks: [["type": "text", "text": "The background task finished."]], stopReason: "end_turn")
        log.prompt("<system-reminder>Be brief.</system-reminder>\nWhat changed?")
        log.assistant(messageID: "m3", blocks: [["type": "text", "text": "Two files."]], stopReason: "end_turn")
        let structure = try parse(log)

        XCTAssertEqual(structure.turns.count, 2)
        XCTAssertEqual(structure.turns[0].prompt.text, "/review the parser change")
        XCTAssertEqual(structure.turns[1].prompt.text, "What changed?")
        XCTAssertEqual(structure.stats.promptCount, 2, "a bare /model is a local command, not a prompt")
        let first = structure.turns[0].prompt
        XCTAssertEqual(first.injectedCount(.commandOutput), 2)
        XCTAssertEqual(first.injectedCount(.attachment), 1)
        XCTAssertEqual(first.injectedCount(.taskNotification), 1)
        XCTAssertEqual(first.injectedCount(.other), 1)
        XCTAssertEqual(structure.turns[1].prompt.injectedCount(.systemReminder), 1)
        XCTAssertEqual(structure.turns[0].finalAnswer, "The background task finished.")
    }

    func testShellEscapesAndInterruptionsAreNotPrompts() throws {
        let log = ClaudeLogBuilder()
        log.prompt("Refactor the reader", parent: .some(nil))
        log.assistant(messageID: "m1", blocks: [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "swift build"]]])
        log.prompt("[Request interrupted by user for tool use]")
        log.prompt("<bash-input>git status</bash-input>")
        log.line(["type": "user", "message": ["role": "user", "content": "<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>"]])
        let structure = try parse(log)
        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.turns[0].status, .aborted)
        XCTAssertEqual(structure.stats.promptCount, 1)
        XCTAssertEqual(structure.turns[0].prompt.injectedCount(.commandOutput), 2)
    }

    func testRewindMarksSkippedTurnsAbandoned() throws {
        let log = ClaudeLogBuilder()
        log.prompt("First", parent: .some(nil))
        let firstAnswer = log.assistant(messageID: "m1", blocks: [["type": "text", "text": "A1"]], stopReason: "end_turn")
        log.prompt("Second")
        log.assistant(messageID: "m2", blocks: [["type": "tool_use", "id": "toolu_x", "name": "Bash", "input": ["command": "false"]]])
        log.toolResult(id: "toolu_x", content: "exit 1", isError: true)
        log.prompt("Third")
        log.assistant(messageID: "m3", blocks: [["type": "text", "text": "A3"]], stopReason: "end_turn")
        // Rewound to after the first answer and asked again.
        log.prompt("Second, rephrased", parent: .some(firstAnswer))
        log.assistant(messageID: "m4", blocks: [["type": "text", "text": "A2'"]], stopReason: "end_turn")
        let structure = try parse(log)

        XCTAssertEqual(structure.turns.map(\.status), [.completed, .abandoned, .abandoned, .completed])
        XCTAssertEqual(structure.stats.promptCount, 2)
        XCTAssertEqual(structure.stats.failedToolCount, 0, "an abandoned turn's failures are not counted")
        XCTAssertEqual(structure.stats.turnCount, 4)
    }

    func testResumedLogSkipsLinesCopiedFromTheEarlierSession() throws {
        let log = ClaudeLogBuilder()
        log.sessionID = SessionStructureFixtures.claudeParentSessionID
        log.prompt("Earlier question", parent: .some(nil))
        log.assistant(messageID: "old", blocks: [["type": "text", "text": "Earlier answer"]], stopReason: "end_turn")
        log.sessionID = SessionStructureFixtures.claudeSessionID
        log.prompt("Picking up where we left off")
        log.assistant(messageID: "new", blocks: [["type": "text", "text": "Sure"]], stopReason: "end_turn")
        let structure = try parse(log)

        XCTAssertEqual(structure.stats.kind, .fork)
        XCTAssertEqual(structure.stats.relation, .forkOf)
        XCTAssertEqual(structure.stats.parentID, SessionStructureFixtures.claudeParentSessionID)
        XCTAssertEqual(structure.stats.forkStartOrdinal, 2)
        XCTAssertEqual(structure.diagnostics.inheritedLinesSkipped, 2)
        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.turns[0].prompt.text, "Picking up where we left off")
        XCTAssertEqual(structure.stats.totalUsage.total, 1_160)
    }

    func testSubagentSidecarFileIsItsOwnSession() throws {
        let log = ClaudeLogBuilder()
        log.line(["type": "user", "isSidechain": true, "agentId": "a77", "message": ["role": "user", "content": "Find the TODOs"]], parent: .some(nil))
        log.line(["type": "assistant", "isSidechain": true, "agentId": "a77", "requestId": "r",
                  "message": ["id": "m", "role": "assistant", "model": "claude-sonnet-4-5",
                              "content": [["type": "tool_use", "id": "toolu_g", "name": "Grep", "input": ["pattern": "TODO", "path": "/Users/example/project"]]],
                              "usage": ["input_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 1]]])
        let url = directory.appendingPathComponent("-Users-example-project/\(SessionStructureFixtures.claudeSessionID)/subagents/agent-a77.jsonl")
        let structure = try parse(log, url: url)

        XCTAssertEqual(structure.sessionID, "a77")
        XCTAssertEqual(structure.stats.kind, .subagent)
        XCTAssertEqual(structure.stats.relation, .spawnedBy)
        XCTAssertEqual(structure.stats.parentID, SessionStructureFixtures.claudeSessionID)
        XCTAssertEqual(structure.turns.first?.prompt.origin, .agent)
        XCTAssertEqual(structure.stats.promptCount, 0)
        XCTAssertEqual(structure.stats.toolCallCount, 1)
        XCTAssertEqual(structure.turns.first?.steps.first?.argsSummary, "TODO in /Users/example/project")
        XCTAssertTrue(structure.sidechains.isEmpty)
    }

    func testParentLinksAttributeLateLinesToTheirTurn() throws {
        let log = ClaudeLogBuilder()
        log.prompt("Start a long task", parent: .some(nil))
        let call = log.assistant(messageID: "m1", blocks: [["type": "tool_use", "id": "toolu_slow", "name": "Bash", "input": ["command": "sleep 5"]]])
        log.prompt("Meanwhile, a second question", parent: .some(call))
        log.assistant(messageID: "m2", blocks: [["type": "text", "text": "Answering the second"]], stopReason: "end_turn")
        // The slow result arrives last but hangs off the first turn's call.
        log.toolResult(id: "toolu_slow", content: "done", extra: [:])
        let structure = try parse(log)
        XCTAssertEqual(structure.turns.count, 2)
        let slow = try XCTUnwrap(structure.turns[0].steps.first { $0.callID == "toolu_slow" })
        XCTAssertEqual(slow.pairing, .paired)
        XCTAssertEqual(structure.diagnostics.orphanResults, 0)
    }

    func testCorruptAndOversizedLinesAreTolerated() throws {
        let log = basicLog()
        log.raw("{\"type\":\"user\",\"message\":")
        log.raw("not json")
        let structure = try parse(log)
        XCTAssertEqual(structure.diagnostics.undecodableLines, 2)
        XCTAssertEqual(structure.stats.promptCount, 1)

        let big = ClaudeLogBuilder()
        big.prompt("Show the screenshot", parent: .some(nil))
        big.assistant(messageID: "m", blocks: [["type": "tool_use", "id": "toolu_img", "name": "Read", "input": ["file_path": "/Users/example/a.png"]]])
        // Claude's own key order: the id precedes the (huge) content.
        big.raw(#"{"parentUuid":"\#(big.lastUUID!)","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_img","type":"tool_result","content":"\#(String(repeating: "A", count: 50_000))"}]},"uuid":"00000000-0000-4000-8000-999999999999","timestamp":"2026-05-01T10:00:09.000Z","sessionId":"\#(SessionStructureFixtures.claudeSessionID)"}"#)
        let url = try SessionStructureFixtures.write(big.lines, to: mainURL)
        let parsed = try XCTUnwrap(ClaudeSessionStructureParser.parse(
            fileURL: url, options: SessionStructureParseOptions(detail: .full, maxLineBytes: 8_192)
        ))
        XCTAssertEqual(parsed.diagnostics.oversizedLines, 1)
        XCTAssertEqual(parsed.turns[0].steps.first { $0.callID == "toolu_img" }?.pairing, .paired)
    }

    func testOutlineDetailMatchesFullCounts() throws {
        let full = try parse(basicLog())
        let outline = try parse(basicLog(), detail: .outline)
        XCTAssertEqual(outline.stats, full.stats)
        XCTAssertEqual(outline.turns.map(\.counts), full.turns.map(\.counts))
        XCTAssertTrue(outline.turns.allSatisfy { $0.steps.isEmpty && $0.prompt.text == nil })
    }
}
