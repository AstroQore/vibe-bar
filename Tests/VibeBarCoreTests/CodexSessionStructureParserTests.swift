import XCTest
@testable import VibeBarCore

final class CodexSessionStructureParserTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SessionStructureFixtures.temporaryDirectory("codex")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rolloutURL(_ id: String = SessionStructureFixtures.codexThreadID) -> URL {
        directory.appendingPathComponent("rollout-2026-05-01T10-00-00-\(id).jsonl")
    }

    private func parse(
        _ builder: CodexRolloutBuilder,
        id: String = SessionStructureFixtures.codexThreadID,
        options: SessionStructureParseOptions = SessionStructureParseOptions()
    ) throws -> SessionStructure {
        let url = try SessionStructureFixtures.write(builder.lines, to: rolloutURL(id))
        return try XCTUnwrap(CodexSessionStructureParser.parse(fileURL: url, options: options))
    }

    /// Two complete turns with a command, a patch, reasoning and usage.
    private func twoTurnRollout() -> CodexRolloutBuilder {
        CodexRolloutBuilder()
            .meta(gitBranch: "feature/outline")
            .taskStarted("turn-a")
            .developer()
            .userResponseItem("# AGENTS.md instructions for /Users/example/project\n\n<INSTRUCTIONS>be careful</INSTRUCTIONS>")
            .userResponseItem("<environment_context>\n  <cwd>/Users/example/project</cwd>\n</environment_context>")
            .turnContext(model: "gpt-5")
            .prompt("List the files in the project", turnID: "turn-a")
            .reasoning(id: "rs_1", summary: "Plan: run ls")
            .reasoningCompleted(id: "rs_1", durationMs: 1_200)
            .assistant("I'll look at the files.")
            .functionCall("exec_command", callID: "call_ls", arguments: ["cmd": "ls -la /Users/example/project"])
            .stringOutput(callID: "call_ls", text: "Chunk ID: 1a2b\nWall time: 0.0500 seconds\nProcess exited with code 0\nOriginal token count: 12\nOutput:\nREADME.md\n")
            .tokenCount(input: 1_000, cached: 200, output: 100)
            .tokenUsageRecord()
            .assistant("There is one file: README.md")
            .taskComplete("turn-a", durationMs: 5_000)
            .taskStarted("turn-b")
            .turnContext(model: "gpt-5")
            .prompt("Fix the typo in README.md", turnID: "turn-b")
            .customToolCall("apply_patch", callID: "call_patch", input: "*** Begin Patch\n*** Update File: /Users/example/project/README.md\n@@\n-teh\n+the\n*** End Patch")
            .stringOutput(callID: "call_patch", text: #"{"output":"Success.","metadata":{"exit_code":0,"duration_seconds":0.2}}"#, custom: true)
            .functionCall("exec_command", callID: "call_test", arguments: ["cmd": "swift test"])
            .stringOutput(callID: "call_test", text: "Exit code: 1\nWall time: 3.5 seconds\nOutput:\nerror: synthetic failure\n")
            .tokenCount(input: 2_000, cached: 1_500, output: 300)
            .assistant("Patched; the test run failed.")
            .taskComplete("turn-b", durationMs: 9_000, lastMessage: "Patched; the test run failed.")
    }

    // MARK: - Turns, prompts, injected context

    func testTurnsSplitOnTaskEventsWithPromptsAndAnswers() throws {
        let structure = try parse(twoTurnRollout())

        XCTAssertEqual(structure.sessionID, SessionStructureFixtures.codexThreadID)
        XCTAssertEqual(structure.turns.count, 2)
        let first = structure.turns[0]
        XCTAssertEqual(first.turnID, "turn-a")
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(first.prompt.origin, .human)
        XCTAssertEqual(first.prompt.text, "List the files in the project")
        XCTAssertEqual(first.finalAnswer, "There is one file: README.md")
        XCTAssertEqual(first.durationMs, 5_000)
        XCTAssertEqual(first.model, "gpt-5")
        XCTAssertTrue(first.steps.contains { $0.kind == .note && $0.name == "commentary" },
                      "an assistant message followed by a tool call is commentary, not the answer")
        XCTAssertEqual(structure.turns[1].prompt.preview, "Fix the typo in README.md")
        XCTAssertEqual(structure.stats.promptCount, 2)
        XCTAssertEqual(structure.stats.turnCount, 2)
        XCTAssertEqual(structure.stats.kind, .interactive)
        XCTAssertEqual(structure.stats.gitBranch, "feature/outline")
        XCTAssertEqual(structure.stats.cwd, "/Users/example/project")
        XCTAssertNotNil(structure.stats.durationMs)
    }

    func testInjectedBlocksAreCountedAndMirrorsAreNotPrompts() throws {
        let structure = try parse(twoTurnRollout())
        let injected = structure.turns[0].prompt
        XCTAssertEqual(injected.injectedCount(.agentsInstructions), 1)
        XCTAssertEqual(injected.injectedCount(.environmentContext), 1)
        XCTAssertEqual(injected.injectedCount(.developerMessage), 1)
        XCTAssertEqual(injected.additionalHumanMessages, 0, "the response-item copy of a prompt is a mirror")
        XCTAssertEqual(structure.stats.injectedBlockCount, 3, "\(structure.turns.map(\.prompt.injected))")
    }

    func testUnknownMachineBlockBeforeThePromptDoesNotCountAsASecondPrompt() throws {
        // A context block whose tag `HumanPromptText` does not know arrives
        // as a response item ahead of the real prompt; the `UserMessage`
        // item settles the turn at one prompt.
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .userResponseItem("<external_app_open_page>Settings</external_app_open_page>")
            .prompt("Open the settings page", turnID: "t1")
            .userResponseItem("Steer: use the dark theme")
            .userMessageItem("Steer: use the dark theme", turnID: "t1")
            .assistant("Done")
            .taskComplete("t1")
        let structure = try parse(builder)
        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.turns[0].prompt.text, "Open the settings page")
        XCTAssertEqual(structure.turns[0].prompt.additionalHumanMessages, 1)
        XCTAssertEqual(structure.stats.promptCount, 2)
    }

    func testRolloutWithoutTaskEventsSplitsOnHumanMessages() throws {
        let builder = CodexRolloutBuilder()
        builder.includeOrdinals = false
        builder.meta()
            .userResponseItem("<environment_context><cwd>/Users/example/a</cwd></environment_context>")
            .userResponseItem("First question")
            .assistant("First answer")
            .userResponseItem("Second question")
            .userResponseItem("…and a follow-up before any answer")
            .functionCall("shell", callID: "c1", arguments: ["command": ["bash", "-lc", "echo hi"]])
            .stringOutput(callID: "c1", text: #"{"output":"hi\n","metadata":{"exit_code":0,"duration_seconds":0.01}}"#)
            .assistant("Second answer")
        let structure = try parse(builder)

        XCTAssertEqual(structure.turns.count, 2)
        XCTAssertEqual(structure.turns[0].finalAnswer, "First answer")
        XCTAssertEqual(structure.turns[1].prompt.additionalHumanMessages, 1)
        XCTAssertEqual(structure.stats.promptCount, 3)
        XCTAssertEqual(structure.turns[1].steps.first { $0.kind == .command }?.argsSummary, "echo hi")
    }

    // MARK: - Calls

    func testCallsPairWithOutputsAndReportExitCodes() throws {
        let structure = try parse(twoTurnRollout())
        let ls = try XCTUnwrap(structure.turns[0].steps.first { $0.callID == "call_ls" })
        XCTAssertEqual(ls.kind, .command)
        XCTAssertEqual(ls.pairing, .paired)
        XCTAssertEqual(ls.exitCode, 0)
        XCTAssertEqual(ls.durationMs, 50)
        XCTAssertFalse(ls.isError)
        XCTAssertEqual(ls.argsSummary, "ls -la /Users/example/project", "paths are kept")
        XCTAssertEqual(ls.resultSummary, "README.md")

        let patch = try XCTUnwrap(structure.turns[1].steps.first { $0.callID == "call_patch" })
        XCTAssertEqual(patch.kind, .toolCall)
        XCTAssertEqual(patch.argsSummary, "/Users/example/project/README.md")
        XCTAssertEqual(patch.exitCode, 0)
        XCTAssertEqual(patch.durationMs, 200)

        let test = try XCTUnwrap(structure.turns[1].steps.first { $0.callID == "call_test" })
        XCTAssertTrue(test.isError)
        XCTAssertEqual(test.exitCode, 1)
        XCTAssertEqual(test.durationMs, 3_500)

        XCTAssertEqual(structure.turns[1].counts.steps, 2)
        XCTAssertEqual(structure.turns[1].counts.failed, 1)
        XCTAssertEqual(structure.stats.toolCallCount, 3)
        XCTAssertEqual(structure.stats.commandCount, 2)
        XCTAssertEqual(structure.stats.failedToolCount, 1)
        XCTAssertEqual(structure.diagnostics.pendingCalls, 0)
        XCTAssertEqual(structure.diagnostics.orphanResults, 0)
    }

    func testCompletedItemWithCallIDEnrichesTheCallInsteadOfAddingAStep() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Run the build", turnID: "t1")
            .functionCall("exec_command", callID: "call_build", arguments: ["cmd": "swift build"])
            .stringOutput(callID: "call_build", text: "Chunk ID: 9f\nWall time: 2.0 seconds\nProcess running with session ID 7\nOutput:\n")
            .commandExecution(id: "call_build", command: ["/bin/zsh", "-lc", "swift build"], exitCode: 2, seconds: 4, nanos: 0)
            .taskComplete("t1")
        let structure = try parse(builder)
        let steps = structure.turns[0].steps.filter { $0.kind.isAction }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].exitCode, 2)
        XCTAssertEqual(steps[0].durationMs, 4_000, "the completed item's duration outranks the output's wall time")
        XCTAssertTrue(steps[0].isError)
    }

    func testCompletedItemAloneFinishesItsCall() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Run the build", turnID: "t1")
            .functionCall("exec_command", callID: "call_only_item", arguments: ["cmd": "swift build"])
            .commandExecution(id: "call_only_item", command: ["/bin/zsh", "-lc", "swift build"], exitCode: 0, seconds: 3, nanos: 0)
            .commandExecution(id: "exec-loose", command: ["/bin/zsh", "-lc", "true"], exitCode: 0)
            .taskComplete("t1")
        let structure = try parse(builder)
        let only = try XCTUnwrap(structure.turns[0].steps.first { $0.callID == "call_only_item" })
        XCTAssertEqual(only.pairing, .paired)
        XCTAssertEqual(only.exitCode, 0)
        XCTAssertEqual(only.durationMs, 3_000)
        XCTAssertEqual(structure.diagnostics.pendingCalls, 0)
        XCTAssertEqual(structure.diagnostics.orphanResults, 0)
        // Once finished, the call no longer parents later items.
        let loose = try XCTUnwrap(structure.turns[0].steps.first { $0.name == "command" && $0.callID == nil })
        XCTAssertNil(loose.parentCallID)
    }

    func testItemBeforeOutputMergesIntoOneStep() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Run the tests", turnID: "t1")
            .functionCall("exec_command", callID: "call_tests", arguments: ["cmd": "swift test"])
            .commandExecution(id: "call_tests", command: ["/bin/zsh", "-lc", "swift test"], exitCode: 1, seconds: 2, nanos: 0)
            .stringOutput(callID: "call_tests", text: "Chunk ID: 1\nWall time: 2.1 seconds\nProcess exited with code 1\nOutput:\nerror: failed\n")
            .taskComplete("t1")
        let structure = try parse(builder)
        let actions = structure.turns[0].steps.filter(\.kind.isAction)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].pairing, .paired)
        XCTAssertEqual(actions[0].exitCode, 1)
        XCTAssertEqual(actions[0].durationMs, 2_000, "the completed item's duration is kept")
        XCTAssertTrue(actions[0].isError)
        XCTAssertEqual(actions[0].resultSummary, "error: failed")
        XCTAssertEqual(structure.diagnostics.pendingCalls, 0)
        XCTAssertEqual(structure.diagnostics.orphanResults, 0)
        XCTAssertEqual(structure.stats.failedToolCount, 1)
    }

    func testCodeModeExecNestsCommandsAndMCPCallsUnderTheScript() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Check the page", turnID: "t1")
            .customToolCall("exec", callID: "call_js", input: "const r = await tools.exec_command({cmd: 'git status'});\ntext(r);")
            .commandExecution(id: "exec-0001", command: ["/bin/zsh", "-lc", "git status"], exitCode: 0)
            .mcpToolCall(id: "exec-0002", server: "browser", tool: "js", failed: true)
            .output(callID: "call_js", text: "Script completed\nWall time 1.5 seconds\nOutput:\nclean\n", custom: true)
            .taskComplete("t1")
        let structure = try parse(builder)
        let steps = structure.turns[0].steps.filter { $0.kind.isAction }
        XCTAssertEqual(steps.map(\.kind), [.toolCall, .command, .mcpCall])
        XCTAssertEqual(steps[1].parentCallID, "call_js")
        XCTAssertEqual(steps[2].parentCallID, "call_js")
        XCTAssertEqual(steps[2].name, "browser.js")
        XCTAssertTrue(steps[2].isError)
        XCTAssertEqual(steps[1].durationMs, 250)
        XCTAssertEqual(steps[0].durationMs, 1_500)
        XCTAssertFalse(steps[0].isError)
        XCTAssertEqual(structure.stats.commandCount, 1)
        XCTAssertEqual(structure.stats.mcpCallCount, 1)
        XCTAssertEqual(structure.stats.failedToolCount, 1)
    }

    func testReasoningBecomesThinkingWithDurationInEitherOrder() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Think", turnID: "t1")
            .reasoningCompleted(id: "rs_a", durationMs: 700)
            .reasoning(id: "rs_a", summary: "Considering options")
            .reasoning(id: "rs_b", summary: "Deciding")
            .reasoningCompleted(id: "rs_b", durationMs: 300)
            .assistant("Done")
            .taskComplete("t1")
        let structure = try parse(builder)
        let thinking = structure.turns[0].steps.filter { $0.kind == .thinking }
        XCTAssertEqual(thinking.map(\.durationMs), [700, 300])
        XCTAssertEqual(thinking[0].thinkingCharacters, "Considering options".count)
        XCTAssertEqual(thinking[0].resultSummary, "Considering options")
        XCTAssertEqual(structure.turns[0].counts.thinking, 2)
        XCTAssertEqual(structure.turns[0].counts.steps, 0, "thinking is not an action")
    }

    func testSpawnAgentOutputLinksTheChildThread() throws {
        let child = "0190aaaa-0000-7000-8000-00000000c0de"
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Delegate the audit", turnID: "t1")
            .functionCall("spawn_agent", callID: "call_spawn", arguments: ["message": "Audit the parser"])
            .stringOutput(callID: "call_spawn", text: #"{"agent_id":"\#(child)","nickname":"Auditor"}"#)
            .taskComplete("t1")
        let structure = try parse(builder)
        let step = try XCTUnwrap(structure.turns[0].steps.first { $0.callID == "call_spawn" })
        XCTAssertEqual(step.kind, .subagent)
        XCTAssertEqual(step.childSessionID, child)
        XCTAssertEqual(step.argsSummary, "Audit the parser")
        XCTAssertEqual(structure.stats.subagentCount, 1)
    }

    // MARK: - Usage & cost

    func testUsageIsPerTurnDeltaAndTotalMatchesTheLastCounter() throws {
        let structure = try parse(twoTurnRollout())
        // Turn A: 1000 in (200 cached) + 100 out; the token_usage_record
        // repeats the same cumulative counter and adds nothing.
        XCTAssertEqual(structure.turns[0].usage, .init(input: 800, cacheWrite: 0, cacheRead: 200, output: 100))
        XCTAssertEqual(structure.turns[1].usage, .init(input: 500, cacheWrite: 0, cacheRead: 1_500, output: 300))
        XCTAssertEqual(structure.stats.totalTokens, 3_400)
        XCTAssertEqual(structure.stats.totalUsage.total, 3_400)
        XCTAssertEqual(structure.stats.usageSource, .cumulativeCounter)
        XCTAssertEqual(structure.stats.cumulativeTokensIncludingInherited, 3_400, "an uncut session's counter is its own")
        XCTAssertEqual(structure.stats.models, ["gpt-5"])
        let cost = try XCTUnwrap(structure.stats.estimatedCostUSD)
        XCTAssertGreaterThan(cost, 0)
        XCTAssertFalse(structure.stats.hasUnpricedUsage)
        XCTAssertEqual(structure.stats.modelUsage.first?.usage.total, 3_400)
    }

    func testCounterResetSumsEpochsInsteadOfKeepingTheLastValue() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .turnContext(model: "gpt-5")
            .prompt("Long task", turnID: "t1")
            .tokenCount(input: 900, cached: 0, output: 100)
            .assistant("Part one")
            .taskComplete("t1")
            .resetCounter()
            .taskStarted("t2")
            .turnContext(model: "gpt-5")
            .prompt("Continue", turnID: "t2")
            .tokenCount(input: 90, cached: 0, output: 10)
            .assistant("Part two")
            .taskComplete("t2")
        let structure = try parse(builder)
        XCTAssertEqual(structure.turns.map(\.usage.total), [1_000, 100])
        XCTAssertEqual(structure.stats.counterResets, 1)
        XCTAssertEqual(structure.stats.totalTokens, 1_100)
        XCTAssertEqual(structure.stats.totalUsage.total, 1_100)
        XCTAssertEqual(structure.stats.usageSource, .ownCounterDeltas)
        XCTAssertEqual(structure.stats.cumulativeTokensIncludingInherited, 100, "the raw last counter is kept as written")
        XCTAssertEqual(structure.stats.modelUsage.reduce(0) { $0 + $1.usage.total }, 1_100)
    }

    func testUnknownModelLeavesCostNil() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .turnContext(model: "synthetic-model-without-price")
            .prompt("Hello", turnID: "t1")
            .tokenCount(input: 100, cached: 0, output: 10)
            .assistant("Hi")
            .taskComplete("t1")
        let structure = try parse(builder)
        XCTAssertNil(structure.stats.estimatedCostUSD)
        XCTAssertTrue(structure.stats.hasUnpricedUsage)
        XCTAssertEqual(structure.stats.totalTokens, 110)
        XCTAssertNil(structure.stats.modelUsage.first?.costUSD)
    }

    // MARK: - Session kinds & inherited history

    func testThreadSpawnForkSkipsCopiedParentHistory() throws {
        let builder = CodexRolloutBuilder()
        builder.meta(
            parentThreadID: SessionStructureFixtures.codexParentID,
            forkedFrom: SessionStructureFixtures.codexParentID,
            source: ["subagent": ["thread_spawn": ["parent_thread_id": SessionStructureFixtures.codexParentID, "depth": 1]]],
            threadSource: "subagent",
            historyStart: 9
        )
        // Ordinals 1…8: the parent's turn, copied verbatim.
        builder.taskStarted("parent-turn")
            .prompt("Parent prompt", turnID: "parent-turn")
            .functionCall("exec_command", callID: "parent_call", arguments: ["cmd": "make"])
            .stringOutput(callID: "parent_call", text: "Exit code: 0\nWall time: 1 seconds\nOutput:\n")
            .tokenCount(input: 5_000, cached: 0, output: 500)
            .assistant("Parent answer")
            .taskComplete("parent-turn")
        XCTAssertEqual(builder.ordinalNow, 9)
        builder.taskStarted("child-turn")
            .raw(SessionStructureFixtures.jsonLine([
                "timestamp": SessionStructureFixtures.stamp(30), "ordinal": 10, "type": "response_item",
                "payload": ["type": "agent_message", "author": "parent", "recipient": "child",
                            "content": [["type": "input_text", "text": "Audit the parser"]]]
            ]))
            .functionCall("exec_command", callID: "child_call", arguments: ["cmd": "rg TODO"])
            .stringOutput(callID: "child_call", text: "Exit code: 0\nWall time: 0.1 seconds\nOutput:\n")
            .tokenCount(input: 300, cached: 0, output: 30)
            .assistant("Child answer")
            .taskComplete("child-turn")
        let structure = try parse(builder)

        XCTAssertEqual(structure.stats.kind, .subagent)
        XCTAssertEqual(structure.stats.relation, .spawnedBy)
        XCTAssertEqual(structure.stats.parentID, SessionStructureFixtures.codexParentID)
        XCTAssertEqual(structure.stats.forkStartOrdinal, 9)
        XCTAssertEqual(structure.diagnostics.inheritedLinesSkipped, 8)
        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.turns[0].prompt.origin, .agent)
        XCTAssertEqual(structure.turns[0].prompt.text, "Audit the parser")
        XCTAssertEqual(structure.stats.toolCallCount, 1)
        XCTAssertEqual(structure.stats.promptCount, 0, "a subagent's task is not a human prompt")
        XCTAssertEqual(structure.turns[0].usage.total, 330, "usage is the delta past the inherited counter")
        // The counter itself ran on from the parent's 5 500.
        XCTAssertEqual(structure.stats.totalTokens, 330)
        XCTAssertEqual(structure.stats.totalUsage.total, 330)
        XCTAssertEqual(structure.stats.usageSource, .ownCounterDeltas)
        XCTAssertEqual(structure.stats.cumulativeTokensIncludingInherited, 5_830)
        XCTAssertEqual(structure.stats.counterResets, 0)
        XCTAssertEqual(structure.stats.modelUsage.reduce(0) { $0 + $1.usage.total }, 330)
    }

    func testUserForkWithoutHistoryOrdinalIsKeptWhole() throws {
        let builder = CodexRolloutBuilder()
            .meta(forkedFrom: SessionStructureFixtures.codexParentID, threadSource: "user")
            .taskStarted("t1").prompt("Continue from here", turnID: "t1").assistant("OK").taskComplete("t1")
        let structure = try parse(builder)
        XCTAssertEqual(structure.stats.kind, .fork)
        XCTAssertEqual(structure.stats.relation, .forkOf)
        XCTAssertEqual(structure.stats.parentID, SessionStructureFixtures.codexParentID)
        XCTAssertNil(structure.stats.forkStartOrdinal)
        XCTAssertEqual(structure.stats.promptCount, 1)
    }

    private func guardianRollout(sessionID: String?, parent: String?, historyStart: Int?, outcome: String) -> CodexRolloutBuilder {
        let builder = CodexRolloutBuilder()
            .meta(
                sessionID: sessionID,
                parentThreadID: parent,
                source: ["subagent": ["other": "guardian"]],
                threadSource: "guardian_review",
                historyStart: historyStart
            )
            .taskStarted("review-1")
            .userResponseItem("Transcript excerpt under review", metadata: [
                "guardian_sources": [["complete": true, "id": ["message_id": "msg_1", "turn_id": "parent-turn-7", "role": "assistant"]]]
            ])
            .userMessageItem("Review the pending command", turnID: "review-1")
            .tokenCount(input: 400, cached: 0, output: 20)
            .assistant(#"{"risk_level":"low","user_authorization":"high","outcome":"\#(outcome)","rationale":"The command only reads files."}"#)
            .taskComplete("review-1")
        return builder
    }

    func testGuardianLegacySelfReferencingHasNoParent() throws {
        // 0.124–0.136: session_id is the guardian's own id, no parent field.
        let structure = try parse(guardianRollout(sessionID: nil, parent: nil, historyStart: nil, outcome: "allow"))
        XCTAssertEqual(structure.stats.kind, .guardian)
        XCTAssertNil(structure.stats.parentID)
        XCTAssertNil(structure.stats.rootSessionID)
        XCTAssertEqual(structure.stats.guardianAllowCount, 1)
        let verdict = try XCTUnwrap(structure.turns[0].steps.first { $0.kind == .guardianVerdict })
        XCTAssertEqual(verdict.verdict, .init(outcome: "allow", riskLevel: "low", userAuthorization: "high"))
        XCTAssertEqual(verdict.resultSummary, "The command only reads files.")
        XCTAssertFalse(verdict.isError)
        XCTAssertEqual(structure.turns[0].prompt.origin, .guardianRequest)
        XCTAssertEqual(structure.stats.promptCount, 0)
    }

    func testGuardianPrereleaseNamesTheRealParent() throws {
        // 0.137–0.142 pre-release: session_id is still self; the parent is explicit.
        let structure = try parse(guardianRollout(
            sessionID: nil, parent: SessionStructureFixtures.codexParentID, historyStart: nil, outcome: "allow"
        ))
        XCTAssertEqual(structure.stats.parentID, SessionStructureFixtures.codexParentID)
        XCTAssertEqual(structure.stats.relation, .reviews)
        XCTAssertNil(structure.stats.rootSessionID)
    }

    func testGuardianCurrentShapeKeepsRootAndIsNeverCut() throws {
        // 0.142.0+: session_id is the root, parent_thread_id the intermediate
        // subagent, and subagent_history_start_ordinal points past every
        // line — which must not cut the guardian's own reviews.
        let structure = try parse(guardianRollout(
            sessionID: SessionStructureFixtures.codexRootID,
            parent: SessionStructureFixtures.codexParentID,
            historyStart: 99,
            outcome: "deny"
        ))
        XCTAssertEqual(structure.stats.parentID, SessionStructureFixtures.codexParentID)
        XCTAssertEqual(structure.stats.rootSessionID, SessionStructureFixtures.codexRootID)
        XCTAssertNil(structure.stats.forkStartOrdinal)
        XCTAssertEqual(structure.diagnostics.inheritedLinesSkipped, 0)
        XCTAssertEqual(structure.stats.usageSource, .cumulativeCounter, "an uncut guardian keeps the counter as its total")
        XCTAssertEqual(structure.stats.totalTokens, 420)
        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.turns[0].reviewedTurnID, "parent-turn-7")
        XCTAssertEqual(structure.stats.guardianDenyCount, 1)
        XCTAssertEqual(structure.stats.failedToolCount, 1, "a denial is a failed step")
        XCTAssertEqual(structure.turns[0].prompt.preview, "Review the pending command")
    }

    func testAutomationExecAndAgentCreatedKinds() throws {
        let automation = try parse(CodexRolloutBuilder().meta(threadSource: "automation")
            .taskStarted("a").prompt("Nightly report", turnID: "a").assistant("Sent").taskComplete("a")
            .taskStarted("b").prompt("Thanks, also include costs", turnID: "b").assistant("Done").taskComplete("b"))
        XCTAssertEqual(automation.stats.kind, .automation)
        XCTAssertEqual(automation.turns.map(\.prompt.origin), [.automation, .human])
        XCTAssertEqual(automation.stats.promptCount, 1)

        let exec = try parse(CodexRolloutBuilder().meta(source: "exec", threadSource: nil), id: "0190aaaa-0000-7000-8000-000000000e1e")
        XCTAssertEqual(exec.stats.kind, .exec)

        let created = try parse(CodexRolloutBuilder().meta(parentThreadID: SessionStructureFixtures.codexParentID, threadSource: "agent_created_thread"),
                                id: "0190aaaa-0000-7000-8000-0000000c4ea7")
        XCTAssertEqual(created.stats.kind, .agentCreated)
        XCTAssertEqual(created.stats.relation, .createdBy)
    }

    // MARK: - Robustness

    func testCorruptLinesAreSkippedWithoutStoppingTheParse() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .raw("{not json at all")
            .prompt("Still counted", turnID: "t1")
            .raw("[1,2,3]")
            .assistant("Fine")
            .taskComplete("t1")
        let structure = try parse(builder)
        XCTAssertEqual(structure.diagnostics.undecodableLines, 2)
        XCTAssertEqual(structure.stats.promptCount, 1)
        XCTAssertEqual(structure.turns.first?.finalAnswer, "Fine")
        XCTAssertFalse(structure.diagnostics.incomplete)
    }

    func testOversizedOutputLineIsPairedFromItsHead() throws {
        let huge = String(repeating: "x", count: 40_000)
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Screenshot please", turnID: "t1")
            .functionCall("view_image", callID: "call_img", arguments: ["path": "/Users/example/shot.png"])
            .output(callID: "call_img", text: huge)
            .assistant("Here it is")
            .taskComplete("t1")
        let structure = try parse(builder, options: SessionStructureParseOptions(detail: .full, maxLineBytes: 16 * 1024))
        XCTAssertEqual(structure.diagnostics.oversizedLines, 1)
        let step = try XCTUnwrap(structure.turns[0].steps.first { $0.callID == "call_img" })
        XCTAssertEqual(step.pairing, .paired)
        XCTAssertTrue(step.resultSummary?.hasPrefix("[output too large") ?? false)
        XCTAssertEqual(structure.diagnostics.pendingCalls, 0)
    }

    func testArgumentSummariesMaskCredentialsButKeepPaths() throws {
        let builder = CodexRolloutBuilder()
            .meta()
            .taskStarted("t1")
            .prompt("Call the API", turnID: "t1")
            .functionCall("exec_command", callID: "c1", arguments: [
                "cmd": "curl -H 'Authorization: Bearer sk-synthetic0123456789abcdef' https://api.example.com/v1 > /Users/example/out.json"
            ])
            .taskComplete("t1")
        let structure = try parse(builder)
        let args = try XCTUnwrap(structure.turns[0].steps.first?.argsSummary)
        XCTAssertFalse(args.contains("sk-synthetic0123456789abcdef"))
        XCTAssertTrue(args.contains("<redacted>"))
        XCTAssertLessThanOrEqual(args.count, SessionStructure.Step.summaryLimit)
        XCTAssertEqual(structure.diagnostics.pendingCalls, 1, "a call without output stays pending")
        XCTAssertEqual(structure.turns[0].steps.first?.pairing, .pending)
    }

    // MARK: - Detail & windows

    func testOutlineDetailKeepsCountsAndDropsStepsAndText() throws {
        let full = try parse(twoTurnRollout())
        let outline = try parse(twoTurnRollout(), options: SessionStructureParseOptions(detail: .outline))
        XCTAssertEqual(outline.detail, .outline)
        XCTAssertTrue(outline.turns.allSatisfy { $0.steps.isEmpty && $0.finalAnswer == nil && $0.prompt.text == nil })
        XCTAssertEqual(outline.turns.map(\.counts), full.turns.map(\.counts))
        XCTAssertEqual(outline.turns.map(\.usage), full.turns.map(\.usage))
        XCTAssertEqual(outline.turns.map(\.prompt.preview), full.turns.map(\.prompt.preview))
        XCTAssertEqual(outline.stats, full.stats)
    }

    func testByteWindowParsesOnlyThatTurn() throws {
        let full = try parse(twoTurnRollout())
        let second = full.turns[1]
        let window = try parse(twoTurnRollout(), options: SessionStructureParseOptions(detail: .full, byteRange: second.byteRange))
        XCTAssertEqual(window.turns.count, 1)
        XCTAssertEqual(window.turns[0].turnID, "turn-b")
        XCTAssertEqual(window.turns[0].byteOffset, second.byteOffset)
        XCTAssertEqual(window.turns[0].steps.filter(\.kind.isAction).map(\.callID), ["call_patch", "call_test"])
        XCTAssertEqual(window.turns[0].counts, second.counts)
    }
}
