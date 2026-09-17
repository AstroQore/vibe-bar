import XCTest
@testable import VibeBarCore

/// Muse Code writes one append-only record log per conversation at
/// `~/.local/share/muse/sessions/YYYY/MM/DD/<id>/session.jsonl`, and every
/// model call adds a `model_completed` run event carrying its usage.
final class MuseCostScannerTests: XCTestCase {
    private var home: URL!
    private let sessionID = "01a0ac0d-5355-7c41-bc77-3b55f0e77ea1"
    private let now = Date(timeIntervalSince1970: 1_767_229_200) // 2026-01-01T01:00:00Z

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarMuseScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Price against the shipped table, never this Mac's pricing cache.
        PricingResolver.testOverride = PricingHardcoded.fallback
    }

    override func tearDownWithError() throws {
        PricingResolver.testOverride = nil
        try? FileManager.default.removeItem(at: home)
    }

    private func micros(_ secondsBeforeNow: TimeInterval) -> Int64 {
        Int64((now.timeIntervalSince1970 - secondsBeforeNow) * 1_000_000)
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func metadata(workspace: String?) -> [String: Any] {
        var record: [String: Any] = ["provider_id": "meta"]
        if let workspace { record["workspace_root"] = workspace }
        return [
            "id": UUID().uuidString, "recorded_at": micros(3_000),
            "stream": ["kind": "session", "id": sessionID],
            "payload_type": "runtime.session.metadata",
            "payload": ["kind": "metadata", "record": record]
        ]
    }

    private func completed(
        input: Int, cached: Int, output: Int, reasoning: Int = 0,
        model: String = "muse-spark-1.3", secondsAgo: TimeInterval
    ) -> [String: Any] {
        [
            "id": UUID().uuidString, "recorded_at": micros(secondsAgo),
            "stream": ["kind": "session", "id": sessionID],
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run", "run_id": "run-1",
                "event": [
                    "kind": "model_completed",
                    "usage": [
                        "input_tokens": input, "output_tokens": output, "cached_tokens": cached,
                        "cache_write_tokens": 0, "cache_read_tokens": cached, "reasoning_tokens": reasoning
                    ],
                    "duration_ms": 1_200,
                    "model": model
                ]
            ]
        ]
    }

    /// The same numbers restated for goal accounting. Counting it too would
    /// double every call.
    private func attribution(input: Int, output: Int, secondsAgo: TimeInterval) -> [String: Any] {
        [
            "id": UUID().uuidString, "recorded_at": micros(secondsAgo),
            "stream": ["kind": "session", "id": sessionID],
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run", "run_id": "run-1",
                "event": [
                    "kind": "goal_usage_attribution",
                    "record": ["quantity": ["input_tokens": input, "output_tokens": output, "cached_tokens": 0]]
                ]
            ]
        ]
    }

    @discardableResult
    private func writeLog(_ lines: [[String: Any]], under directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.jsonl")
        try (try lines.map(line).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var sessionDirectory: URL {
        home.appendingPathComponent(".local/share/muse/sessions/2026/01/01/\(sessionID)", isDirectory: true)
    }

    func testModelCompletedEventsAreTheUsageAndAttributionIsNotCountedTwice() async throws {
        try writeLog([
            metadata(workspace: "/Users/example/proj"),
            completed(input: 24_519, cached: 0, output: 29, reasoning: 12, secondsAgo: 1_800),
            attribution(input: 24_519, output: 29, secondsAgo: 1_799)
        ], under: sessionDirectory)
        // A reminder child's log sits inside the parent and spends the same
        // subscription, so it counts — with no workspace of its own.
        try writeLog([
            metadata(workspace: nil),
            completed(input: 3_173, cached: 2_801, output: 227, reasoning: 127, secondsAgo: 1_700)
        ], under: sessionDirectory.appendingPathComponent("subagent/a8234fe2-23ee-4cc5-8e81-8908fe89b18d", isDirectory: true))

        let sink = MuseCollectingSink()
        let scanned = await CostUsageScanner.scan(tool: .muse, homeDirectory: home.path, now: now, eventSink: sink)
        let snapshot = try XCTUnwrap(scanned)

        XCTAssertEqual(snapshot.jsonlFilesFound, 2)
        let events = await sink.events.sorted { $0.date < $1.date }
        XCTAssertEqual(events.count, 2)

        let main = events[0]
        XCTAssertEqual(main.input, 24_519)
        XCTAssertEqual(main.cache, 0)
        XCTAssertEqual(main.output, 29, "output already includes reasoning")
        XCTAssertEqual(main.model, "muse-spark-1.3")
        XCTAssertEqual(main.harness, .museCode)
        XCTAssertEqual(main.sessionId, sessionID)

        let child = events[1]
        XCTAssertEqual(child.input, 3_173 - 2_801, "input_tokens includes the cached prefix")
        XCTAssertEqual(child.cache, 2_801)
        XCTAssertEqual(child.sessionId, sessionID, "a child's usage belongs to its parent conversation")
        XCTAssertEqual(child.projectPath, main.projectPath)
        XCTAssertNotNil(main.projectPath)

        // Priced at the API's rates for the same model: fresh input, cached
        // input and output each at their own rate.
        let expectedMain = 24_519 * 1.25e-6 + 29 * 4.25e-6
        let expectedChild = 372 * 1.25e-6 + 2_801 * 1.5e-7 + 227 * 4.25e-6
        let priced = await sink.costs
        XCTAssertEqual(priced, [expectedMain, expectedChild].map(PricedUsageEvent.micros(fromUSD:)))
        XCTAssertEqual(snapshot.allTimeCostUSD, expectedMain + expectedChild, accuracy: 1e-9)
    }

    /// Meta Model API rates per 1M tokens: $1.25 input, $0.15 cached input,
    /// $4.25 output; the contributor variants a tenth of that and less. The
    /// CLI logs the bare id, LiteLLM the `meta/`-prefixed one.
    func testMuseSparkRatesMatchTheModelAPI() throws {
        let standard = try XCTUnwrap(CostUsagePricing.museCostUSD(
            model: "muse-spark-1.3", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 1_000_000
        ))
        XCTAssertEqual(standard, 1.25 + 4.25, accuracy: 1e-9)
        let cached = try XCTUnwrap(CostUsagePricing.museCostUSD(
            model: "meta/Muse-Spark-1.3", inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 0
        ))
        XCTAssertEqual(cached, 0.15, accuracy: 1e-9)
        let contributor = try XCTUnwrap(CostUsagePricing.museCostUSD(
            model: "muse-spark-1.3-contributor", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 1_000_000
        ))
        XCTAssertEqual(contributor, 0.10 + 0.20, accuracy: 1e-9)
        XCTAssertNil(
            CostUsagePricing.museCostUSD(model: "muse-unknown", inputTokens: 1, cachedInputTokens: 0, outputTokens: 1),
            "an unknown model stays unpriced rather than borrowing a sibling's rate"
        )
        XCTAssertTrue(CostUsagePricing.canRepriceAggregate(tool: .muse, model: "muse-spark-1.3-contributor"))
    }

    func testRecordsInsideARetainedFrameAreRead() async throws {
        let child = try line(completed(input: 100, cached: 0, output: 10, secondsAgo: 600))
        let frame: [String: Any] = [
            "retained_frame": "session_permission_transaction",
            "children": [["child_index": 0, "record_json": child]]
        ]
        try writeLog([metadata(workspace: "/Users/example/proj"), frame], under: sessionDirectory)

        let sink = MuseCollectingSink()
        _ = await CostUsageScanner.scan(tool: .muse, homeDirectory: home.path, now: now, eventSink: sink)
        let events = await sink.events
        XCTAssertEqual(events.map(\.input), [100])
    }

    func testHiddenViewDirectoriesAreNotSessions() throws {
        try writeLog([metadata(workspace: nil)], under: sessionDirectory)
        try writeLog(
            [metadata(workspace: nil)],
            under: home.appendingPathComponent(".local/share/muse/sessions/.msp-view-v1/\(sessionID)", isDirectory: true)
        )
        let logs = CostUsageScanner.collectMuseSessionLogs(
            under: home.appendingPathComponent(".local/share/muse/sessions", isDirectory: true)
        )
        XCTAssertEqual(logs.map { $0.resolvingSymlinksInPath().path },
                       [sessionDirectory.appendingPathComponent("session.jsonl").resolvingSymlinksInPath().path])
    }

    func testNoSessionsIsAnEmptySnapshot() async throws {
        let scanned = await CostUsageScanner.scan(tool: .muse, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.jsonlFilesFound, 0)
        XCTAssertEqual(snapshot.allTimeTokens, 0)
    }
}

private actor MuseCollectingSink: CostUsageEventSink {
    private(set) var events: [CostUsageScanCache.ParsedEvent] = []
    private(set) var costs: [Int64?] = []

    func consume(_ batch: UsageEventFileBatch) async {
        events.append(contentsOf: batch.events.map(\.event))
        costs.append(contentsOf: batch.events.map(\.costMicros))
    }
}
