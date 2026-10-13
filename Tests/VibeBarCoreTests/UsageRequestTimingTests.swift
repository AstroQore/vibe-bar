import XCTest
import SQLite3
@testable import VibeBarCore

/// Request timing end to end: the byte-level probes, both scanners' readings
/// of synthetic logs, the scan cache's compact encoding, the ledger's v5
/// columns and backfill, the speed medians, and the MCP wire shape.
/// Everything is synthetic: `/Users/example/...` paths, fake ids.
final class UsageRequestTimingTests: XCTestCase {
    /// 2025-11-05T10:00:00Z.
    private let base = Date(timeIntervalSince1970: 1_762_336_800)
    private var now: Date { base.addingTimeInterval(3_600) }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func stamp(_ seconds: Double) -> String {
        Self.iso.string(from: base.addingTimeInterval(seconds))
    }

    private func makeHome(_ label: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBar\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private actor CollectingSink: CostUsageEventSink {
        private var collected: [PricedUsageEvent] = []
        func consume(_ batch: UsageEventFileBatch) async { collected.append(contentsOf: batch.events) }
        func events() -> [CostUsageScanCache.ParsedEvent] { collected.map(\.event) }
    }

    // MARK: - Byte probes

    func testFastISO8601MatchesTheFoundationParser() throws {
        let samples = [
            "2026-10-13T09:10:36.547Z",
            "2026-10-13T09:10:36Z",
            "2026-10-13T09:10:36.5Z",
            "2026-10-13T09:10:36.123456Z",
            "2026-10-13T17:10:36.547+08:00",
            "2026-10-13T01:10:36.547-0800",
            "2024-02-29T23:59:59.999Z",
            "1999-12-31T00:00:00Z"
        ]
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for sample in samples {
            let expected = try XCTUnwrap(withFraction.date(from: sample) ?? plain.date(from: sample), sample)
            let parsed = try XCTUnwrap(Array(sample.utf8).withUnsafeBytes { ISO8601Bytes.parse($0) }, sample)
            XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, sample)
        }
        XCTAssertNil(Array("not a date".utf8).withUnsafeBytes { ISO8601Bytes.parse($0) })
        XCTAssertNil(Array("2026-13-01T00:00:00Z".utf8).withUnsafeBytes { ISO8601Bytes.parse($0) })
    }

    func testFirstTimestampIsTheTopLevelOneInBothLogShapes() throws {
        // Claude Code: the prompt text before the key is a JSON string, so a
        // quoted "timestamp" inside it is escaped and cannot match; the
        // nested `toolUseResult` comes after the real key.
        let claude = #"{"parentUuid":"p","type":"user","message":{"role":"user","content":"see \"timestamp\":\"2020-01-01T00:00:00Z\""},"uuid":"u","timestamp":"2026-10-13T09:10:36.547Z","toolUseResult":{"timestamp":"2027-01-01T00:00:00Z"}}"#
        let date = Data(claude.utf8).withUnsafeBytes { JSONLLineProbe.firstTimestamp(in: $0) }
        XCTAssertEqual(date, Self.iso.date(from: "2026-10-13T09:10:36.547Z"))
    }

