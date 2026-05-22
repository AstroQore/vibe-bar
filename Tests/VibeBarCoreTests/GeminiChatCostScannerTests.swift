import XCTest
@testable import VibeBarCore

/// AQ's installation stores Gemini CLI usage in chat-history JSONL
/// files under `~/.gemini/tmp/<project>/chats/session-*.jsonl`, NOT
/// the OpenTelemetry log the scanner originally only knew how to
/// read. This suite locks in the chat-history branch: per-message
/// `tokens.{input,output,cached,thoughts,tool}` records aggregate
/// into the same CostSnapshot shape Codex / Claude produce.
final class GeminiChatCostScannerTests: XCTestCase {
    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarGeminiChatScannerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeChatSession(
        home: URL,
        project: String,
        sessionFileName: String,
        startTime: String,
        sessionId: String,
        records: [String]
    ) throws {
        let chats = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let header = """
        {"sessionId":"\(sessionId)","projectHash":"0000","startTime":"\(startTime)","lastUpdated":"\(startTime)","kind":"main"}
        """
        let lines = [header] + records
        try lines.joined(separator: "\n").write(
            to: chats.appendingPathComponent(sessionFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    func testChatHistoryGeminiTurnsAggregateIntoSnapshot() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        try writeChatSession(
            home: home,
            project: "example-project",
            sessionFileName: "session-2026-05-22T10-00-aaaaaaaa.jsonl",
            startTime: "2026-05-22T10:00:00.000Z",
            sessionId: "aaaaaaaa-1111-2222-3333-444444444444",
            records: [
                #"{"id":"u1","timestamp":"2026-05-22T10:00:00.000Z","type":"user","content":[{"text":"hi"}]}"#,
                #"{"id":"g1","timestamp":"2026-05-22T10:00:05.000Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":1000,"output":100,"cached":0,"thoughts":50,"tool":0,"total":1150}}"#,
                #"{"id":"u2","timestamp":"2026-05-22T10:00:10.000Z","type":"user","content":[{"text":"and again"}]}"#,
                #"{"id":"g2","timestamp":"2026-05-22T10:00:15.000Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":2000,"output":200,"cached":500,"thoughts":25,"tool":10,"total":2735}}"#
            ]
        )

        let snapshot = await CostUsageScanner.scan(
            tool: .gemini,
            homeDirectory: home.path,
            now: now
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 1)
        // Sum:
        //   g1: input 1000 (cached 0 → non-cached 1000), output 100+50 = 150
        //   g2: input 2000 (cached 500 → non-cached 1500), output 200+25+10 = 235, cache 500
        //   Aggregator sums input + output + cache = 1000 + 150 + 1500 + 235 + 500 = 3385
        XCTAssertEqual(snap.allTimeTokens, 3_385)
        XCTAssertEqual(snap.modelBreakdowns.map(\.modelName), ["gemini-2.5-pro"])
        XCTAssertGreaterThan(snap.allTimeCostUSD, 0)
    }

    func testChatHistorySkipsNonGeminiMessages() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        try writeChatSession(
            home: home,
            project: "example",
            sessionFileName: "session-2026-05-22T11-00-bbbbbbbb.jsonl",
            startTime: "2026-05-22T11:00:00.000Z",
            sessionId: "bbbbbbbb",
            records: [
                #"{"id":"u","timestamp":"2026-05-22T11:00:00.000Z","type":"user","content":[{"text":"hi"}]}"#,
                #"{"id":"t","timestamp":"2026-05-22T11:00:02.000Z","type":"tool","content":[{"text":"ran"}]}"#,
                #"{"id":"g","timestamp":"2026-05-22T11:00:05.000Z","type":"gemini","model":"gemini-2.5-flash","tokens":{"input":500,"output":50,"cached":0,"thoughts":0,"tool":0,"total":550}}"#
            ]
        )

        let snapshot = await CostUsageScanner.scan(
            tool: .gemini,
            homeDirectory: home.path,
            now: now
        )
        let snap = try XCTUnwrap(snapshot)
        // Only the gemini record contributes: input 500 + output 50 = 550 tokens.
        XCTAssertEqual(snap.allTimeTokens, 550)
        XCTAssertEqual(snap.modelBreakdowns.map(\.modelName), ["gemini-2.5-flash"])
    }
}
