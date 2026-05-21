import XCTest
@testable import VibeBarCore

/// Locks the Gemini CLI telemetry-log → `CostSnapshot` pipeline.
/// We can't depend on the user actually having `~/.gemini/telemetry.log`
/// populated, so each test plants a synthetic JSONL fixture in a fresh
/// temporary HOME and points `CostUsageScanner.scan(tool: .gemini)`
/// at it.
final class GeminiCostScannerTests: XCTestCase {
    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-gemini-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"),
                                                 withIntermediateDirectories: true)
        return home
    }

    private func writeLog(_ home: URL, _ lines: [String]) throws {
        let file = home.appendingPathComponent(".gemini/telemetry.log")
        let body = lines.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: file)
    }

    private func cleanup(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
    }

    func testMissingLogReturnsEmptySnapshot() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let snapshot = await CostUsageScanner.scan(tool: .gemini, homeDirectory: home.path, now: Date())
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.jsonlFilesFound ?? -1, 0)
        XCTAssertEqual(snapshot?.allTimeTokens, 0)
        XCTAssertEqual(snapshot?.allTimeCostUSD, 0)
    }

    func testFlatAttributesShape() async throws {
        // Some OpenTelemetry SDK writers flatten the log line so token
        // counts live at the top level rather than under `attributes`.
        let home = try makeTempHome()
        defer { cleanup(home) }

        let line = """
        {"name":"gemini_cli.api_response","timestamp":"2026-05-22T01:00:00Z","model":"gemini-2.5-flash","input_token_count":1000,"output_token_count":2000,"cached_content_token_count":0}
        """
        try writeLog(home, [line])

        let snapshot = await CostUsageScanner.scan(tool: .gemini, homeDirectory: home.path, now: Date(timeIntervalSince1970: 1_779_000_000))
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.allTimeTokens, 3000)
        // gemini-2.5-flash: input $0.30/M, output $2.50/M
        XCTAssertEqual(snap.allTimeCostUSD, 1000 * 3e-7 + 2000 * 2.5e-6, accuracy: 1e-9)
        XCTAssertEqual(snap.jsonlFilesFound, 1)
    }

    func testNestedAttributesShape() async throws {
        // OpenTelemetry SDKs more commonly nest attributes.
        let home = try makeTempHome()
        defer { cleanup(home) }

        let line = """
        {"name":"gemini_cli.api_response","timestamp":"2026-05-22T01:00:00Z","attributes":{"model":"gemini-2.5-pro","input_token_count":100000,"output_token_count":5000,"cached_content_token_count":0,"prompt_id":"p-1","session.id":"s-1"}}
        """
        try writeLog(home, [line])

        let snapshot = await CostUsageScanner.scan(tool: .gemini, homeDirectory: home.path, now: Date(timeIntervalSince1970: 1_779_000_000))
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.allTimeTokens, 105_000)
        // gemini-2.5-pro: input $1.25/M, output $1e-5/token below threshold
        let expected = 100_000 * 1.25e-6 + 5_000 * 1e-5
        XCTAssertEqual(snap.allTimeCostUSD, expected, accuracy: 1e-6)
    }

    func testNonMatchingEventsAreSkipped() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let lines = [
            "{\"name\":\"gemini_cli.user_prompt\",\"prompt\":\"hi\"}",
            "{\"name\":\"gemini_cli.api_request\",\"model\":\"gemini-2.5-flash\"}",
            "{\"name\":\"gemini_cli.api_response\",\"timestamp\":\"2026-05-22T01:00:00Z\",\"model\":\"gemini-2.5-flash\",\"input_token_count\":500,\"output_token_count\":500}"
        ]
        try writeLog(home, lines)

        let snapshot = await CostUsageScanner.scan(tool: .gemini, homeDirectory: home.path, now: Date(timeIntervalSince1970: 1_779_000_000))
        XCTAssertEqual(snapshot?.allTimeTokens, 1000)
    }

    func testOTLPArrayAttributeShape() async throws {
        // OTLP JSON shape: attributes is an array of {key, value:{stringValue/intValue/...}}.
        let home = try makeTempHome()
        defer { cleanup(home) }

        let line = """
        {"name":"gemini_cli.api_response","timestamp":"2026-05-22T01:00:00Z","attributes":[{"key":"model","value":{"stringValue":"gemini-2.5-flash"}},{"key":"input_token_count","value":{"intValue":1000}},{"key":"output_token_count","value":{"intValue":2000}}]}
        """
        try writeLog(home, [line])

        let snapshot = await CostUsageScanner.scan(tool: .gemini, homeDirectory: home.path, now: Date(timeIntervalSince1970: 1_779_000_000))
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.allTimeTokens, 3000)
    }

    func testNonGeminiToolsStillBehave() async throws {
        // Defensive — Antigravity remains cost-blind even though it's
        // partial-primary; misc providers stay nil.
        let snapshot = await CostUsageScanner.scan(tool: .antigravity, homeDirectory: NSTemporaryDirectory())
        XCTAssertNil(snapshot)
    }
}
