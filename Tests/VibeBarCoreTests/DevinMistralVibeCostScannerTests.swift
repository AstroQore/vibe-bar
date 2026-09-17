import XCTest
import SQLite3
@testable import VibeBarCore

final class DevinMistralVibeCostScannerTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_789_700_000) // 2026-09-18

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarDevinVibeScanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        PricingResolver.testOverride = PricingHardcoded.fallback
    }

    override func tearDownWithError() throws {
        PricingResolver.testOverride = nil
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Devin

    private func makeDevinDatabase(_ rows: [(session: String, node: Int, message: [String: Any])]) throws {
        let url = CostUsageScanner.devinDatabaseURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
              model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL,
              title TEXT, main_chain_id INTEGER, hidden INTEGER NOT NULL DEFAULT 0, metadata TEXT);
            CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
              node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL, created_at INTEGER NOT NULL,
              metadata TEXT, UNIQUE(session_id, node_id));
            INSERT INTO sessions VALUES ('quiet-harbor', '/Users/example/proj', 'windsurf', 'swe-1.7', 'default', 1789600000, 1789600100, NULL, NULL, 0, NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for row in rows {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: row.message), as: UTF8.self)
                .replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO message_nodes (session_id, node_id, chat_message, created_at) VALUES ('\(row.session)', \(row.node), '\(json)', 1789600050);"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func assistant(request: String, input: Int, cacheRead: Int, output: Int, model: String) -> [String: Any] {
        [
            "role": "assistant",
            "content": "synthetic",
            "metadata": [
                "request_id": request,
                "generation_model": model,
                "created_at": "2026-09-17T07:18:13.615783Z",
                "metrics": ["input_tokens": input, "output_tokens": output, "cache_read_tokens": cacheRead]
            ]
        ]
    }

    /// Compaction copies nodes; one response must count once, and the cached
    /// prefix is part of `input_tokens`.
    func testDevinCountsEachResponseOnceAndPricesByModel() async throws {
        try makeDevinDatabase([
            ("quiet-harbor", 1, ["role": "user", "content": "hi"]),
            ("quiet-harbor", 2, assistant(request: "req-1", input: 17_545, cacheRead: 9_219, output: 99, model: "swe-1.7-high")),
            ("quiet-harbor", 3, assistant(request: "req-1", input: 17_545, cacheRead: 9_219, output: 99, model: "swe-1.7-high")),
            ("quiet-harbor", 4, assistant(request: "req-2", input: 100, cacheRead: 0, output: 10, model: "swe-2-high"))
        ])
        let sink = CollectingSink()
        let scanned = await CostUsageScanner.scan(tool: .devin, homeDirectory: home.path, now: now, eventSink: sink)
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.allTimeTokens, 17_545 + 99 + 100 + 10)

        let events = await sink.events
        XCTAssertEqual(events.count, 2)
        let first = try XCTUnwrap(events.first { $0.event.messageId == "req-1" })
        XCTAssertEqual(first.event.input, 17_545 - 9_219)
        XCTAssertEqual(first.event.cache, 9_219)
        XCTAssertEqual(first.event.harness, .devin)
        XCTAssertEqual(first.event.sessionId, "quiet-harbor")
        XCTAssertEqual(first.event.projectPath, "/Users/example/proj")
        let fresh: Double = Double(17_545 - 9_219) * 5e-7
        let cacheRead: Double = 9_219 * 2e-7
        let output: Double = 99 * 2.5e-6
        let expected = fresh + cacheRead + output
        XCTAssertEqual(first.costMicros, PricedUsageEvent.micros(fromUSD: expected))

        let unlisted = try XCTUnwrap(events.first { $0.event.messageId == "req-2" })
        XCTAssertNil(unlisted.costMicros, "a model no price list knows yet stays unpriced")
    }

    func testNoDevinDatabaseIsAnEmptySnapshot() async throws {
        let scanned = await CostUsageScanner.scan(tool: .devin, homeDirectory: home.path, now: now)
        XCTAssertEqual(try XCTUnwrap(scanned).jsonlFilesFound, 0)
    }

    // MARK: - Mistral Vibe

    private func writeMeta(
        _ directory: String, id: String, prompt: Int, cached: Int, completion: Int, listedModels: Bool = false
    ) throws {
        let dir = home.appendingPathComponent(".vibe/logs/session/\(directory)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "session_id": id,
            "start_time": "2026-09-17T07:24:50.688793+00:00",
            "end_time": "2026-09-17T07:25:19.497635+00:00",
            "environment": ["working_directory": "/Users/example/proj"],
            "config": [
                "active_model": "mistral-medium-3.5",
                "models": listedModels
                    ? [["alias": "mistral-medium-3.5", "name": "mistral-vibe-cli-latest", "provider": "mistral"]] as Any
                    : ["mistral-medium-3.5": ["name": "mistral-vibe-cli-latest", "provider": "mistral"]] as Any
            ],
            "stats": [
                "session_prompt_tokens": prompt,
                "session_cached_tokens": cached,
                "session_completion_tokens": completion
            ]
        ]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data().write(to: dir.appendingPathComponent("messages.jsonl"))
    }

    func testMistralVibeSessionsAndSubAgentsEachCountOnceAtAPIRates() async throws {
        try writeMeta("session_20260917_072450_90a50b6c", id: "90a50b6c-0000", prompt: 21_858, cached: 2_048, completion: 55)
        try writeMeta("session_20260917_072450_90a50b6c/agents/explore_20260917_072500_11112222", id: "11112222-0000",
                      prompt: 1_000, cached: 0, completion: 20)
        try writeMeta("session_20260917_080003_b0ec96a0", id: "b0ec96a0-0000", prompt: 0, cached: 0, completion: 0)
        let active = home.appendingPathComponent(".vibe/logs/session/active", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: active.appendingPathComponent("meta.json"))

        let sink = CollectingSink()
        let scanned = await CostUsageScanner.scan(tool: .mistralVibe, homeDirectory: home.path, now: now, eventSink: sink)
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.jsonlFilesFound, 3, "the active/ lease directory is not a session")
        let events = await sink.events.sorted { $0.event.input > $1.event.input }
        XCTAssertEqual(events.map(\.event.sessionId), ["90a50b6c-0000", "11112222-0000"])
        let main = try XCTUnwrap(events.first)
        XCTAssertEqual(main.event.model, "mistral-vibe-cli-latest")
        XCTAssertEqual(main.event.input, 21_858 - 2_048)
        XCTAssertEqual(main.event.cache, 2_048)
        XCTAssertEqual(main.event.harness, .mistralVibe)
        // Vibe's own session_cost for the same totals is 0.0304347.
        XCTAssertEqual(Double(main.costMicros ?? 0) / 1_000_000, 0.030435, accuracy: 1e-6)
    }

    /// A list of `{alias, name}` entries resolves to the served model too,
    /// never to the alias.
    func testAListedModelTableResolvesTheAlias() async throws {
        try writeMeta("session_20260917_090000_c0ffee00", id: "c0ffee00-0000", prompt: 1_000, cached: 0,
                      completion: 10, listedModels: true)
        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(tool: .mistralVibe, homeDirectory: home.path, now: now, eventSink: sink)
        let events = await sink.events
        XCTAssertEqual(events.map(\.event.model), ["mistral-vibe-cli-latest"])
    }
}

private actor CollectingSink: CostUsageEventSink {
    private(set) var events: [PricedUsageEvent] = []

    func consume(_ batch: UsageEventFileBatch) async {
        events.append(contentsOf: batch.events)
    }
}
