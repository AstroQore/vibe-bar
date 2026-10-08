import XCTest
@testable import VibeBarCore

final class SessionStructureLineReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SessionStructureFixtures.temporaryDirectory("reader")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines(in url: URL, range: SessionStructure.ByteRange? = nil, maxLineBytes: Int = 1 << 20)
        -> (lines: [(String, Int64, Bool)], outcome: SessionStructureLineReader.Outcome) {
        var collected: [(String, Int64, Bool)] = []
        let outcome = SessionStructureLineReader.forEachLine(in: url, range: range, maxLineBytes: maxLineBytes, headBytes: 8) { line in
            collected.append((String(decoding: line.data, as: UTF8.self), line.offset, line.isTruncated))
            return true
        }
        return (collected, outcome)
    }

    func testOffsetsBlankLinesAndMissingTrailingNewline() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data("alpha\n\nbeta\ngamma".utf8).write(to: url)
        let result = lines(in: url)
        XCTAssertEqual(result.lines.map(\.0), ["alpha", "beta", "gamma"])
        XCTAssertEqual(result.lines.map(\.1), [0, 7, 12])
        XCTAssertTrue(result.outcome.completed)
    }

    func testWindowResynchronizesOnTheNextLineAndStopsAtItsEnd() throws {
        let url = directory.appendingPathComponent("b.jsonl")
        try Data("0123\n5678\nabcd\nefgh\n".utf8).write(to: url)
        // Starts mid-line 1: that partial line is skipped.
        XCTAssertEqual(lines(in: url, range: .init(2, 12)).lines.map(\.0), ["5678", "abcd"])
        // Starts exactly on a line: included. A line starting at the upper
        // bound is not.
        XCTAssertEqual(lines(in: url, range: .init(5, 10)).lines.map(\.0), ["5678"])
        XCTAssertEqual(lines(in: url, range: .init(10, 100)).lines.map(\.0), ["abcd", "efgh"])
    }

    func testOversizedLineKeepsOnlyItsHead() throws {
        let url = directory.appendingPathComponent("c.jsonl")
        try Data(("short\n" + String(repeating: "z", count: 5_000) + "\nafter\n").utf8).write(to: url)
        let result = lines(in: url, maxLineBytes: 1_024)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.lines[1].0, "zzzzzzzz", "only `headBytes` of an oversized line are kept")
        XCTAssertTrue(result.lines[1].2)
        XCTAssertEqual(result.lines[2].0, "after")
        XCTAssertEqual(result.lines[2].1, 6 + 5_000 + 1)
    }

    /// The streaming guarantee: a 50 000-line rollout parsed through a byte
    /// window reads that window (plus at most a chunk either side), not the
    /// file — so a turn of a multi-GB rollout costs the turn.
    func testFiftyThousandLineRolloutWindowReadsOnlyItsBytes() throws {
        let builder = CodexRolloutBuilder().meta()
        var turn = 0
        while builder.lines.count < 50_000 {
            builder.taskStarted("turn-\(turn)")
                .prompt("Question \(turn)", turnID: "turn-\(turn)")
                .functionCall("exec_command", callID: "call-\(turn)", arguments: ["cmd": "echo \(turn)"])
                .stringOutput(callID: "call-\(turn)", text: "Exit code: \(turn % 7 == 0 ? 1 : 0)\nWall time: 0.1 seconds\nOutput:\n\(turn)\n")
                .tokenCount(input: 100, cached: 50, output: 10)
                .assistant("Answer \(turn)")
                .taskComplete("turn-\(turn)")
            turn += 1
        }
        let url = try SessionStructureFixtures.write(
            builder.lines,
            to: directory.appendingPathComponent("rollout-2026-05-01T10-00-00-\(SessionStructureFixtures.codexThreadID).jsonl")
        )
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
        XCTAssertGreaterThan(fileSize, 8 * 1024 * 1024)

        let outline = try XCTUnwrap(CodexSessionStructureParser.parse(fileURL: url, options: .init(detail: .outline)))
        XCTAssertEqual(outline.turns.count, turn)
        XCTAssertEqual(outline.diagnostics.bytesRead, fileSize)
        XCTAssertEqual(outline.stats.toolCallCount, turn)
        XCTAssertEqual(outline.stats.failedToolCount, (0..<turn).filter { $0 % 7 == 0 }.count)
        XCTAssertTrue(outline.turns.allSatisfy(\.steps.isEmpty))

        let middle = outline.turns[turn / 2]
        let window = try XCTUnwrap(CodexSessionStructureParser.parse(
            fileURL: url, options: .init(detail: .full, byteRange: middle.byteRange)
        ))
        XCTAssertEqual(window.turns.count, 1)
        XCTAssertEqual(window.turns[0].prompt.text, "Question \(turn / 2)")
        XCTAssertEqual(window.turns[0].counts, middle.counts)
        let chunk = Int64(SessionStructureLineReader.chunkSize)
        XCTAssertLessThanOrEqual(window.diagnostics.bytesRead, middle.byteRange.count + 2 * chunk)
        XCTAssertLessThan(window.diagnostics.bytesRead * 50, fileSize)
    }

    // MARK: - Text helpers

    func testPreviewCollapsesWhitespaceAndCapsWithEllipsis() {
        XCTAssertEqual(SessionStructureText.preview("  a\n\n b  c ", limit: 20), "a b c")
        XCTAssertEqual(SessionStructureText.preview("abcdef", limit: 4), "abc…")
        XCTAssertEqual(SessionStructureText.preview("abcd", limit: 4), "abcd")
        XCTAssertEqual(SessionStructureText.preview(String(repeating: "x ", count: 1_000), limit: 120).count, 120)
    }

    func testFastISODateMatchesFoundation() throws {
        for raw in ["2026-10-08T12:34:56.789Z", "2026-10-08T12:34:56Z", "2026-10-08T12:34:56.123456Z", "2026-10-08T14:34:56.5+02:00"] {
            let fast = try XCTUnwrap(SessionStructureText.fastISODate(raw), raw)
            let reference = try XCTUnwrap(SessionParsing.date(raw), raw)
            XCTAssertEqual(fast.timeIntervalSince1970, reference.timeIntervalSince1970, accuracy: 0.001, raw)
        }
        XCTAssertNil(SessionStructureText.fastISODate("yesterday"))
    }

    func testInjectedBlockClassification() {
        XCTAssertEqual(SessionStructureText.injectedBlock(for: "# AGENTS.md instructions for /Users/example/x"), .agentsInstructions)
        XCTAssertEqual(SessionStructureText.injectedBlock(for: "<environment_context>…"), .environmentContext)
        XCTAssertEqual(SessionStructureText.injectedBlock(for: "<system-reminder>x</system-reminder>"), .systemReminder)
        XCTAssertEqual(SessionStructureText.injectedBlock(for: "<local-command-stdout>ok"), .commandOutput)
        XCTAssertNil(SessionStructureText.injectedBlock(for: "Please fix <b>this</b>"))
        XCTAssertEqual(SessionStructureText.injectedBlocks(in: "<system-reminder>a</system-reminder> hi <task-notification>b</task-notification>"),
                       [.systemReminder, .taskNotification])
    }

    func testCodexToolOutputShapes() {
        let json = CodexToolOutput.classify(#"{"output":"done","metadata":{"exit_code":3,"duration_seconds":1.25}}"#)
        XCTAssertEqual(json.exitCode, 3)
        XCTAssertEqual(json.durationMs, 1_250)
        XCTAssertTrue(json.isError)
        XCTAssertEqual(json.body, "done")

        let shell = CodexToolOutput.classify("Exit code: 0\nWall time: 0.5 seconds\nOutput:\nok\n")
        XCTAssertEqual(shell.exitCode, 0)
        XCTAssertEqual(shell.durationMs, 500)
        XCTAssertFalse(shell.isError)
        XCTAssertEqual(shell.body, "ok\n")

        let unified = CodexToolOutput.classify("Chunk ID: ab12\nWall time: 2 seconds\nProcess running with session ID 4\nOriginal token count: 3\nOutput:\n")
        XCTAssertTrue(unified.isRunning)
        XCTAssertNil(unified.exitCode)

        let script = CodexToolOutput.classify("Script failed\nWall time 0.3 seconds\nOutput:\nReferenceError\n")
        XCTAssertTrue(script.isError)
        XCTAssertEqual(script.durationMs, 300)

        XCTAssertTrue(CodexToolOutput.classify("apply_patch verification failed: no such file").isError)
        XCTAssertFalse(CodexToolOutput.classify("Plan updated").isError)
    }

    func testSessionStructureRoundTripsThroughJSON() throws {
        var structure = SessionStructure(provider: .codex, sessionID: "s", sourcePath: "/Users/example/r.jsonl", detail: .full)
        var turn = SessionStructure.Turn(index: 0, turnID: "t", startedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .completed)
        turn.prompt = .init(origin: .human, text: "Hi", preview: "Hi", injected: ["skill": 1])
        turn.steps = [.init(kind: .guardianVerdict, name: "guardian", verdict: .init(outcome: "deny", riskLevel: "high"))]
        turn.usage = .init(input: 1, cacheWrite: 2, cacheRead: 3, output: 4)
        structure.turns = [turn]
        structure.stats.kind = .guardian
        structure.stats.modelUsage = [.init(model: "m", usage: turn.usage, costUSD: nil)]
        let data = try JSONEncoder().encode(structure)
        XCTAssertEqual(try JSONDecoder().decode(SessionStructure.self, from: data), structure)
        XCTAssertEqual(structure.outline.first?.promptPreview, "Hi")
        XCTAssertEqual(structure.outlineOnly.turns.first?.steps, [])
    }
}

extension SessionStructureLineReaderTests {
    func testCredentialPrecheckCoversTheRedactorsShapes() {
        for sample in [
            "curl -H 'Authorization: Bearer abcdefghijklmnop'",
            "export OPENAI_API_KEY=sk-proj-abcdefgh12345678",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJleGFtcGxlIn0.c2lnbmF0dXJlLXN5bnRoZXRpYw",
            "sessionKey=abc123", "password: hunter2", "Cookie: a=b"
        ] {
            XCTAssertTrue(SessionStructureText.mayContainCredential(sample), sample)
            XCTAssertNotEqual(SessionStructureText.summary(sample), sample, sample)
        }
        XCTAssertFalse(SessionStructureText.mayContainCredential("rg -n TODO /Users/example/project/Sources"))
        XCTAssertEqual(SessionStructureText.summary("rg -n TODO /Users/example/project/Sources"), "rg -n TODO /Users/example/project/Sources")
        XCTAssertFalse(SessionStructureText.summary("mail someone@example.com")?.contains("someone@example.com") ?? true)
    }
}
