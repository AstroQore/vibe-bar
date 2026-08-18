import XCTest
import SQLite3
@testable import VibeBarCore

/// Shared fixtures for the `UsageEventLedger` test files. Everything is
/// synthetic: `/Users/example/...` paths and fake session / message ids.
enum UsageLedgerFixtures {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A ledger on a throwaway file, plus the directory to delete after.
    static func makeLedger(_ label: String) throws -> (UsageEventLedger, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBar\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage_events.sqlite3")
        return (try UsageEventLedger(url: url), directory)
    }

    static func event(
        date: Date,
        model: String = "gpt-5",
        input: Int = 1_000,
        output: Int = 200,
        cache: Int = 0,
        cacheCreation: Int? = nil,
        sessionId: String? = nil,
        messageId: String? = nil,
        requestId: String? = nil,
        isSidechain: Bool? = nil,
        pathRole: CostUsageScanCache.PathRole? = nil,
        sourceKey: String? = nil,
        serviceTier: String? = nil,
        harness: Harness? = nil
    ) -> CostUsageScanCache.ParsedEvent {
        CostUsageScanCache.ParsedEvent(
            date: date,
            model: model,
            input: input,
            output: output,
            cache: cache,
            cacheCreation: cacheCreation,
            sessionId: sessionId,
            messageId: messageId,
            requestId: requestId,
            isSidechain: isSidechain,
            pathRole: pathRole,
            sourceKey: sourceKey,
            serviceTier: serviceTier,
            harness: harness
        )
    }

    static func priced(
        _ event: CostUsageScanCache.ParsedEvent,
        costUSD: Double? = 0.25
    ) -> PricedUsageEvent {
        PricedUsageEvent(event: event, costUSD: costUSD)
    }

    static func batch(
        tool: ToolType = .codex,
        path: String = "/Users/example/.codex/sessions/session-a.jsonl",
        mtime: Date = Date(timeIntervalSince1970: 1_700_000_000),
        size: Int64 = 4_096,
        events: [PricedUsageEvent]
    ) -> UsageEventFileBatch {
        UsageEventFileBatch(tool: tool, filePath: path, mtime: mtime, size: size, events: events)
    }

    /// A filter wide enough to catch everything these tests write.
    static func wideFilter(
        around date: Date,
        tools: [ToolType]? = nil,
        models: [String]? = nil
    ) -> UsageQueryFilter {
        UsageQueryFilter(
            range: DateInterval(
                start: date.addingTimeInterval(-400 * 86_400),
                end: date.addingTimeInterval(2 * 86_400)
            ),
            tools: tools,
            models: models
        )
    }
}

