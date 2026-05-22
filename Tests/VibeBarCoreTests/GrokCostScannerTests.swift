import XCTest
@testable import VibeBarCore

/// Grok stores each session as `~/.grok/sessions/<urlEncodedCwd>/
/// <sessionUUID>/updates.jsonl`. Modern records carry a cumulative
/// `params._meta.totalTokens` plus `params._meta.agentTimestampMs` — per-turn token
/// delta is the only "what did this turn cost" signal Grok hands us,
/// so the scanner deltas the running total and 70 / 30 splits the
/// number across input vs output for cost.
final class GrokCostScannerTests: XCTestCase {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarGrokScannerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeUpdatesFile(
        home: URL,
        cwdLabel: String,
        sessionId: String,
        records: [(date: Date, total: Int)],
        nestedMeta: Bool = false
    ) throws -> URL {
        let dir = home
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(cwdLabel, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("updates.jsonl")
        let lines = records.map { record -> String in
            let ms = Int64(record.date.timeIntervalSince1970 * 1000)
            if nestedMeta {
                return """
                {"method":"session/update","params":{"sessionId":"\(sessionId)","_meta":{"totalTokens":\(record.total),"agentTimestampMs":\(ms),"updateType":"AvailableCommandsUpdate"}}}
                """
            }
            return """
            {"_meta":{"totalTokens":\(record.total),"agentTimestampMs":\(ms),"updateType":"AvailableCommandsUpdate"},"payload":{}}
            """
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return dir
    }

    private func writeEventsFile(
        sessionDirectory: URL,
        records: [(date: Date, model: String)]
    ) throws {
        let file = sessionDirectory.appendingPathComponent("events.jsonl")
        let lines = records.map { record -> String in
            """
            {"ts":"\(Self.isoFormatter.string(from: record.date))","type":"turn_started","model_id":"\(record.model)"}
            """
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func testEmptyHomeProducesEmptySnapshot() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let snapshot = await CostUsageScanner.scan(
            tool: .grok,
            homeDirectory: home.path,
            now: Date()
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 0)
        XCTAssertEqual(snap.allTimeTokens, 0)
        XCTAssertEqual(snap.allTimeCostUSD, 0)
    }

    func testSingleSessionDeltaSplitsInputOutputAndCostsAtGrokBuildRate() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        let t0 = now.addingTimeInterval(-200)
        let t1 = now.addingTimeInterval(-100)
        let t2 = now
        try writeUpdatesFile(
            home: home,
            cwdLabel: "%2FUsers%2Fexample%2Fproject",
            sessionId: "019e4e90-f8b7-7473-9f42-4eba2e254caf",
            records: [
                (t0, 1_000),
                (t1, 6_000),
                (t2, 11_000)
            ]
        )

        let snapshot = await CostUsageScanner.scan(
            tool: .grok,
            homeDirectory: home.path,
            now: now
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 1)
        XCTAssertEqual(snap.allTimeTokens, 11_000,
                       "First-row floor (1000) + two 5000 deltas should equal the latest cumulative")

        // 70 / 30 split → per-Mtok blended cost for grok-build:
        //   0.7 * $1 + 0.3 * $2 = $1.30 per million tokens
        // 11_000 tokens * $1.30/Mtok = $0.01430
        XCTAssertEqual(snap.allTimeCostUSD, 0.0143, accuracy: 0.0001)
        XCTAssertEqual(snap.modelBreakdowns.map(\.modelName), ["grok-build"])
    }

    func testNestedSessionUpdateMetaAndSiblingModelAreParsed() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        let t0 = now.addingTimeInterval(-240)
        let t1 = now.addingTimeInterval(-120)
        let sessionDirectory = try writeUpdatesFile(
            home: home,
            cwdLabel: "%2FUsers%2Fexample%2Fproject",
            sessionId: "session-model",
            records: [
                (t0, 2_000),
                (t1, 7_000)
            ],
            nestedMeta: true
        )
        try writeEventsFile(
            sessionDirectory: sessionDirectory,
            records: [(t0.addingTimeInterval(-1), "grok-4-fast")]
        )

        let snapshot = await CostUsageScanner.scan(
            tool: .grok,
            homeDirectory: home.path,
            now: now
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 1)
        XCTAssertEqual(snap.allTimeTokens, 7_000)
        XCTAssertEqual(snap.modelBreakdowns.map(\.modelName), ["grok-4-fast"])
        // 7000 tokens split 70 / 30 at grok-4-fast's $0.20 / $0.50 per Mtok.
        XCTAssertEqual(snap.allTimeCostUSD, 0.00203, accuracy: 0.00001)
    }

    func testMultipleSessionsAggregateAcrossWorkingDirectories() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        try writeUpdatesFile(
            home: home,
            cwdLabel: "%2FUsers%2Fexample%2Fa",
            sessionId: "session-a",
            records: [
                (now.addingTimeInterval(-3 * 86_400), 2_000),
                (now.addingTimeInterval(-3 * 86_400 + 60), 4_500)
            ]
        )
        try writeUpdatesFile(
            home: home,
            cwdLabel: "%2FUsers%2Fexample%2Fb",
            sessionId: "session-b",
            records: [
                (now.addingTimeInterval(-1 * 86_400), 1_000),
                (now.addingTimeInterval(-1 * 86_400 + 60), 3_000)
            ]
        )

        let snapshot = await CostUsageScanner.scan(
            tool: .grok,
            homeDirectory: home.path,
            now: now
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 2)
        // session-a: 2000 + (4500 - 2000) = 4500
        // session-b: 1000 + (3000 - 1000) = 3000
        XCTAssertEqual(snap.allTimeTokens, 7_500)
        XCTAssertGreaterThan(snap.dailyHistory.count, 1)
    }

    func testCacheReusesEventsWhenFingerprintMatches() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        try writeUpdatesFile(
            home: home,
            cwdLabel: "%2FUsers%2Fexample%2Fc",
            sessionId: "session-c",
            records: [
                (now.addingTimeInterval(-300), 1_000),
                (now.addingTimeInterval(-200), 5_000)
            ]
        )

        let firstScan = await CostUsageScanner.scan(
            tool: .grok,
            homeDirectory: home.path,
            now: now
        )
        let firstSnap = try XCTUnwrap(firstScan)
        let secondScan = await CostUsageScanner.scan(
            tool: .grok,
            homeDirectory: home.path,
            now: now
        )
        let secondSnap = try XCTUnwrap(secondScan)
        XCTAssertEqual(firstSnap.allTimeTokens, secondSnap.allTimeTokens)
        XCTAssertEqual(firstSnap.allTimeCostUSD, secondSnap.allTimeCostUSD, accuracy: 1e-9)
    }

    func testGrokPricingAtPublishedRates() throws {
        // grok-build is published at $1 / $2 per million tokens.
        let oneMillionInput = try XCTUnwrap(CostUsagePricing.grokCostUSD(
            model: "grok-build",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        ))
        XCTAssertEqual(oneMillionInput, 1.0, accuracy: 1e-9)

        let oneMillionOutput = try XCTUnwrap(CostUsagePricing.grokCostUSD(
            model: "grok-build",
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 1_000_000
        ))
        XCTAssertEqual(oneMillionOutput, 2.0, accuracy: 1e-9)

        // grok-4 fast variant: $0.20 / $0.50 per Mtok.
        let fastInput = try XCTUnwrap(CostUsagePricing.grokCostUSD(
            model: "grok-4-fast",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        ))
        XCTAssertEqual(fastInput, 0.2, accuracy: 1e-9)
    }
}
