import XCTest
import SQLite3
@testable import VibeBarCore

/// The harness dimension of `UsageEventLedger`: the in-place SQLite
/// migration, the per-harness grouping, and the filter.
final class UsageLedgerHarnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_339_200)

    // MARK: - Migration

    /// The pre-harness schema, as shipped. Rebuilt here rather than imported
    /// so a future schema edit cannot quietly rewrite the thing we migrate
    /// *from*.
    private func makeLegacyDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE ledger_meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE usage_events(
                id INTEGER PRIMARY KEY,
                tool TEXT NOT NULL,
                ts INTEGER NOT NULL,
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                fresh_input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_creation INTEGER NOT NULL DEFAULT 0,
                cost_micros INTEGER,
                dedupe_key TEXT NOT NULL UNIQUE
            );
            CREATE TABLE usage_daily_rollups(
                day TEXT NOT NULL,
                tool TEXT NOT NULL,
                model TEXT NOT NULL,
                requests INTEGER NOT NULL DEFAULT 0,
                fresh_input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_creation INTEGER NOT NULL DEFAULT 0,
                cost_micros INTEGER NOT NULL DEFAULT 0,
                unpriced INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(day, tool, model)
            );
            CREATE TABLE ingested_files(
                tool TEXT NOT NULL,
                file_key TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                PRIMARY KEY(tool, file_key)
            );
            INSERT INTO usage_events(tool, ts, day, model, dedupe_key)
                VALUES('codex', 1, '2026-07-01', 'gpt-5', 'f:one');
            INSERT INTO usage_events(tool, ts, day, model, dedupe_key)
                VALUES('claude', 2, '2026-07-01', 'claude-sonnet-4-5', 'cm-v3:two');
            INSERT INTO usage_events(tool, ts, day, model, dedupe_key)
                VALUES('cursor', 3, '2026-07-01', 'composer-1', 'three');
            INSERT INTO usage_daily_rollups(day, tool, model, requests, cost_micros)
                VALUES('2026-06-01', 'codex', 'gpt-5', 4, 400);
            INSERT INTO usage_daily_rollups(day, tool, model, requests, cost_micros)
                VALUES('2026-06-01', 'grok', 'grok-build', 2, 200);
            INSERT INTO ingested_files VALUES('codex', 'file-a', 1.0, 10);
            INSERT INTO ingested_files VALUES('claude', 'file-b', 2.0, 20);
            """, nil, nil, nil), SQLITE_OK)
        return db
    }

    private func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        var out: [[String]] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let columns = sqlite3_column_count(query)
            out.append((0..<columns).map { index in
                sqlite3_column_text(query, index).map { String(cString: $0) } ?? "<null>"
            })
        }
        return out
    }

    func testMigrationBackfillsDetailHarnessFromTheTool() throws {
        let db = try makeLegacyDatabase()
        defer { sqlite3_close_v2(db) }

        XCTAssertTrue(UsageEventLedger.migrateHarnessColumns(db))

        XCTAssertEqual(
            try rows(db, "SELECT tool, harness FROM usage_events ORDER BY ts"),
            [["codex", "codex"], ["claude", "claudeCode"], ["cursor", "cursor"]]
        )
    }

    func testMigrationWidensTheRollupKeyWithoutLosingRows() throws {
        let db = try makeLegacyDatabase()
        defer { sqlite3_close_v2(db) }

        XCTAssertTrue(UsageEventLedger.migrateHarnessColumns(db))

        XCTAssertEqual(
            try rows(
                db,
                "SELECT tool, harness, model, requests, cost_micros FROM usage_daily_rollups ORDER BY tool"
            ),
            [
                ["codex", "codex", "gpt-5", "4", "400"],
                ["grok", "grokBuild", "grok-build", "2", "200"]
            ]
        )
        // The widened key is what lets two harnesses of one tool coexist on
        // the same day and model.
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO usage_daily_rollups(day, tool, harness, model, requests, cost_micros)
                VALUES('2026-06-01', 'codex', 'chatgptWork', 'gpt-5', 9, 900);
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            try rows(
                db,
                """
                SELECT harness, requests FROM usage_daily_rollups
                 WHERE tool = 'codex' ORDER BY harness
                """
            ),
            [["chatgptWork", "9"], ["codex", "4"]]
        )
    }

    /// A rollout's harness lives in its `session_meta`, which only a fresh
    /// parse can read. Dropping Codex's fingerprints is what makes the next
    /// scan re-emit those files so the backfilled default can be corrected.
    func testMigrationDropsOnlyCodexIngestFingerprints() throws {
        let db = try makeLegacyDatabase()
        defer { sqlite3_close_v2(db) }

        XCTAssertTrue(UsageEventLedger.migrateHarnessColumns(db))

        XCTAssertEqual(
            try rows(db, "SELECT tool FROM ingested_files ORDER BY tool"),
            [["claude"]]
        )
    }

    func testMigrationIsIdempotentAndMarked() throws {
        let db = try makeLegacyDatabase()
        defer { sqlite3_close_v2(db) }

        XCTAssertTrue(UsageEventLedger.migrateHarnessColumns(db))
        XCTAssertEqual(
            try rows(db, "SELECT value FROM ledger_meta WHERE key = 'harness_v1'"),
            [["1"]]
        )
        XCTAssertEqual(sqlite3_exec(
            db,
            "INSERT INTO ingested_files VALUES('codex', 'file-c', 3.0, 30)",
            nil, nil, nil
        ), SQLITE_OK)

        // A second pass must be a no-op — in particular it must not drop the
        // fingerprints a completed re-scan just wrote.
        XCTAssertTrue(UsageEventLedger.migrateHarnessColumns(db))
        XCTAssertEqual(
            try rows(db, "SELECT tool, file_key FROM ingested_files ORDER BY file_key"),
            [["claude", "file-b"], ["codex", "file-c"]]
        )
    }

    /// The v2 fixup: rows stamped ChatGPT Work by the old `Codex Desktop` rule
    /// go back to Codex, folding into the Codex rollup that already owns the
    /// same day and model instead of sitting beside it.
    func testCodexHarnessFixupFoldsChatGPTWorkRowsBackIntoCodex() throws {
        let db = try makeLegacyDatabase()
        defer { sqlite3_close_v2(db) }
        XCTAssertTrue(UsageEventLedger.migrateHarnessColumns(db))
        XCTAssertEqual(sqlite3_exec(db, """
            UPDATE usage_events SET harness = 'chatgptWork' WHERE tool = 'codex';
            INSERT INTO usage_daily_rollups(
                    day, tool, harness, model, requests, fresh_input, output,
                    cache_read, cache_creation, cost_micros, unpriced)
                VALUES('2026-06-01', 'codex', 'chatgptWork', 'gpt-5', 9, 90, 9, 5, 1, 900, 3);
            INSERT INTO usage_daily_rollups(
                    day, tool, harness, model, requests, cost_micros)
                VALUES('2026-06-02', 'codex', 'chatgptWork', 'gpt-5', 1, 100);
            INSERT INTO ingested_files VALUES('codex', 'file-c', 3.0, 30);
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(UsageEventLedger.migrateCodexDesktopHarnessRows(db))

        XCTAssertEqual(
            try rows(db, "SELECT tool, harness FROM usage_events ORDER BY ts"),
            [["codex", "codex"], ["claude", "claudeCode"], ["cursor", "cursor"]]
        )
        // The colliding day is summed; the day Codex did not already own is
        // simply relabelled. Nothing is left under chatgptWork.
        XCTAssertEqual(
            try rows(db, """
                SELECT day, harness, requests, fresh_input, cost_micros, unpriced
                  FROM usage_daily_rollups WHERE tool = 'codex' ORDER BY day
                """),
            [
                ["2026-06-01", "codex", "13", "90", "1300", "3"],
                ["2026-06-02", "codex", "1", "0", "100", "0"]
            ]
        )
        XCTAssertEqual(
            try rows(db, "SELECT value FROM ledger_meta WHERE key = 'harness_v2'"),
            [["1"]]
        )
        // Codex's fingerprints are gone so the next scan re-stamps every
        // rollout; no other tool is asked to re-read anything.
        XCTAssertEqual(
            try rows(db, "SELECT tool, file_key FROM ingested_files ORDER BY file_key"),
            [["claude", "file-b"]]
        )

        // A second open must not re-run: the fingerprints a completed re-scan
        // wrote have to survive, and the folded rollups must not double.
        XCTAssertEqual(sqlite3_exec(
            db, "INSERT INTO ingested_files VALUES('codex', 'file-d', 4.0, 40)", nil, nil, nil
        ), SQLITE_OK)
        XCTAssertTrue(UsageEventLedger.migrateCodexDesktopHarnessRows(db))
        XCTAssertEqual(
            try rows(db, "SELECT tool, file_key FROM ingested_files ORDER BY file_key"),
            [["claude", "file-b"], ["codex", "file-d"]]
        )
        XCTAssertEqual(
            try rows(db, """
                SELECT requests FROM usage_daily_rollups
                 WHERE tool = 'codex' AND day = '2026-06-01'
                """),
            [["13"]]
        )
    }

    func testFreshLedgerIsBornMigrated() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessFresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now))
        ]))
        let stats = try await ledger.harnessStats(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(stats.map(\.harness), [.codex])
    }

    // MARK: - Grouping and filtering

    func testHarnessStatsSeparateTwoHarnessesOfOneTool() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessSplit")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/cli.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(date: now, input: 1_000, output: 100, harness: .codex)
                )
            ]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/desktop.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now, input: 4_000, output: 400, harness: .chatgptWork
                    )
                )
            ]
        ))

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let stats = try await ledger.harnessStats(filter)
        XCTAssertEqual(stats.map(\.harness), [.chatgptWork, .codex])
        XCTAssertEqual(stats[0].totalTokens, 4_400)
        XCTAssertEqual(stats[1].totalTokens, 1_100)
        // Both still belong to one company on the quota axis.
        let providers = try await ledger.providerStats(filter)
        XCTAssertEqual(providers.map(\.tool), [.codex])
        XCTAssertEqual(providers[0].requests, 2)
    }

    func testHarnessFilterNarrowsSummaryAndModels() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessFilter")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/cli.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(date: now, model: "gpt-5", harness: .codex)
                )
            ]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/desktop.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now, model: "gpt-5-desktop", harness: .chatgptWork
                    )
                )
            ]
        ))

        var filter = UsageLedgerFixtures.wideFilter(around: now)
        let all = try await ledger.summary(filter).requests
        XCTAssertEqual(all, 2)

        filter.harnesses = [.chatgptWork]
        let desktopOnly = try await ledger.summary(filter).requests
        XCTAssertEqual(desktopOnly, 1)
        let desktopModels = try await ledger.availableModels(harnesses: [.chatgptWork])
        XCTAssertEqual(desktopModels, ["gpt-5-desktop"])

        filter.harnesses = []
        let none = try await ledger.summary(filter).requests
        XCTAssertEqual(none, 0)
    }

    /// The whole point of dropping Codex's fingerprints in the migration: the
    /// re-emitted rows have to *replace* the backfilled default rather than
    /// duplicating it.
    func testReIngestCorrectsABackfilledHarnessInPlace() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessCorrect")
        defer { try? FileManager.default.removeItem(at: directory) }

        let event = UsageLedgerFixtures.event(date: now, input: 1_000, output: 100)
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/desktop.jsonl",
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            events: [UsageLedgerFixtures.priced(event)]
        ))
        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let backfilled = try await ledger.harnessStats(filter)
        XCTAssertEqual(backfilled.map(\.harness), [.codex])

        let corrected = UsageLedgerFixtures.event(
            date: now, input: 1_000, output: 100, harness: .chatgptWork
        )
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/desktop.jsonl",
            // A different fingerprint stands in for the dropped `ingested_files`
            // row: either way the batch is no longer skipped.
            mtime: Date(timeIntervalSince1970: 1_700_000_500),
            events: [UsageLedgerFixtures.priced(corrected)]
        ))

        let stats = try await ledger.harnessStats(filter)
        XCTAssertEqual(stats.map(\.harness), [.chatgptWork])
        let requests = try await ledger.summary(filter).requests
        XCTAssertEqual(requests, 1, "corrected, not duplicated")
    }

    func testRequestRowsCarryTheProducingHarness() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessRequestRows")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/desktop.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now, input: 4_000, output: 400, harness: .chatgptWork
                    )
                )
            ]
        ))
        // Nothing stamped: the row still has to resolve through the tool's
        // default, the same value the migration would have backfilled.
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/demo/session.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now.addingTimeInterval(-60),
                        model: "claude-sonnet-4-5", input: 1_000, output: 100
                    )
                )
            ]
        ))

        let page = try await ledger.requestPage(
            UsageLedgerFixtures.wideFilter(around: now), page: 0, pageSize: 10
        )
        XCTAssertEqual(page.rows.map(\.harness), [.chatgptWork, .claudeCode])
        // The quota-side tool is unchanged: the two axes coexist on one row.
        XCTAssertEqual(page.rows.map(\.tool), [.codex, .claude])
    }

    /// Two fully unpriced rollups can share a day, tool and model and differ
    /// only by harness. Repricing has to match the whole primary key, or the
    /// first row's cost is written onto both and both are marked priced.
    func testRepricingPricesEachHarnessRollupSeparately() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessRepricing")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { PricingResolver.testOverride = nil }

        let base = PricingHardcoded.fallback
        var codexModels = base.providers.codex.models
        codexModels["linear-test"] = .init(input: 2e-6, output: 6e-6, cacheRead: nil)
        PricingResolver.testOverride = PricingDataSet(
            schemaVersion: base.schemaVersion,
            updatedAt: "test-harness-repricing",
            calculationVersion: base.calculationVersion,
            providers: .init(
                codex: .init(displayName: "OpenAI", models: codexModels),
                claude: base.providers.claude,
                gemini: base.providers.gemini,
                grok: base.providers.grok,
                antigravity: base.providers.antigravity
            )
        )

        let old = now.addingTimeInterval(-60 * 86_400)
        let seeds: [(path: String, harness: Harness, input: Int, output: Int)] = [
            ("/Users/example/.codex/sessions/cli.jsonl", .codex, 1_000_000, 100_000),
            ("/Users/example/.codex/sessions/desktop.jsonl", .chatgptWork, 2_000_000, 200_000)
        ]
        for seed in seeds {
            try await ledger.ingest(UsageLedgerFixtures.batch(
                path: seed.path,
                events: [
                    UsageLedgerFixtures.priced(
                        UsageLedgerFixtures.event(
                            date: old, model: "linear-test",
                            input: seed.input, output: seed.output, harness: seed.harness
                        ),
                        costUSD: nil
                    )
                ]
            ))
        }
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 90)

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let before = try await ledger.summary(filter)
        XCTAssertEqual(before.requests, 2)
        XCTAssertEqual(before.unpricedRequests, 2)

        let prepared = try await ledger.prepareForPricingRevision("pricing-harness")
        XCTAssertTrue(prepared)

        let stats = try await ledger.harnessStats(filter)
        XCTAssertEqual(stats.map(\.harness), [.chatgptWork, .codex])
        XCTAssertEqual(stats[0].costMicros, 5_200_000)
        XCTAssertEqual(stats[1].costMicros, 2_600_000)
        let after = try await ledger.summary(filter)
        XCTAssertEqual(after.unpricedRequests, 0)
        XCTAssertEqual(after.costMicros, 7_800_000)
    }

    // MARK: - Hourly floor

    func testFloorCheckToolsDerivesToolsFromTheHarnessFilter() {
        XCTAssertNil(UsageEventLedger.floorCheckTools(tools: nil, harnesses: nil))
        XCTAssertEqual(
            UsageEventLedger.floorCheckTools(tools: nil, harnesses: [.claudeCode, .claudeCowork]),
            [.claude]
        )
        XCTAssertEqual(
            UsageEventLedger.floorCheckTools(tools: nil, harnesses: [.codex, .grokBuild]),
            [.codex, .grok]
        )
        XCTAssertEqual(
            UsageEventLedger.floorCheckTools(tools: [.codex, .claude], harnesses: [.claudeCode]),
            [.claude]
        )
        XCTAssertEqual(
            UsageEventLedger.floorCheckTools(tools: [.grok], harnesses: nil),
            [.grok]
        )
        // Disjoint axes match no row at all, so no floor can veto anything.
        XCTAssertEqual(
            UsageEventLedger.floorCheckTools(tools: [.codex], harnesses: [.claudeCode]),
            []
        )
    }

    /// A harness-only selection must be checked against *its* tool's floor.
    /// Codex has folded history here and Claude Code does not, so the Hourly
    /// picker has to stay available once the filter excludes Codex.
    func testHarnessFilterKeepsHourlyDespiteAnotherToolsDetailFloor() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessHourlyFloor")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/cli.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(date: now.addingTimeInterval(-5 * 86_400))
                )
            ]
        ))
        // Only Codex is ingested at this point, so only Codex gains a floor.
        try await ledger.rollupAndPrune(now: now, detailDays: 1, retentionDays: 0)
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/demo/session.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now.addingTimeInterval(-2 * 3_600), model: "claude-sonnet-4-5"
                    )
                )
            ]
        ))
        let codexFloor = try await ledger.detailFloorDay(for: .codex)
        XCTAssertNotNil(codexFloor)
        let claudeFloor = try await ledger.detailFloorDay(for: .claude)
        XCTAssertNil(claudeFloor)

        var filter = UsageQueryFilter(
            range: DateInterval(
                start: now.addingTimeInterval(-3 * 86_400),
                end: now.addingTimeInterval(3_600)
            )
        )
        let unfiltered = try await ledger.supportsHourlyTrend(filter)
        XCTAssertFalse(unfiltered)

        filter.harnesses = [.claudeCode]
        let claudeCodeOnly = try await ledger.supportsHourlyTrend(filter)
        XCTAssertTrue(claudeCodeOnly)
        let bucket = try await ledger.trend(filter, bucket: .hour).bucket
        XCTAssertEqual(bucket, .hour)

        // Disagreeing axes match nothing, so no floor is left to veto.
        filter.tools = [.codex]
        let disjoint = try await ledger.supportsHourlyTrend(filter)
        XCTAssertTrue(disjoint)

        // Codex alone is still vetoed by its own floor.
        filter.harnesses = nil
        let codexOnly = try await ledger.supportsHourlyTrend(filter)
        XCTAssertFalse(codexOnly)
    }

    func testRollupKeepsHarnessesApartBelowTheDetailFloor() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessRollup")
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = now.addingTimeInterval(-120 * 86_400)
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/cli.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(date: old, input: 1_000, output: 100, harness: .codex)
                )
            ]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/desktop.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: old, input: 4_000, output: 400, harness: .chatgptWork
                    )
                )
            ]
        ))

        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        // Detail rows are gone; these totals can only come from the rollups.
        let detailCount = try await ledger.requestPage(filter, page: 0, pageSize: 50).totalCount
        XCTAssertEqual(detailCount, 0)
        let stats = try await ledger.harnessStats(filter)
        XCTAssertEqual(stats.map(\.harness), [.chatgptWork, .codex])
        XCTAssertEqual(stats[0].totalTokens, 4_400)
        XCTAssertEqual(stats[1].totalTokens, 1_100)
    }
}
