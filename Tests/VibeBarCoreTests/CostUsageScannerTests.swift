import XCTest
@testable import VibeBarCore

final class CostUsageScannerTests: XCTestCase {
    func testCodexModelBreakdownsSplitSevenDayTopFromAllTimeRanking() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        let recentDate = now.addingTimeInterval(-86_400)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let lines = [
            codexTokenCountLine(timestamp: oldDate, model: "gpt-5", input: 8_000_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: recentDate, model: "gpt-5-mini", input: 8_200_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)

        XCTAssertEqual(snapshot?.modelBreakdowns.map(\.modelName), ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(snapshot?.last7DaysModelBreakdowns.map(\.modelName), ["gpt-5-mini"])
        XCTAssertGreaterThan(snapshot?.modelBreakdowns.first?.costUSD ?? 0, snapshot?.last7DaysModelBreakdowns.first?.costUSD ?? .infinity)
    }

    func testCodexScanHonorsRetentionWindow() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageRetentionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        let recentDate = now.addingTimeInterval(-2 * 86_400)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let lines = [
            codexTokenCountLine(timestamp: oldDate, model: "gpt-5", input: 8_000_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: recentDate, model: "gpt-5-mini", input: 8_200_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(
            tool: .codex,
            homeDirectory: home.path,
            now: now,
            retentionDays: 7
        )

        XCTAssertEqual(snapshot?.dailyHistory.count, 1)
        XCTAssertEqual(snapshot?.dailyHistory.first?.totalTokens, 200_000)
        XCTAssertEqual(snapshot?.allTimeTokens, 200_000)
        XCTAssertEqual(snapshot?.modelBreakdowns.map(\.modelName), ["gpt-5-mini"])
    }

    func testCodexScanBuildsTodayHourlyHistory() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageHourlyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 20)))
        let today = calendar.startOfDay(for: now)
        let morning = try XCTUnwrap(calendar.date(byAdding: .hour, value: 9, to: today))
        let afternoon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 15, to: today))
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let lines = [
            codexTokenCountLine(timestamp: morning, model: "gpt-5", input: 100_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: afternoon, model: "gpt-5", input: 300_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let scanned = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)
        let byHour = Dictionary(uniqueKeysWithValues: snapshot.todayHourlyHistory.map {
            (calendar.component(.hour, from: $0.date), $0.totalTokens)
        })

        XCTAssertEqual(snapshot.todayHourlyHistory.count, 21)
        XCTAssertEqual(byHour[9], 100_000)
        XCTAssertEqual(byHour[15], 200_000)
        XCTAssertEqual(snapshot.todayHourlyHistory.reduce(0) { $0 + $1.totalTokens }, 300_000)
    }

    func testCodexScanUsesLastTokenUsageWhenTotalsAreMissing() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageLastTokenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let timestamp = Self.isoFormatter.string(from: now)
        let lines = [
            #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"info":{"model":"gpt-5.4"}}}"#,
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50}}}}"#
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)

        XCTAssertEqual(snapshot?.allTimeTokens, 1_050)
        XCTAssertEqual(snapshot?.modelBreakdowns.first?.modelName, "gpt-5.4")
    }

    func testClaudeScanKeepsLastStreamingChunkAcrossCache() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarClaudeStreamingCostTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("project-a", isDirectory: true)
        try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let logURL = projects.appendingPathComponent("session.jsonl")
        let lines = [
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-stream",
                messageId: "msg-stream",
                requestId: "req-stream",
                model: "claude-haiku-4-5",
                input: 100,
                cacheRead: 0,
                cacheCreation: 0,
                output: 10
            ),
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-stream",
                messageId: "msg-stream",
                requestId: "req-stream",
                model: "claude-haiku-4-5",
                input: 150,
                cacheRead: 20,
                cacheCreation: 30,
                output: 15
            )
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let first = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)
        let second = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)

        XCTAssertEqual(first?.allTimeTokens, 215)
        XCTAssertEqual(second?.allTimeTokens, 215)
        XCTAssertEqual(first?.jsonlFilesFound, 1)
    }

    func testClaudeScanDeduplicatesCrossFileSubagentRows() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarClaudeCrossFileCostTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessionRoot = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("project-a", isDirectory: true)
            .appendingPathComponent("session-cross-file", isDirectory: true)
        let subagents = sessionRoot.appendingPathComponent("subagents", isDirectory: true)
        try fileManager.createDirectory(at: subagents, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let parentURL = sessionRoot.appendingPathComponent("parent.jsonl")
        let subagentURL = subagents.appendingPathComponent("agent.jsonl")
        try claudeAssistantLine(
            timestamp: now,
            sessionId: "session-cross-file",
            messageId: "msg-overlap",
            requestId: "req-overlap",
            model: "claude-haiku-4-5",
            input: 100,
            cacheRead: 0,
            cacheCreation: 0,
            output: 11
        ).write(to: parentURL, atomically: true, encoding: .utf8)
        let subagentLines = [
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-cross-file",
                messageId: "msg-overlap",
                requestId: "req-overlap",
                model: "claude-haiku-4-5",
                input: 900,
                cacheRead: 0,
                cacheCreation: 0,
                output: 99,
                isSidechain: true
            ),
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-cross-file",
                messageId: "msg-unique",
                requestId: "req-unique",
                model: "claude-haiku-4-5",
                input: 5,
                cacheRead: 0,
                cacheCreation: 0,
                output: 2,
                isSidechain: true
            )
        ]
        try subagentLines.joined(separator: "\n").write(to: subagentURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)

        XCTAssertEqual(snapshot?.allTimeTokens, 118)
        XCTAssertEqual(snapshot?.jsonlFilesFound, 2)
    }

    private func codexTokenCountLine(
        timestamp: Date,
        model: String,
        input: Int,
        cached: Int,
        output: Int
    ) -> String {
        let timestampString = Self.isoFormatter.string(from: timestamp)
        return """
        {"timestamp":"\(timestampString)","type":"event_msg","payload":{"type":"token_count","model":"\(model)","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}}}}
        """
    }

    private func claudeAssistantLine(
        timestamp: Date,
        sessionId: String,
        messageId: String,
        requestId: String,
        model: String,
        input: Int,
        cacheRead: Int,
        cacheCreation: Int,
        output: Int,
        isSidechain: Bool = false
    ) -> String {
        let timestampString = Self.isoFormatter.string(from: timestamp)
        return """
        {"timestamp":"\(timestampString)","type":"assistant","sessionId":"\(sessionId)","requestId":"\(requestId)","isSidechain":\(isSidechain),"message":{"id":"\(messageId)","model":"\(model)","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),"output_tokens":\(output)}}}
        """
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
