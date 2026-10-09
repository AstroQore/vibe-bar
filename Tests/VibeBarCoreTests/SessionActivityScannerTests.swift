import XCTest
@testable import VibeBarCore

/// `SessionActivityScanner` over synthetic logs written in each harness's
/// own key order. Every path, id and text is made up.
final class SessionActivityScannerTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static let codexLines: [String] = [
        #"{"timestamp":"2026-05-01T10:00:00.000Z","type":"session_meta","payload":{"id":"0190aaaa-0000-7000-8000-000000000001","cwd":"/Users/example/project"}}"#,
        // A developer message listing installed skills is not a use.
        #"{"timestamp":"2026-05-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"- alpha: /Users/example/.agents/skills/alpha/SKILL.md"}]}}"#,
        #"{"timestamp":"2026-05-01T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<skill>\n<name>alpha</name>\n<path>/Users/example/.agents/skills/alpha/SKILL.md</path>\nbody</skill>"}]}}"#,
        #"{"timestamp":"2026-05-01T10:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","name":"exec","input":"cat /Users/example/.agents/skills/beta/SKILL.md","call_id":"c1"}}"#,
        #"{"timestamp":"2026-05-01T10:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"name: beta"}}"#,
        #"{"timestamp":"2026-05-01T10:00:05.000Z","type":"response_item","payload":{"type":"function_call","id":"fc_1","name":"js","arguments":"{}","call_id":"c2"}}"#,
        #"{"timestamp":"2026-05-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":12000,"output_tokens":500,"total_tokens":12500},"last_token_usage":{"input_tokens":12000,"cached_input_tokens":8000,"output_tokens":500,"total_tokens":12500},"model_context_window":272000}}}"#,
        // A rate-limit refresh repeats the totals; not a request.
        #"{"timestamp":"2026-05-01T10:00:07.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":12000,"output_tokens":500,"total_tokens":12500},"last_token_usage":{"input_tokens":12000,"output_tokens":500,"total_tokens":12500},"model_context_window":272000}}}"#,
        #"{"timestamp":"2026-05-01T10:00:08.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":29000,"output_tokens":1000,"total_tokens":30000},"last_token_usage":{"input_tokens":17000,"output_tokens":500,"total_tokens":17500},"model_context_window":272000}}}"#,
        #"{"timestamp":"2026-05-02T09:00:00.000Z","type":"response_item","payload":{"type":"web_search_call","id":"ws_1","status":"completed"}}"#,
    ]

    static let claudeLines: [String] = [
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-05-01T11:00:00.000Z","sessionId":"s"}"#,
        #"{"parentUuid":"u1","type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"uuid":"u2","timestamp":"2026-05-01T11:00:02.000Z"}"#,
        #"{"parentUuid":"u2","type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Skill","input":{"skill":"gamma"}}]},"uuid":"u3","timestamp":"2026-05-01T11:00:04.000Z"}"#,
        #"{"parentUuid":"u3","isMeta":true,"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/example/.claude/skills/gamma\n\n# Gamma"}]},"uuid":"u4","timestamp":"2026-05-01T11:00:05.000Z"}"#,
        // A slash command loads a skill with no tool call.
        #"{"parentUuid":"u4","isMeta":true,"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/example/.claude/skills/delta\n\n# Delta"}]},"uuid":"u5","timestamp":"2026-05-01T11:00:06.000Z"}"#,
        #"{"parentUuid":"u5","type":"assistant","message":{"id":"m3","role":"assistant","content":[{"type":"tool_use","id":"toolu_3","name":"Read","input":{"file_path":"/Users/example/.claude/skills/epsilon/SKILL.md"}}]},"uuid":"u6","timestamp":"2026-05-01T11:00:08.000Z"}"#,
        // The same block with sorted keys: name and input before type.
        #"{"message":{"content":[{"id":"toolu_4","input":{"skill":"gamma"},"name":"Skill","type":"tool_use"}],"id":"m4","role":"assistant"},"parentUuid":"u6","timestamp":"2026-05-01T11:00:10.000Z","type":"assistant","uuid":"u7"}"#,
        // A tool result quoting a tool_use is escaped and must not count.
        #"{"parentUuid":"u7","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_4","content":"{\"type\":\"tool_use\",\"name\":\"Fake\"}"}]},"uuid":"u8","timestamp":"2026-05-01T11:00:11.000Z"}"#,
    ]

    private func write(_ lines: [String], name: String) throws -> URL {
        let directory = try SessionStructureFixtures.temporaryDirectory("Activity")
        let url = directory.appendingPathComponent(name)
        try SessionStructureFixtures.write(lines, to: url)
        return url
    }

    func testCodexToolsSkillsAndPromptSizes() throws {
        let url = try write(Self.codexLines, name: "rollout.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tally = try XCTUnwrap(SessionActivityScanner.scan(fileURL: url, provider: .codex, calendar: utc))

        XCTAssertEqual(tally.days["2026-05-01"]?.tools, ["exec": 1, "js": 1])
        XCTAssertEqual(tally.days["2026-05-02"]?.tools, ["web_search": 1])
        XCTAssertEqual(tally.days["2026-05-01"]?.skills, ["alpha": 1, "beta": 1])
        XCTAssertEqual(tally.totalToolCalls, 3)
        XCTAssertEqual(tally.requests, 2)
        XCTAssertEqual(tally.firstPromptTokens, 12_000)
        XCTAssertEqual(tally.maxPromptTokens, 17_000)
        XCTAssertEqual(tally.contextWindow, 272_000)
        XCTAssertEqual(tally.activeDays, ["2026-05-01", "2026-05-02"])
        XCTAssertEqual(tally.activeSlots, 2)
        XCTAssertEqual(tally.skillLastUsed["beta"], ISO8601DateFormatter().date(from: "2026-05-01T10:00:03Z"))
    }

    func testClaudeSkillToolAndItsEchoCountOnce() throws {
        let url = try write(Self.claudeLines, name: "session.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tally = try XCTUnwrap(SessionActivityScanner.scan(fileURL: url, provider: .claude, calendar: utc))
        let day = try XCTUnwrap(tally.days["2026-05-01"])
        XCTAssertEqual(day.tools, ["Bash": 1, "Skill": 2, "Read": 1])
        // gamma: two Skill calls and one base-directory echo → two uses;
        // delta: an echo alone; epsilon: a SKILL.md read.
        XCTAssertEqual(day.skills, ["gamma": 2, "delta": 1, "epsilon": 1])
        XCTAssertNil(tally.firstPromptTokens, "Claude prompt sizes come from the ledger")
        XCTAssertEqual(tally.activeDays, ["2026-05-01"])
    }

    func testOtherProvidersAreNotScanned() throws {
        let url = try write(Self.codexLines, name: "other.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(SessionActivityScanner.scan(fileURL: url, provider: .grok, calendar: utc))
    }

    func testSkillNamesAreDirectoryNames() {
        XCTAssertEqual(SessionActivityScanner.validSkillName("pdf"), "pdf")
        XCTAssertEqual(SessionActivityScanner.validSkillName("plugin:skill-name"), "plugin:skill-name")
        XCTAssertNil(SessionActivityScanner.validSkillName(".hidden"))
        XCTAssertNil(SessionActivityScanner.validSkillName("two words"))
        XCTAssertNil(SessionActivityScanner.validSkillName(""))
    }

    func testStoreFillsOnceAndServesFromCacheUntilTheFileMoves() async throws {
        let url = try write(Self.codexLines, name: "rollout.jsonl")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionActivityStore(url: directory.appendingPathComponent("activity.sqlite3"), calendar: utc)
        let summary = SessionSummary(provider: .codex, sessionID: "a", sourcePath: url.path)

        let first = await store.fill([summary])
        XCTAssertEqual(first.scanned, 1)
        let second = await store.fill([summary])
        XCTAssertEqual(second.scanned, 0)
        XCTAssertEqual(second.upToDate, 1)

        // A second store on the same file reads the row back.
        let reopened = SessionActivityStore(url: directory.appendingPathComponent("activity.sqlite3"), calendar: utc)
        let tallies = await reopened.tallies(for: [summary])
        XCTAssertEqual(tallies[url.path]?.totalToolCalls, 3)

        // Appending moves the fingerprint: a miss until the next fill.
        try SessionStructureFixtures.write(Self.codexLines + Self.codexLines.suffix(1), to: url)
        let stale = await reopened.tallies(for: [summary])
        XCTAssertNil(stale[url.path])
        let refill = await reopened.fill([summary])
        XCTAssertEqual(refill.scanned, 1)
    }

    func testFillRespectsTheBudget() async throws {
        let directory = try SessionStructureFixtures.temporaryDirectory("ActivityBudget")
        defer { try? FileManager.default.removeItem(at: directory) }
        var summaries: [SessionSummary] = []
        for index in 0..<3 {
            let url = directory.appendingPathComponent("rollout-\(index).jsonl")
            try SessionStructureFixtures.write(Self.codexLines, to: url)
            summaries.append(SessionSummary(
                provider: .codex, sessionID: "s\(index)",
                lastActiveAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                sourcePath: url.path
            ))
        }
        let store = SessionActivityStore(url: nil, calendar: utc)
        let report = await store.fill(summaries, budget: .init(maxFiles: 2, maxBytes: 1 << 30, maxFileBytes: 1 << 30))
        XCTAssertEqual(report.scanned, 2)
        XCTAssertEqual(report.deferred, 1)
        let tallies = await store.tallies(for: summaries)
        // Most recent first: s2 and s1 were scanned, s0 waits.
        XCTAssertNil(tallies[summaries[0].sourcePath])
        XCTAssertNotNil(tallies[summaries[2].sourcePath])
    }
}