    func testCodexLineClassification() {
        func kind(_ line: String) -> CodexRequestTimingTracker.LineKind {
            CodexRequestTimingTracker.classify(Data(line.utf8)).kind
        }
        let t = #""timestamp":"2026-10-13T09:05:43.544Z""#
        XCTAssertEqual(kind(#"{\#(t),"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#), .requestStart)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"message","id":"m","role":"user","content":[]}}"#), .requestStart)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"x"}}"#), .requestStart)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c","output":"x"}}"#), .requestStart)
        XCTAssertEqual(kind(#"{\#(t),"ordinal":4,"type":"response_item","payload":{"type":"reasoning","id":"r","summary":[]}}"#), .responseItem)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"message","id":"m","role":"assistant","content":[]}}"#), .responseItem)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"function_call","name":"shell"}}"#), .responseItem)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"message","id":"m","role":"developer","content":[]}}"#), .other)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"compaction","id":"c"}}"#), .other)
        XCTAssertEqual(kind(#"{\#(t),"type":"event_msg","payload":{"type":"item_completed","item":{"type":"reasoning"}}}"#), .other)
        XCTAssertEqual(kind(#"{\#(t),"ordinal":9,"type":"token_usage_record","payload":{"thread_id":"t","usage":{}}}"#), .responseEnd)
        XCTAssertEqual(kind(#"{\#(t),"type":"response_item","payload":{"type":"agent_message","id":"g","author":"/root"}}"#), .requestStart)
        XCTAssertEqual(kind(#"{\#(t),"type":"turn_context","payload":{"model":"gpt-5"}}"#), .other)
    }

    // MARK: - Plausibility gate

    func testSanitizedDropsImplausibleInstantsOneAtATime() {
        let completed = base.addingTimeInterval(100)
        // Too long ago: the start goes, the blocks stay.
        var checked = UsageRequestTiming.sanitized(
            start: base.addingTimeInterval(-3_600), firstBlock: base.addingTimeInterval(90), completed: completed
        )
        XCTAssertNil(checked.start)
        XCTAssertNotNil(checked.firstBlock)
        // Not before completion.
        checked = UsageRequestTiming.sanitized(start: completed, firstBlock: nil, completed: completed)
        XCTAssertNil(checked.start)
        // A first block before the start keeps the duration, loses itself.
        checked = UsageRequestTiming.sanitized(
            start: base.addingTimeInterval(50), firstBlock: base.addingTimeInterval(40), completed: completed
        )
        XCTAssertNotNil(checked.start)
        XCTAssertNil(checked.firstBlock)
        // No completion, nothing measured.
        checked = UsageRequestTiming.sanitized(start: base, firstBlock: base, completed: nil)
        XCTAssertNil(checked.start)
        XCTAssertNil(checked.completed)

        XCTAssertNil(UsageRequestTiming.outputTokensPerSecond(output: 100, durationMs: 499))
        XCTAssertNil(UsageRequestTiming.outputTokensPerSecond(output: 0, durationMs: 5_000))
        XCTAssertEqual(UsageRequestTiming.outputTokensPerSecond(output: 100, durationMs: 500), 200)
    }

    // MARK: - Claude Code

    func testClaudeScanTimesEachResponseFromTheLineBeforeIt() async throws {
        let home = try makeHome("ClaudeTiming")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        func assistant(_ at: Double, message: String, request: String, block: String, output: Int) -> String {
            #"{"parentUuid":"p","isSidechain":false,"message":{"id":"\#(message)","model":"claude-sonnet-4-5","role":"assistant","content":[{"type":"\#(block)"}],"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":\#(output)}},"requestId":"\#(request)","type":"assistant","uuid":"a-\#(at)","timestamp":"\#(stamp(at))","sessionId":"session-a","cwd":"/Users/example/project-a"}"#
        }
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(stamp(0))","sessionId":"session-a"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hello"},"uuid":"u1","timestamp":"\#(stamp(0.5))","sessionId":"session-a"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"attachment":{"type":"hook"},"type":"attachment","uuid":"a1","timestamp":"\#(stamp(0.6))","sessionId":"session-a"}"#,
            assistant(10, message: "msg-1", request: "req-1", block: "thinking", output: 700),
            assistant(11, message: "msg-1", request: "req-1", block: "text", output: 768),
            // Bookkeeping written mid-response is not a request boundary.
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(stamp(11.5))","sessionId":"session-a"}"#,
            assistant(13, message: "msg-1", request: "req-1", block: "tool_use", output: 768),
            #"{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"uuid":"u2","timestamp":"\#(stamp(14))","toolUseResult":{"timestamp":"\#(stamp(99))"},"sessionId":"session-a"}"#,
            #"{"type":"file-history-snapshot","messageId":"m","snapshot":{"timestamp":"\#(stamp(14.5))"},"isSnapshotUpdate":false}"#,
            assistant(20, message: "msg-2", request: "req-2", block: "text", output: 30),
            // A prompt that mentions both words is JSON-parsed, and still a boundary.
            #"{"parentUuid":"u2","isSidechain":false,"type":"user","message":{"role":"user","content":"why is the assistant usage high"},"uuid":"u3","timestamp":"\#(stamp(30))","sessionId":"session-a"}"#,
            assistant(31, message: "msg-3", request: "req-3", block: "text", output: 100)
        ]
        try lines.joined(separator: "\n").write(
            to: project.appendingPathComponent("session-a.jsonl"), atomically: true, encoding: .utf8
        )

        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now, eventSink: sink)
        let events = Dictionary(uniqueKeysWithValues: await sink.events().map { ($0.messageId ?? "", $0) })

        let first = try XCTUnwrap(events["msg-1"])
        XCTAssertEqual(first.requestStartedAt?.timeIntervalSince(base) ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(first.firstBlockAt?.timeIntervalSince(base) ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(first.completedAt?.timeIntervalSince(base) ?? -1, 13, accuracy: 0.001)
        XCTAssertEqual(first.durationMs, 12_400)
        XCTAssertEqual(first.firstTokenMs, 9_400)
        XCTAssertEqual(first.output, 768, "the last block's usage still wins")

        let second = try XCTUnwrap(events["msg-2"])
        XCTAssertEqual(second.durationMs, 6_000, "starts at the tool result, not the snapshot or its nested stamp")
        XCTAssertEqual(second.firstTokenMs, 6_000)

        let third = try XCTUnwrap(events["msg-3"])
        XCTAssertEqual(third.durationMs, 1_000)

        // The timing survives the warm cache.
        let again = CollectingSink()
        _ = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now, eventSink: again)
        let cached = await again.events().first { $0.messageId == "msg-1" }
        XCTAssertEqual(cached?.durationMs, 12_400)
        XCTAssertEqual(cached?.firstTokenMs, 9_400)
    }

    // MARK: - Codex

    func testCodexScanTimesEachReportedRequest() async throws {
        let home = try makeHome("CodexTiming")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent(".codex/sessions/2025/11/05", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        func line(_ at: Double, _ type: String, _ payload: String) -> String {
            #"{"timestamp":"\#(stamp(at))","ordinal":1,"type":"\#(type)","payload":\#(payload)}"#
        }
        func tokens(_ at: Double, input: Int, cached: Int, output: Int) -> String {
            line(at, "event_msg", #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}"#)
        }
        let usageRecord = #"{"thread_id":"t","response_id":"r","usage":{}}"#
        // The order Codex really writes: a tool's output — the next request's
        // opening line — lands *before* the token_count of the request that
        // called the tool.
        let lines = [
            line(0, "session_meta", #"{"id":"s","originator":"codex_cli_rs","cwd":"/Users/example/project-a"}"#),
            line(0.1, "event_msg", #"{"type":"task_started","turn_id":"t1"}"#),
            line(1.0, "response_item", #"{"type":"message","id":"m0","role":"developer","content":[]}"#),
            line(1.5, "response_item", #"{"type":"message","id":"m1","role":"user","content":[]}"#),
            line(1.6, "turn_context", #"{"model":"gpt-5.1-codex"}"#),
            line(5.0, "event_msg", #"{"type":"item_completed","item":{"type":"reasoning"}}"#),
            line(5.1, "response_item", #"{"type":"reasoning","id":"r1","summary":[]}"#),
            line(8.0, "response_item", #"{"type":"function_call","name":"shell","call_id":"c1"}"#),
            line(8.05, "token_usage_record", usageRecord),
            // The tool ran for ~1 s; that is not generation time.
            line(9.0, "response_item", #"{"type":"function_call_output","call_id":"c1","output":"ok"}"#),
            tokens(9.01, input: 1_000, cached: 200, output: 500),
            // A repeated total closes nothing.
            tokens(9.5, input: 1_000, cached: 200, output: 500),
            // A message another agent delivered opens the next request.
            line(9.6, "inter_agent_communication_metadata", #"{"trigger_turn":false}"#),
            line(9.6, "response_item", #"{"type":"agent_message","id":"g","author":"/root","recipient":"/root/worker","content":[]}"#),
            line(12.0, "response_item", #"{"type":"reasoning","id":"r2","summary":[]}"#),
            line(15.0, "response_item", #"{"type":"message","id":"m2","role":"assistant","content":[]}"#),
            line(15.1, "token_usage_record", usageRecord),
            tokens(15.2, input: 2_500, cached: 1_200, output: 900),
            line(15.3, "event_msg", #"{"type":"task_complete"}"#),
            // An older rollout: no usage record, the tool output still first.
            line(16.0, "event_msg", #"{"type":"task_started","turn_id":"t2"}"#),
            line(16.5, "response_item", #"{"type":"message","id":"m3","role":"user","content":[]}"#),
            line(20.0, "response_item", #"{"type":"reasoning","id":"r3","summary":[]}"#),
            line(22.0, "response_item", #"{"type":"custom_tool_call","name":"apply_patch","call_id":"c2"}"#),
            line(22.5, "response_item", #"{"type":"custom_tool_call_output","call_id":"c2","output":"ok"}"#),
            tokens(22.5, input: 3_000, cached: 1_200, output: 1_300)
        ]
        try lines.joined(separator: "\n").write(
            to: day.appendingPathComponent("rollout-2025-11-05T10-00-00-session.jsonl"),
            atomically: true, encoding: .utf8
        )

        let sink = CollectingSink()
        _ = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now, eventSink: sink)
        let events = await sink.events().sorted { $0.date < $1.date }
        XCTAssertEqual(events.count, 3)

        XCTAssertEqual(events[0].requestStartedAt?.timeIntervalSince(base) ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(events[0].firstBlockAt?.timeIntervalSince(base) ?? -1, 5.1, accuracy: 0.001)
        XCTAssertEqual(events[0].completedAt?.timeIntervalSince(base) ?? -1, 8.05, accuracy: 0.001)
        XCTAssertEqual(events[0].durationMs, 6_550, "ends at the usage record, not after the tool ran")
        XCTAssertEqual(events[0].firstTokenMs, 3_600)
        XCTAssertEqual(events[0].output, 500)

        XCTAssertEqual(events[1].durationMs, 5_500, "starts at the agent message, across the repeated total")
        XCTAssertEqual(events[1].firstTokenMs, 2_400)
        XCTAssertEqual(events[1].output, 400)

        XCTAssertEqual(events[2].durationMs, 5_500, "ends at the last model item without a usage record")
        XCTAssertEqual(events[2].firstTokenMs, 3_500)
        XCTAssertEqual(events[2].output, 400)
    }

    // MARK: - Scan cache encoding

    func testParsedEventTimingRoundTripsCompactly() throws {
        let event = CostUsageScanCache.ParsedEvent(
            date: base.addingTimeInterval(13),
            model: "gpt-5",
            input: 1,
            output: 2,
            cache: 0,
            requestStartedAt: base.addingTimeInterval(0.6),
            firstBlockAt: base.addingTimeInterval(10),
            completedAt: base.addingTimeInterval(13)
        )
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""rt":[-12400,-3000,0]"#), json)
        let decoded = try JSONDecoder().decode(CostUsageScanCache.ParsedEvent.self, from: data)
        XCTAssertEqual(decoded.durationMs, 12_400)
        XCTAssertEqual(decoded.firstTokenMs, 9_400)

        // An entry cached before timing existed decodes with none.
        let legacy = #"{"date":0,"model":"gpt-5","input":1,"output":2,"cache":0}"#
        let old = try JSONDecoder().decode(CostUsageScanCache.ParsedEvent.self, from: Data(legacy.utf8))
        XCTAssertNil(old.durationMs)
        XCTAssertNil(old.completedAt)
        XCTAssertFalse(String(data: try JSONEncoder().encode(old), encoding: .utf8)!.contains(#""rt""#))

        // A missing start encodes as null and keeps the blocks.
        let partial = CostUsageScanCache.ParsedEvent(
            date: base, model: "m", input: 0, output: 1, cache: 0,
            firstBlockAt: base.addingTimeInterval(-1), completedAt: base
        )
        XCTAssertTrue(String(data: try JSONEncoder().encode(partial), encoding: .utf8)!.contains(#""rt":[null,-1000,0]"#))
        XCTAssertNil(partial.durationMs)
    }

    // MARK: - Ledger

    private func timedEvent(
        at offset: Double,
        model: String = "gpt-5",
        output: Int,
        duration: Double?,
        firstToken: Double? = nil,
        harness: Harness? = nil
    ) -> CostUsageScanCache.ParsedEvent {
        let completed = now.addingTimeInterval(offset)
        let start = duration.map { completed.addingTimeInterval(-$0) }
        return CostUsageScanCache.ParsedEvent(
            date: completed,
            model: model,
            input: 1_000,
            output: output,
            cache: 0,
            harness: harness,
            requestStartedAt: start,
            firstBlockAt: firstToken.flatMap { value in start.map { $0.addingTimeInterval(value) } },
            completedAt: completed
        )
    }

    private func execute(_ path: String, _ sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5_000)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func scalar(_ path: String, _ sql: String) throws -> String? {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5_000)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    func testVersionFourLedgerGainsTheColumnsAndBackfillsOnReingest() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("TimingMigration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage_events.sqlite3").path
        await ledger.optimizeStorage()

        // A v4 ledger: one Codex row ingested before timing existed, a rollup,
        // and fingerprints for Codex and Gemini.
        let untimed = timedEvent(at: -60, output: 600, duration: nil)
        let batch = UsageLedgerFixtures.batch(events: [UsageLedgerFixtures.priced(untimed)])
        try await ledger.ingest(batch)
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .gemini, path: "/Users/example/.gemini/telemetry.log", events: []
        ))
        try execute(path, """
            ALTER TABLE usage_events DROP COLUMN duration_ms;
            ALTER TABLE usage_events DROP COLUMN first_token_ms;
            INSERT INTO usage_daily_rollups(day, tool, harness, model, requests) VALUES('2025-09-01', 'codex', 'codex', 'gpt-5', 7);
            UPDATE ledger_meta SET value = '4' WHERE key = 'schema_version';
            """)

        let reopened = try UsageEventLedger(url: URL(fileURLWithPath: path))
        await reopened.optimizeStorage()
        XCTAssertEqual(try scalar(path, "SELECT value FROM ledger_meta WHERE key = 'schema_version'"), "5")
        XCTAssertEqual(try scalar(path, "SELECT COUNT(*) FROM pragma_table_info('usage_events') WHERE name IN ('duration_ms', 'first_token_ms')"), "2")
        XCTAssertEqual(try scalar(path, "SELECT COUNT(*) FROM ingested_files WHERE tool IN ('codex', 'claude')"), "0")
        XCTAssertEqual(try scalar(path, "SELECT COUNT(*) FROM ingested_files WHERE tool = 'gemini'"), "1", "tools without timing keep their fingerprints")
        XCTAssertEqual(try scalar(path, "SELECT SUM(requests) FROM usage_daily_rollups"), "7", "rollups survive")

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        var page = try await reopened.requestPage(filter, pageSize: 10)
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertNil(page.rows.first?.durationMs)

        // The next scan re-reads the same file, now with timing: same row, filled in.
        let timed = timedEvent(at: -60, output: 600, duration: 12, firstToken: 2.5)
        try await reopened.ingest(UsageLedgerFixtures.batch(events: [UsageLedgerFixtures.priced(timed)]))
        page = try await reopened.requestPage(filter, pageSize: 10)
        XCTAssertEqual(page.rows.count, 1, "updated, not duplicated")
        XCTAssertEqual(page.rows.first?.durationMs, 12_000)
        XCTAssertEqual(page.rows.first?.firstTokenMs, 2_500)
        XCTAssertEqual(try XCTUnwrap(page.rows.first?.outputTokensPerSecond), 50, accuracy: 0.0001)
    }

    func testRequestRowsWithoutTimingOrTooShortHaveNoSpeed() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("TimingRows")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(timedEvent(at: -30, output: 100, duration: 0.4, firstToken: 0.2)),
            UsageLedgerFixtures.priced(timedEvent(at: -20, output: 100, duration: nil))
        ]))
        let rows = try await ledger.requestPage(UsageLedgerFixtures.wideFilter(around: now), pageSize: 10).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].durationMs)
        XCTAssertNil(rows[0].outputTokensPerSecond)
        XCTAssertEqual(rows[1].durationMs, 400)
        XCTAssertEqual(rows[1].firstTokenMs, 200)
        XCTAssertNil(rows[1].outputTokensPerSecond, "under 500 ms is not a speed")
    }

    func testSpeedCardTakesMediansOverMergedSamples() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("TimingSpeed")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Codex: 100, 200, 300, 400 tok/s; first tokens 1, 2, 3, 4 s.
        let codex = (1...4).map { index in
            UsageLedgerFixtures.priced(timedEvent(
                at: Double(-index * 60), output: index * 1_000, duration: 10, firstToken: Double(index)
            ))
        }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: codex))
        // ChatGPT Work on the same model, plus one untimed row.
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/work.jsonl",
            events: [
                UsageLedgerFixtures.priced(timedEvent(at: -500, output: 5_000, duration: 10, firstToken: 9, harness: .chatgptWork)),
                UsageLedgerFixtures.priced(timedEvent(at: -600, output: 5_000, duration: nil, harness: .chatgptWork))
            ]
        ))
        // Claude Code on another model.
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/demo/session.jsonl",
            events: [UsageLedgerFixtures.priced(timedEvent(
                at: -700, model: "claude-sonnet-4-5", output: 600, duration: 10, firstToken: 0.5
            ))]
        ))

        let interval = DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(60))
        let facts = try await ledger.dashboardFacts(UsageQueryFilter(range: interval))

        func build(_ harnesses: [Harness]?) -> UsageDashboardSnapshot.Speed {
            UsageDashboardBuilder.build(UsageDashboardInputs(
                query: UsageDashboardQuery(range: .today, interval: interval, harnesses: harnesses),
                now: now,
                ledger: facts
            )).speed
        }

        let all = build(nil)
        XCTAssertEqual(all.timedRequests, 6)
        XCTAssertEqual(all.byHarness.map(\.id), ["codex", "chatgptWork", "claudeCode"])
        let codexStat = try XCTUnwrap(all.byHarness.first?.stat)
        XCTAssertEqual(codexStat.requestsWithTiming, 4)
        XCTAssertEqual(try XCTUnwrap(codexStat.medianTokensPerSecond), 250, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(codexStat.p90TokensPerSecond), 370, accuracy: 0.01)
        XCTAssertEqual(codexStat.medianFirstTokenMs, 2_500)

        // gpt-5 merges Codex and ChatGPT Work before the median: 100…500.
        let gpt = try XCTUnwrap(all.byModel.first { $0.id == "gpt-5" }?.stat)
        XCTAssertEqual(gpt.requestsWithTiming, 5)
        XCTAssertEqual(try XCTUnwrap(gpt.medianTokensPerSecond), 300, accuracy: 0.01)
        XCTAssertEqual(gpt.medianFirstTokenMs, 3_000)
        XCTAssertEqual(all.byModel.first { $0.id == "claude-sonnet-4-5" }?.stat.medianFirstTokenMs, 500)

        // The chips narrow the samples, not just the rows shown.
        let codexOnly = build([.codex])
        XCTAssertEqual(codexOnly.byHarness.map(\.id), ["codex"])
        XCTAssertEqual(try XCTUnwrap(codexOnly.byModel.first?.stat.medianTokensPerSecond), 250, accuracy: 0.01)
        XCTAssertEqual(codexOnly.timedRequests, 4)

        XCTAssertTrue(build([.geminiCLI]).byHarness.isEmpty)
    }

    // MARK: - MCP

    func testRequestRowDTOCarriesTimingOnlyWhenMeasured() throws {
        func row(_ duration: Int64?, _ first: Int64?) -> UsageRequestRow {
            UsageRequestRow(
                id: 1, date: base, tool: .codex, harness: .codex, model: "gpt-5",
                freshInput: 1, output: 1_234, cacheRead: 0, cacheCreation: 0,
                costMicros: nil, serviceTier: nil, sessionId: nil, sourceKey: nil,
                durationMs: duration, firstTokenMs: first
            )
        }
        let timed = try XCTUnwrap(MCPJSON.encoding(MCPUsageRequestRowDTO(row: row(11_520, 2_600))).objectValue)
        XCTAssertEqual(timed["durationMs"]?.intValue, 11_520)
        XCTAssertEqual(timed["firstTokenMs"]?.intValue, 2_600)
        XCTAssertEqual(try XCTUnwrap(timed["outputTokensPerSecond"]?.doubleValue), 107.1, accuracy: 0.0001)

        let untimed = try XCTUnwrap(MCPJSON.encoding(MCPUsageRequestRowDTO(row: row(nil, nil))).objectValue)
        XCTAssertNil(untimed["durationMs"])
        XCTAssertNil(untimed["firstTokenMs"])
        XCTAssertNil(untimed["outputTokensPerSecond"])
    }
}
