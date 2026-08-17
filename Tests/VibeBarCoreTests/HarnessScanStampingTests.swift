import XCTest
@testable import VibeBarCore

/// The usage axis is only as good as the stamp the scanner puts on each event.
/// Everything here is synthetic: `/Users/example/...`-shaped temp trees and
/// fake session ids.
final class HarnessScanStampingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_339_200)

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Codex vs ChatGPT Work

    func testCodexDesktopOriginatorStampsChatGPTWork() async throws {
        let events = try await scanCodexRollout(originator: "Codex Desktop")
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.event.harness == .chatgptWork })
    }

    func testCodexCLIOriginatorsStampCodex() async throws {
        for originator in ["codex_cli_rs", "codex-tui", "codex_exec"] {
            let events = try await scanCodexRollout(originator: originator)
            XCTAssertFalse(events.isEmpty, originator)
            XCTAssertTrue(
                events.allSatisfy { $0.event.harness == .codex },
                "\(originator) is the CLI, not the desktop app"
            )
        }
    }

    /// A rollout with no readable header must not be invented as desktop
    /// usage — the CLI is the overwhelming majority.
    func testMissingOriginatorFallsBackToCodex() async throws {
        let events = try await scanCodexRollout(originator: nil)
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.event.harness == .codex })
        XCTAssertEqual(CostUsageScanner.codexHarness(originator: nil), .codex)
        XCTAssertEqual(CostUsageScanner.codexHarness(originator: "something-new"), .codex)
    }

    // MARK: - Claude Code vs Claude Cowork

    func testCoworkTranscriptsAreScannedAndStampedSeparately() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarHarnessCowork-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-example-proj", isDirectory: true)
        try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)
        try claudeAssistantLine(
            sessionId: "session-code", messageId: "msg-code", requestId: "req-code"
        ).write(
            to: projects.appendingPathComponent("session-code.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let cowork = CostUsageScanner.claudeCoworkRoot(homeDirectory: home.path)
            .appendingPathComponent("space-1/0/local_00000000-0000-0000-0000-000000000001", isDirectory: true)
            .appendingPathComponent(".claude/projects/-Users-example-proj", isDirectory: true)
        try fileManager.createDirectory(at: cowork, withIntermediateDirectories: true)
        try claudeAssistantLine(
            sessionId: "session-cowork", messageId: "msg-cowork", requestId: "req-cowork"
        ).write(
            to: cowork.appendingPathComponent("session-cowork.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(
            tool: .claude, homeDirectory: home.path, now: now, eventSink: sink
        )
        let byHarness = Dictionary(
            grouping: await sink.events().map(\.event),
            by: { $0.harness }
        )
        XCTAssertEqual(byHarness[.claudeCode]?.count, 1)
        XCTAssertEqual(byHarness[.claudeCowork]?.count, 1)
        XCTAssertEqual(byHarness[.claudeCode]?.first?.sessionId, "session-code")
        XCTAssertEqual(byHarness[.claudeCowork]?.first?.sessionId, "session-cowork")
    }

    func testCoworkStampSurvivesSymlinkResolvedPaths() {
        let root = CostUsageScanner.claudeCoworkRoot(homeDirectory: "/Users/example")
        XCTAssertEqual(
            CostUsageScanner.claudeHarness(
                file: root.appendingPathComponent("s/0/local_x/.claude/projects/p/a.jsonl")
            ),
            .claudeCowork
        )
        // FileManager hands back `/private/var/...` for a `/var/...` root, so
        // the stamp must not depend on matching the root's own prefix.
        XCTAssertEqual(
            CostUsageScanner.claudeHarness(
                file: URL(fileURLWithPath:
                    "/private/var/folders/x/T/home/Library/Application Support/Claude/"
                    + "local-agent-mode-sessions/s/0/local_x/.claude/projects/p/a.jsonl")
            ),
            .claudeCowork
        )
        XCTAssertEqual(
            CostUsageScanner.claudeHarness(
                file: URL(fileURLWithPath: "/Users/example/.claude/projects/p/a.jsonl")
            ),
            .claudeCode
        )
        // Claude Code encodes a cwd into one dash-joined directory name, so a
        // project that merely mentions the folder name is not a Cowork run.
        XCTAssertEqual(
            CostUsageScanner.claudeHarness(
                file: URL(fileURLWithPath:
                    "/Users/example/.claude/projects/-Users-example-local-agent-mode-sessions/a.jsonl")
            ),
            .claudeCode
        )
    }

    // MARK: - Single-harness providers

    func testGrokEventsAreStampedGrokBuild() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarHarnessGrok-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let session = home
            .appendingPathComponent(".grok/sessions/-Users-example-proj/session-1", isDirectory: true)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        let millis = Int(now.timeIntervalSince1970 * 1000)
        try """
        {"params":{"_meta":{"totalTokens":1000,"agentTimestampMs":\(millis)}}}
        {"params":{"_meta":{"totalTokens":3000,"agentTimestampMs":\(millis + 1000)}}}
        """.write(
            to: session.appendingPathComponent("updates.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(
            tool: .grok, homeDirectory: home.path, now: now, eventSink: sink
        )
        let events = await sink.events()
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.event.harness == .grokBuild })
    }

    func testGeminiChatEventsAreStampedGeminiCLI() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarHarnessGemini-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let chats = home
            .appendingPathComponent(".gemini/tmp/projecthash/chats", isDirectory: true)
        try fileManager.createDirectory(at: chats, withIntermediateDirectories: true)
        let stamp = Self.isoFormatter.string(from: now.addingTimeInterval(-3_600))
        try """
        {"sessionId":"session-1"}
        {"type":"gemini","id":"m1","model":"gemini-2.5-pro","timestamp":"\(stamp)",\
        "tokens":{"input":1000,"output":200,"cached":0,"thoughts":0,"tool":0}}
        """.write(
            to: chats.appendingPathComponent("session-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(
            tool: .gemini, homeDirectory: home.path, now: now, eventSink: sink
        )
        let events = await sink.events()
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.event.harness == .geminiCLI })
    }

    // MARK: - Helpers

    private func scanCodexRollout(originator: String?) async throws -> [PricedUsageEvent] {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarHarnessCodex-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let sessions = home
            .appendingPathComponent(".codex/sessions/2026/08/17", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        var lines: [String] = []
        if let originator {
            lines.append("""
            {"timestamp":"\(Self.isoFormatter.string(from: now.addingTimeInterval(-7_200)))",\
            "type":"session_meta","payload":{"id":"00000000-0000-0000-0000-0000000000ab",\
            "cwd":"/Users/example/proj","originator":"\(originator)","cli_version":"0.0.0"}}
            """)
        }
        lines.append("""
        {"timestamp":"\(Self.isoFormatter.string(from: now.addingTimeInterval(-3_600)))",\
        "type":"event_msg","payload":{"type":"token_count","model":"gpt-5",\
        "info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":0,"output_tokens":800}}}}
        """)
        try lines.joined(separator: "\n").write(
            to: sessions.appendingPathComponent("rollout-00000000-0000-0000-0000-0000000000ab.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(
            tool: .codex, homeDirectory: home.path, now: now, eventSink: sink
        )
        return await sink.events()
    }

    private func claudeAssistantLine(
        sessionId: String,
        messageId: String,
        requestId: String
    ) -> String {
        let stamp = Self.isoFormatter.string(from: now.addingTimeInterval(-3_600))
        return """
        {"type":"assistant","timestamp":"\(stamp)","sessionId":"\(sessionId)",\
        "requestId":"\(requestId)","message":{"id":"\(messageId)","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1200,"output_tokens":300,\
        "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    private actor CollectingSink: CostUsageEventSink {
        private var collected: [PricedUsageEvent] = []

        func consume(_ batch: UsageEventFileBatch) async {
            collected.append(contentsOf: batch.events)
        }

        func events() -> [PricedUsageEvent] { collected }
    }
}
