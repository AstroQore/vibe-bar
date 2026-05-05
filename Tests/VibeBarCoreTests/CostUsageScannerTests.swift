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

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