final class UsageEventLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_339_200)

    func testInitCreatesUsableDatabaseOnATemporaryFile() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerInit")
        defer { try? FileManager.default.removeItem(at: directory) }

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 0)
        XCTAssertNil(summary.costMicros)
        XCTAssertNil(summary.cacheHitRate)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("usage_events.sqlite3").path
            )
        )
    }

    func testInitCreatesTimeOrderedRequestIndex() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerTimeIndex")
        defer { try? FileManager.default.removeItem(at: directory) }
        // `init` schedules storage upkeep (index build + ANALYZE) on the actor;
        // opening the file read-only while that write is in flight returns
        // SQLITE_BUSY. Await it so the assertion is deterministic.
        await ledger.optimizeStorage()
        let url = directory.appendingPathComponent("usage_events.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        defer { if let database { sqlite3_close_v2(database) } }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'usage_events_ts_id_idx'",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { if let statement { sqlite3_finalize(statement) } }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    }

    func testCursorToolMigrationUpdatesOnlyIdentifiableDetailRowsInPlace() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE ledger_meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE usage_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool TEXT NOT NULL,
                harness TEXT,
                source_key TEXT,
                dedupe_key TEXT NOT NULL UNIQUE
            );
            INSERT INTO ledger_meta VALUES('detail_floor_day:grok', '2026-07-17');
            INSERT INTO usage_events(tool, source_key, dedupe_key)
                VALUES('grok', 'cursor-event-v1-fixture', 'f:legacy-cursor');
            INSERT INTO usage_events(tool, source_key, dedupe_key)
                VALUES('grok', 'grok-session-fixture', 'f:grok');
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(UsageEventLedger.migrateCursorToolRows(db))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db,
            "SELECT tool FROM usage_events ORDER BY source_key",
            -1,
            &statement,
            nil
        ), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        var tools: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            tools.append(String(cString: sqlite3_column_text(query, 0)))
        }
        XCTAssertEqual(tools, ["cursor", "grok"])

        var floorStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db,
            "SELECT value FROM ledger_meta WHERE key = 'detail_floor_day:cursor'",
            -1,
            &floorStatement,
            nil
        ), SQLITE_OK)
        let floorQuery = try XCTUnwrap(floorStatement)
        defer { sqlite3_finalize(floorQuery) }
        XCTAssertEqual(sqlite3_step(floorQuery), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(floorQuery, 0)), "2026-07-17")
    }

    func testCursorToolMigrationDoesNotInventFloorWithoutCursorEvidence() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE ledger_meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE usage_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool TEXT NOT NULL,
                harness TEXT,
                source_key TEXT,
                dedupe_key TEXT NOT NULL UNIQUE
            );
            INSERT INTO ledger_meta VALUES('detail_floor_day:grok', '2026-07-17');
            INSERT INTO usage_events(tool, source_key, dedupe_key)
                VALUES('grok', 'grok-session-fixture', 'f:grok');
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(UsageEventLedger.migrateCursorToolRows(db))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db,
            "SELECT value FROM ledger_meta WHERE key = 'detail_floor_day:cursor'",
            -1,
            &statement,
            nil
        ), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_DONE)
    }

    /// A second batch carrying the same `(mtime, size)` fingerprint is
    /// skipped wholesale — proven by handing it *more* events than the
    /// first and watching the extra one never land.
    func testUnchangedFingerprintSkipsTheWholeBatch() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerFingerprint")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now)),
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now.addingTimeInterval(-60)))
        ])
        let initialRevision = await ledger.contentRevision()
        try await ledger.ingest(first)
        let firstRevision = await ledger.contentRevision()
        XCTAssertEqual(firstRevision, initialRevision + 1)
        let afterFirstIngest = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now)).requests
        XCTAssertEqual(afterFirstIngest, 2)

        let sameFingerprint = UsageLedgerFixtures.batch(
            events: first.events + [
                UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now.addingTimeInterval(-120)))
            ]
        )
        try await ledger.ingest(sameFingerprint)
        let sameRevision = await ledger.contentRevision()
        XCTAssertEqual(sameRevision, firstRevision)
        let afterSameFingerprint = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now)).requests
        XCTAssertEqual(afterSameFingerprint, 2)

        // A changed fingerprint re-ingests: the two originals upsert onto
        // their existing dedupe keys, the third is new.
        let changed = UsageEventFileBatch(
            tool: sameFingerprint.tool,
            filePath: sameFingerprint.filePath,
            mtime: sameFingerprint.mtime.addingTimeInterval(120),
            size: sameFingerprint.size + 1,
            events: sameFingerprint.events
        )
        try await ledger.ingest(changed)
        let changedRevision = await ledger.contentRevision()
        XCTAssertEqual(changedRevision, firstRevision + 1)
        let afterChangedFingerprint = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now)).requests
        XCTAssertEqual(afterChangedFingerprint, 3)
    }

    func testPricingRevisionRepricesWithoutDeletingDetailOrRollups() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerRepricing")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { PricingResolver.testOverride = nil }

        let base = PricingHardcoded.fallback
        var grokModels = base.providers.grok.models
        grokModels["grok-4.6"] = .init(input: 2e-6, output: 6e-6, cacheRead: nil)
        PricingResolver.testOverride = PricingDataSet(
            schemaVersion: base.schemaVersion,
            updatedAt: "test-repricing",
            calculationVersion: base.calculationVersion,
            providers: .init(
                codex: base.providers.codex,
                claude: base.providers.claude,
                gemini: base.providers.gemini,
                grok: .init(displayName: "xAI", models: grokModels),
                antigravity: base.providers.antigravity
            )
        )

        let preparedOldRevision = try await ledger.prepareForPricingRevision("pricing-old")
        XCTAssertTrue(preparedOldRevision)
        let oldEvent = UsageLedgerFixtures.event(
            date: now.addingTimeInterval(-60 * 86_400), model: "grok-4.6",
            input: 1_000_000, output: 100_000
        )
        let recentEvent = UsageLedgerFixtures.event(
            date: now.addingTimeInterval(-5 * 86_400), model: "grok-4.6",
            input: 1_000_000, output: 100_000
        )
        let oldBatch = UsageLedgerFixtures.batch(
            tool: .grok,
            path: "/Users/example/.grok/sessions/session-a.jsonl",
            events: [
                UsageLedgerFixtures.priced(oldEvent, costUSD: nil),
                UsageLedgerFixtures.priced(recentEvent, costUSD: 9.0)
            ]
        )
        try await ledger.ingest(oldBatch)
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 90)

        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let before = try await ledger.summary(filter)
        XCTAssertEqual(before.requests, 2)
        XCTAssertEqual(before.unpricedRequests, 1)
        XCTAssertEqual(before.costMicros, 9_000_000)
        let repeatedOldRevision = try await ledger.prepareForPricingRevision("pricing-old")
        XCTAssertFalse(repeatedOldRevision)
        let unchanged = try await ledger.summary(filter)
        XCTAssertEqual(unchanged.requests, 2)

        let preparedNewRevision = try await ledger.prepareForPricingRevision("pricing-new")
        XCTAssertTrue(preparedNewRevision)
        let repriced = try await ledger.summary(filter)
        XCTAssertEqual(repriced.requests, 2)
        XCTAssertEqual(repriced.unpricedRequests, 0)
        XCTAssertEqual(repriced.costMicros, 5_200_000)
        let detailFloor = try await ledger.detailFloorDay(for: .grok)
        XCTAssertNotNil(detailFloor)
        let detailPage = try await ledger.requestPage(filter, pageSize: 10)
        XCTAssertEqual(detailPage.totalCount, 1)
        let modelStats = try await ledger.modelStats(filter)
        XCTAssertEqual(modelStats.first?.costMicros, 5_200_000)
    }

    func testPricingRevisionLeavesAmbiguousTieredAndFastRollupsUnpriced() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerAmbiguousRepricing")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { PricingResolver.testOverride = nil }

        let base = PricingHardcoded.fallback
        var codexModels = base.providers.codex.models
        codexModels["tiered-test"] = .init(
            input: 1e-6, output: 2e-6, cacheRead: nil,
            thresholdTokens: 200_000,
            inputAboveThreshold: 2e-6,
            outputAboveThreshold: 4e-6
        )
        codexModels["fast-test"] = .init(
            input: 1e-6, output: 2e-6, cacheRead: nil,
            fastMultiplier: 2.0
        )
        PricingResolver.testOverride = PricingDataSet(
            schemaVersion: base.schemaVersion,
            updatedAt: "test-ambiguous-repricing",
            calculationVersion: base.calculationVersion,
            providers: .init(
                codex: .init(displayName: "OpenAI", models: codexModels),
                claude: base.providers.claude,
                gemini: base.providers.gemini,
                grok: base.providers.grok,
                antigravity: base.providers.antigravity
            )
        )

        for (index, model) in ["tiered-test", "fast-test"].enumerated() {
            let event = UsageLedgerFixtures.event(
                date: now.addingTimeInterval(-60 * 86_400),
                model: model,
                input: 150_000,
                output: 10_000,
                serviceTier: index == 1 ? "fast" : nil
            )
            try await ledger.ingest(UsageLedgerFixtures.batch(
                path: "/Users/example/.codex/sessions/ambiguous-\(index).jsonl",
                events: [UsageLedgerFixtures.priced(event, costUSD: nil)]
            ))
        }
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 90)

        let prepared = try await ledger.prepareForPricingRevision("pricing-new")
        XCTAssertTrue(prepared)
        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(summary.unpricedRequests, 2)
        XCTAssertNil(summary.costMicros)
    }

    /// `(messageId, requestId)` is the same billable request no matter how
    /// many transcripts copied it. The parent, non-sidechain copy must win
    /// regardless of which file the scan reached first.
    func testDedupeConflictPrefersTheParentNonSidechainCopy() async throws {
        for sidechainFirst in [true, false] {
            let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerConflict")
            defer { try? FileManager.default.removeItem(at: directory) }

            let parent = UsageLedgerFixtures.event(
                date: now, model: "claude-sonnet-4-5", input: 100, output: 50,
                sessionId: "session-1", messageId: "msg-1", requestId: "req-1",
                isSidechain: false, pathRole: .parent, sourceKey: "path-v1-aaa"
            )
            let sidechain = UsageLedgerFixtures.event(
                date: now, model: "claude-sonnet-4-5", input: 900, output: 400,
                sessionId: "session-1", messageId: "msg-1", requestId: "req-1",
                isSidechain: true, pathRole: .subagent, sourceKey: "path-v1-bbb"
            )
            let parentBatch = UsageLedgerFixtures.batch(
                tool: .claude,
                path: "/Users/example/.claude/projects/demo/parent.jsonl",
                events: [UsageLedgerFixtures.priced(parent, costUSD: 0.10)]
            )
            let sidechainBatch = UsageLedgerFixtures.batch(
                tool: .claude,
                path: "/Users/example/.claude/projects/demo/subagents/child.jsonl",
                events: [UsageLedgerFixtures.priced(sidechain, costUSD: 0.90)]
            )
            if sidechainFirst {
                try await ledger.ingest(sidechainBatch)
                try await ledger.ingest(parentBatch)
            } else {
                try await ledger.ingest(parentBatch)
                try await ledger.ingest(sidechainBatch)
            }

            let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
            XCTAssertEqual(summary.requests, 1, "sidechainFirst=\(sidechainFirst)")
            XCTAssertEqual(summary.freshInput, 100, "sidechainFirst=\(sidechainFirst)")
            XCTAssertEqual(summary.output, 50, "sidechainFirst=\(sidechainFirst)")
            XCTAssertEqual(summary.costMicros, 100_000, "sidechainFirst=\(sidechainFirst)")
        }
    }

    /// Claude only guarantees message/request ids inside one session. Two
    /// sessions that reuse those ids are two billable requests and must stay
    /// separate, matching `CostUsageScanner`'s source aggregation.
    func testClaudeDedupeKeepsMatchingMessageIDsFromDifferentSessions() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerSessionScopedDedupe")
        defer { try? FileManager.default.removeItem(at: directory) }

        for (session, input, path) in [
            ("session-a", 111, "/Users/example/.claude/projects/demo/a.jsonl"),
            ("session-b", 222, "/Users/example/.claude/projects/demo/b.jsonl")
        ] {
            let event = UsageLedgerFixtures.event(
                date: now,
                model: "claude-sonnet-4-5",
                input: input,
                output: 10,
                sessionId: session,
                messageId: "msg-reused",
                requestId: "req-reused",
                isSidechain: false,
                pathRole: .parent,
                sourceKey: "path-v1-\(session)"
            )
            try await ledger.ingest(UsageLedgerFixtures.batch(
                tool: .claude,
                path: path,
                events: [UsageLedgerFixtures.priced(event)]
            ))
        }

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(summary.freshInput, 333)
        XCTAssertEqual(summary.output, 20)
    }

    /// The persisted dedupe key must include the fields after the session id.
    /// SQLite text bindings are NUL terminated, so an embedded `\0` separator
    /// would silently collapse these two requests into one row.
    func testClaudeDedupeKeepsDifferentMessagesInsideOneSession() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerMessageScopedDedupe")
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = [
            UsageLedgerFixtures.event(
                date: now, input: 100, sessionId: "session-shared",
                messageId: "message-a", requestId: "request-a"
            ),
            UsageLedgerFixtures.event(
                date: now.addingTimeInterval(1), input: 200, sessionId: "session-shared",
                messageId: "message-b", requestId: "request-b"
            )
        ]
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            events: events.map { UsageLedgerFixtures.priced($0) }
        ))

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(summary.freshInput, 300)
    }

    /// Same message, both copies in a parent path: the smaller source key
    /// wins, matching `CostUsageScanner.claudeEventWins`'s final tiebreak.
    func testDedupeConflictTiebreaksOnSourceKey() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerTiebreak")
        defer { try? FileManager.default.removeItem(at: directory) }

        let low = UsageLedgerFixtures.event(
            date: now, model: "claude-sonnet-4-5", input: 111, output: 11,
            sessionId: "session-2", messageId: "msg-2", requestId: "req-2",
            isSidechain: false, pathRole: .parent, sourceKey: "path-v1-aaa"
        )
        let high = UsageLedgerFixtures.event(
            date: now, model: "claude-sonnet-4-5", input: 222, output: 22,
            sessionId: "session-2", messageId: "msg-2", requestId: "req-2",
            isSidechain: false, pathRole: .parent, sourceKey: "path-v1-zzz"
        )
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude, path: "/Users/example/.claude/projects/demo/z.jsonl",
            events: [UsageLedgerFixtures.priced(high)]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude, path: "/Users/example/.claude/projects/demo/a.jsonl",
            events: [UsageLedgerFixtures.priced(low)]
        ))

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.freshInput, 111)
    }

    /// Claude reports `cache` as read + creation combined and repeats the
    /// creation half in `cacheCreation`; ingest must split them back apart.
    func testClaudeCombinedCacheFieldSplitsIntoReadAndCreation() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerCacheSplit")
        defer { try? FileManager.default.removeItem(at: directory) }

        let event = UsageLedgerFixtures.event(
            date: now, model: "claude-sonnet-4-5", input: 400, output: 80,
            cache: 700, cacheCreation: 100,
            messageId: "msg-3", requestId: "req-3"
        )
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude, path: "/Users/example/.claude/projects/demo/s.jsonl",
            events: [UsageLedgerFixtures.priced(event)]
        ))

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.freshInput, 400)
        XCTAssertEqual(summary.cacheRead, 600)
        XCTAssertEqual(summary.cacheCreation, 100)
        XCTAssertEqual(summary.output, 80)
        XCTAssertEqual(summary.realTotalTokens, 1_180)
    }

    func testUnpricedRowsAreCountedButContributeNoCost() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerUnpriced")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now), costUSD: 0.50),
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: now.addingTimeInterval(-60)), costUSD: nil
            ),
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: now.addingTimeInterval(-120)), costUSD: nil
            )
        ]))

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 3)
        XCTAssertEqual(summary.unpricedRequests, 2)
        XCTAssertEqual(summary.costMicros, 500_000)
    }

    /// With nothing priced at all, cost is `nil` rather than a misleading
    /// `$0.00`.
    func testCostIsNilWhenNoRowCarriedAPrice() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerAllUnpriced")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now), costUSD: nil)
        ]))

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.unpricedRequests, 1)
        XCTAssertNil(summary.costMicros)
    }

    func testEraseAllClearsEventsRollupsAndFingerprints() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerErase")
        defer { try? FileManager.default.removeItem(at: directory) }

        let batch = UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now))
        ])
        try await ledger.ingest(batch)
        try await ledger.rollupAndPrune(now: now, detailDays: 0, retentionDays: 0)
        let floorAfterRollup = try await ledger.detailFloorDay(for: .codex)
        XCTAssertNotNil(floorAfterRollup)

        try await ledger.eraseAll()

        let summary = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(summary.requests, 0)
        XCTAssertNil(summary.costMicros)
        let floorAfterErase = try await ledger.detailFloorDay(for: .codex)
        XCTAssertNil(floorAfterErase)
        // The fingerprint went with it, so the very same batch re-ingests.
        try await ledger.ingest(batch)
        let afterReingest = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now)).requests
        XCTAssertEqual(afterReingest, 1)
    }

    func testProviderAndModelStatsGroupAcrossTools() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("LedgerStats")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .codex,
            path: "/Users/example/.codex/sessions/one.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(date: now, model: "gpt-5", input: 1_000, output: 100),
                    costUSD: 1.0
                ),
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now.addingTimeInterval(-60), model: "gpt-5", input: 500, output: 50
                    ),
                    costUSD: 0.5
                )
            ]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/demo/one.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now, model: "claude-sonnet-4-5", input: 10, output: 5,
                        messageId: "msg-9", requestId: "req-9"
                    ),
                    costUSD: 0.25
                )
            ]
        ))

        let providers = try await ledger.providerStats(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(providers.map(\.tool), [.codex, .claude])
        XCTAssertEqual(providers.first?.requests, 2)
        XCTAssertEqual(providers.first?.totalTokens, 1_650)
        XCTAssertEqual(providers.first?.costMicros, 1_500_000)

        let models = try await ledger.modelStats(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(models.map(\.model), ["gpt-5", "claude-sonnet-4-5"])
        XCTAssertEqual(models.first?.avgCostMicrosPerRequest, 750_000)

        let allModels = try await ledger.availableModels()
        XCTAssertEqual(allModels, ["claude-sonnet-4-5", "gpt-5"])
        let claudeModels = try await ledger.availableModels(tools: [.claude])
        XCTAssertEqual(claudeModels, ["claude-sonnet-4-5"])
        let noToolModels = try await ledger.availableModels(tools: [])
        XCTAssertEqual(noToolModels, [])
    }

    // MARK: - Schema upkeep

    /// A ledger created before the harness index existed must gain it on the
    /// next open — the whole point of `CREATE INDEX IF NOT EXISTS` running on
    /// every open rather than only at create time. Dropping the index from an
    /// otherwise current database is exactly that shape, and it also proves
    /// the retained rows survive: adding an index must not take the
    /// drop-and-recreate path that a schema-version bump does.
    func testOpeningAnIndexlessDatabaseRestoresTheHarnessIndex() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("HarnessIndex")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage_events.sqlite3")

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: now, harness: .claudeCode)
            )
        ]))
        await ledger.optimizeStorage()
        XCTAssertTrue(try Self.indexNames(at: url).contains("usage_events_harness_ts_idx"))

        try Self.execute("DROP INDEX usage_events_harness_ts_idx", at: url)
        XCTAssertFalse(try Self.indexNames(at: url).contains("usage_events_harness_ts_idx"))

        // A page has to arrive indexed even if the background upkeep the
        // initializer schedules has not landed yet.
        let reopened = try UsageEventLedger(url: url)
        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let retained = try await reopened.requestPage(filter, pageSize: 10)
        XCTAssertTrue(try Self.indexNames(at: url).contains("usage_events_harness_ts_idx"))
        XCTAssertEqual(retained.rows.count, 1)
    }

    /// Index names on `usage_events`, read through a connection of the test's
    /// own so nothing has to be exposed from the actor for the assertion.
    private static func indexNames(at url: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else { throw UsageLedgerError.open }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'usage_events'",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw UsageLedgerError.statement }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) {
                names.append(String(cString: raw))
            }
        }
        return names
    }

    private static func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle
        else { throw UsageLedgerError.open }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 5_000)
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageLedgerError.statement
        }
    }
}
