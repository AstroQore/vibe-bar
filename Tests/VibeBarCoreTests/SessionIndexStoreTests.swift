import XCTest
import SQLite3
@testable import VibeBarCore

final class SessionIndexStoreTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSessionIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("session_index.sqlite3")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> SessionIndexStore {
        try SessionIndexStore(url: databaseURL)
    }

    private func summary(
        provider: SessionProvider = .claude,
        id: String = "11111111-2222-3333-4444-555555555555",
        harness: Harness? = nil,
        model: String? = nil,
        title: String? = "Wire up the session list",
        summaryText: String? = "Done.",
        projectDir: String? = "/Users/example/proj",
        lastActive: Date? = Date(timeIntervalSince1970: 1_780_000_000),
        path: String = "/Users/example/.claude/projects/proj/one.jsonl"
    ) -> SessionSummary {
        SessionSummary(
            provider: provider,
            sessionID: id,
            providerVariant: provider == .antigravity ? "cli" : nil,
            harness: harness,
            model: model,
            title: title,
            summary: summaryText,
            projectDir: projectDir,
            createdAt: Date(timeIntervalSince1970: 1_779_000_000),
            lastActiveAt: lastActive,
            sourcePath: path,
            sizeBytes: 4_096,
            messageCount: 12
        )
    }

    private func excerpts(_ texts: [String]) -> [SessionIndexStore.MessageExcerpt] {
        texts.enumerated().map {
            SessionIndexStore.MessageExcerpt(
                seq: $0.offset,
                role: $0.offset.isMultiple(of: 2) ? .user : .assistant,
                excerpt: $0.element
            )
        }
    }

    @discardableResult
    private func seed(
        _ store: SessionIndexStore,
        summary value: SessionSummary,
        messages: [String]
    ) async throws -> Int64 {
        let row = try await store.upsertSession(value)
        try await store.replaceMessages(sessionRow: row, excerpts: excerpts(messages))
        return row
    }

    // MARK: - Sessions

    func testUpsertIsIdempotentOnProviderSessionAndPath() async throws {
        let store = try makeStore()
        let first = try await store.upsertSession(summary())
        let second = try await store.upsertSession(summary(title: "Renamed"))
        XCTAssertEqual(first, second)

        let all = try await store.allSummaries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Renamed")
        XCTAssertEqual(all.first?.projectDir, "/Users/example/proj")
        XCTAssertEqual(all.first?.messageCount, 12)
        XCTAssertEqual(all.first?.sizeBytes, 4_096)
        XCTAssertEqual(all.first?.createdAt, Date(timeIntervalSince1970: 1_779_000_000))
    }

    func testTheSameSessionIDUnderTwoRootsIsTwoRows() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(path: "/Users/example/.claude/projects/p/one.jsonl"))
        try await store.upsertSession(summary(path: "/Users/example/.config/claude/projects/p/one.jsonl"))
        let count = try await store.sessionCount()
        XCTAssertEqual(count, 2)
    }

    func testSummariesComeBackMostRecentlyActiveFirst() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(
            id: "old", lastActive: Date(timeIntervalSince1970: 1_000), path: "/a"
        ))
        try await store.upsertSession(summary(
            id: "new", lastActive: Date(timeIntervalSince1970: 9_000), path: "/b"
        ))
        try await store.upsertSession(summary(id: "undated", lastActive: nil, path: "/c"))

        let ids = try await store.allSummaries().map(\.sessionID)
        XCTAssertEqual(ids, ["new", "old", "undated"])
    }

    func testProviderVariantRoundTrips() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(provider: .antigravity, path: "/conv.db"))
        let variant = try await store.allSummaries().first?.providerVariant
        XCTAssertEqual(variant, "cli")
    }

    // MARK: - Harness and model (schema v2)

    func testHarnessAndModelRoundTrip() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(
            provider: .codex,
            id: "work",
            harness: .chatgptWork,
            model: "gpt-daybreak-blue-latest",
            path: "/work.jsonl"
        ))
        let row = try await store.allSummaries().first
        XCTAssertEqual(row?.harness, .chatgptWork)
        XCTAssertEqual(row?.model, "gpt-daybreak-blue-latest")
    }

    /// Two rollouts from the same tree, told apart only by their harness —
    /// which is the whole reason the column exists.
    func testCodexAndChatGPTWorkAreSeparableInTheSameProvider() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(
            provider: .codex, id: "plain", harness: .codex, path: "/plain.jsonl"
        ))
        try await store.upsertSession(summary(
            provider: .codex, id: "work", harness: .chatgptWork, path: "/work.jsonl"
        ))

        let onlyWork = try await store.summaryPage(harnesses: [.chatgptWork])
        XCTAssertEqual(onlyWork.summaries.map(\.sessionID), ["work"])
        XCTAssertEqual(onlyWork.totalCount, 1)

        let counts = try await store.harnessCounts()
        XCTAssertEqual(counts[.codex], 1)
        XCTAssertEqual(counts[.chatgptWork], 1)
        XCTAssertNil(counts[.cursor])
    }

    /// A summary that arrived without a harness is still filterable: the
    /// write substitutes the provider's default rather than storing null.
    func testAMissingHarnessIsStoredAsTheProvidersDefault() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(provider: .grok, id: "grok", path: "/grok.json"))
        let stored = try await store.allSummaries().first?.harness
        let counts = try await store.harnessCounts()
        let page = try await store.summaryPage(harnesses: [.grokBuild])
        XCTAssertEqual(stored, .grokBuild)
        XCTAssertEqual(counts[.grokBuild], 1)
        XCTAssertEqual(page.totalCount, 1)
    }

    func testEveryProviderDefaultsToADistinctHarness() async throws {
        let store = try makeStore()
        for provider in SessionProvider.allCases {
            try await store.upsertSession(summary(
                provider: provider, id: provider.rawValue, path: "/\(provider.rawValue)"
            ))
        }
        let counts = try await store.harnessCounts()
        XCTAssertEqual(counts.values.reduce(0, +), SessionProvider.allCases.count)
        XCTAssertEqual(counts.count, SessionProvider.allCases.count,
                       "two providers must not collapse onto one default harness")
    }

    func testAnEmptyHarnessFilterSelectsNothing() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary())
        let page = try await store.summaryPage(harnesses: [])
        let hits = try await store.search(text: "session", harnesses: [])
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertTrue(hits.isEmpty)
    }

    func testSearchIsNarrowedByHarness() async throws {
        let store = try makeStore()
        try await seed(
            store,
            summary: summary(provider: .codex, id: "plain", harness: .codex, path: "/plain.jsonl"),
            messages: ["Refactoring the transcript indexer"]
        )
        try await seed(
            store,
            summary: summary(provider: .codex, id: "work", harness: .chatgptWork, path: "/work.jsonl"),
            messages: ["Refactoring the transcript indexer"]
        )

        let all = try await store.search(text: "transcript")
        XCTAssertEqual(all.count, 2)
        let scoped = try await store.search(text: "transcript", harnesses: [.chatgptWork])
        XCTAssertEqual(scoped.map(\.summary.sessionID), ["work"])
        XCTAssertNotNil(scoped.first?.snippet, "the row id column moved; the snippet must follow it")
        XCTAssertEqual(scoped.first?.matchedSeq, 0)
    }

    /// Metadata hits come back through the same column layout as body hits,
    /// so a bad index would show up as a decoded-but-wrong summary.
    func testMetadataHitsStillDecodeTheWholeRow() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(
            provider: .cursor, id: "cursor", harness: .cursor,
            model: "gpt-5.3-codex-xhigh", title: "Polish the showcase", path: "/store.db"
        ))
        let hit = try await store.search(text: "Polish").first
        XCTAssertEqual(hit?.summary.harness, .cursor)
        XCTAssertEqual(hit?.summary.model, "gpt-5.3-codex-xhigh")
        XCTAssertNil(hit?.snippet)
        XCTAssertNil(hit?.matchedSeq)
    }

    func testSummaryPageFiltersOrdersAndBoundsTheRead() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(
            provider: .claude, id: "claude-old", projectDir: "/Users/example/alpha",
            lastActive: Date(timeIntervalSince1970: 1_000), path: "/claude-old"
        ))
        try await store.upsertSession(summary(
            provider: .claude, id: "claude-new", projectDir: "/Users/example/beta",
            lastActive: Date(timeIntervalSince1970: 3_000), path: "/claude-new"
        ))
        try await store.upsertSession(summary(
            provider: .codex, id: "codex", projectDir: "/Users/example/gamma",
            lastActive: Date(timeIntervalSince1970: 4_000), path: "/codex"
        ))

        let first = try await store.summaryPage(
            providers: [.claude],
            since: Date(timeIntervalSince1970: 1_500),
            order: .recentFirst,
            offset: 0,
            limit: 1
        )
        XCTAssertEqual(first.totalCount, 1)
        XCTAssertEqual(first.summaries.map(\.sessionID), ["claude-new"])
        XCTAssertEqual(first.limit, 1)

        let oldest = try await store.summaryPage(order: .oldestFirst, offset: 1, limit: 2)
        XCTAssertEqual(oldest.totalCount, 3)
        XCTAssertEqual(oldest.summaries.map(\.sessionID), ["claude-new", "codex"])

        let counts = try await store.providerCounts()
        XCTAssertEqual(counts[.claude], 2)
        XCTAssertEqual(counts[.codex], 1)
        XCTAssertNil(counts[.grok])
    }

    // MARK: - Search

    func testTrigramSearchMatchesAnEnglishSubstring() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: [
            "Refactoring the transcript indexer today",
            "Understood, starting with the store."
        ])

        let hits = try await store.search(text: "script index")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.matchedSeq, 0)
        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertTrue(snippet.contains("<b>"), snippet)
        XCTAssertTrue(snippet.lowercased().contains("script index"), snippet)
    }

    func testTrigramSearchMatchesAChineseSubstring() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: [
            "帮我把会话管理器的中文内容也索引进去",
            "好的，已经完成了索引。"
        ])

        let hits = try await store.search(text: "会话管理")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.matchedSeq, 0)
        XCTAssertTrue(try XCTUnwrap(hits.first?.snippet).contains("<b>会话管理</b>"))

        // Three characters is the shortest a trigram index can answer,
        // and it still matches mid-sentence.
        let shortest = try await store.search(text: "中文内")
        XCTAssertEqual(shortest.count, 1)
    }

    func testTwoCharacterQueriesFallBackToLikeAndStillHit() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: ["帮我把中文内容索引进去", "好的"])

        let hits = try await store.search(text: "中文")
        XCTAssertEqual(hits.count, 1)
        // The LIKE path has no FTS snippet, so the excerpt stands in.
        XCTAssertEqual(hits.first?.snippet, "帮我把中文内容索引进去")
        XCTAssertEqual(hits.first?.matchedSeq, 0)

        let miss = try await store.search(text: "zz")
        XCTAssertTrue(miss.isEmpty)
    }

    func testFTSOperatorsInAQueryAreTreatedAsLiteralText() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: [
            "the \"quoted\" NEAR* value: a-b^c (paren)",
            "ack"
        ])

        // None of these may reach the MATCH parser as syntax: a throw
        // here is a query-escaping bug, not a missing row.
        for query in ["\"quoted\"", "NEAR*", "value: a-b^c", "a OR b", "* * *", "AND", "^", "\""] {
            let hits = try await store.search(text: query)
            XCTAssertLessThanOrEqual(hits.count, 1, "unexpected extra hits for \(query)")
        }
        let quoted = try await store.search(text: "\"quoted\"")
        XCTAssertEqual(quoted.count, 1)
        let paren = try await store.search(text: "(paren)")
        XCTAssertEqual(paren.count, 1)
        let near = try await store.search(text: "NEAR*")
        XCTAssertEqual(near.count, 1)
    }

    func testWildcardsInAMetadataQueryAreEscaped() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(title: "100% done", path: "/a"))
        try await store.upsertSession(summary(id: "other", title: "nothing here", path: "/b"))

        let exact = try await store.search(text: "100% done")
        XCTAssertEqual(exact.map(\.summary.title), ["100% done"])
        // A bare wildcard is a literal percent sign, so it finds the one
        // row that really contains one — not every row in the table.
        let wildcard = try await store.search(text: "%")
        XCTAssertEqual(wildcard.map(\.summary.title), ["100% done"])
        let underscore = try await store.search(text: "_")
        XCTAssertTrue(underscore.isEmpty)
    }

    func testSearchIsFilteredByProviderAndCappedByLimit() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(provider: .claude, path: "/a"),
                       messages: ["shared needle text"])
        try await seed(store, summary: summary(provider: .codex, id: "codex", path: "/b"),
                       messages: ["shared needle text"])

        let all = try await store.search(text: "needle")
        XCTAssertEqual(all.count, 2)
        let codexOnly = try await store.search(text: "needle", providers: [.codex])
        XCTAssertEqual(codexOnly.map(\.summary.provider), [.codex])
        let capped = try await store.search(text: "needle", limit: 1)
        XCTAssertEqual(capped.count, 1)
        let noProviders = try await store.search(text: "needle", providers: [])
        XCTAssertTrue(noProviders.isEmpty)
        let blank = try await store.search(text: "   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testOneHitPerSessionEvenWhenSeveralMessagesMatch() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: [
            "needle one", "needle two", "needle three"
        ])
        let hits = try await store.search(text: "needle")
        XCTAssertEqual(hits.count, 1)
    }

    func testMetadataMatchesEvenWithoutBodyIndexing() async throws {
        let store = try makeStore()
        try await store.upsertSession(summary(title: "Wire up the session list"))

        let hits = try await store.search(text: "session list")
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits.first?.snippet)
        XCTAssertNil(hits.first?.matchedSeq)
        let byProject = try await store.search(text: "example/proj")
        XCTAssertEqual(byProject.count, 1)
    }

    // MARK: - Cascades and lifecycle

    func testDeletingASessionClearsItsMessagesAndFTSRows() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: ["needle in the transcript"])
        let seeded = try await store.messageCount()
        XCTAssertEqual(seeded, 1)

        try await store.removeSessions(sourcePathIn: [summary().sourcePath])

        let sessions = try await store.sessionCount()
        let messages = try await store.messageCount()
        let hits = try await store.search(text: "needle")
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(messages, 0)
        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(try ftsRowCount(), 0)
    }

    func testReplacingMessagesRetiresTheOldFTSRows() async throws {
        let store = try makeStore()
        let row = try await seed(store, summary: summary(), messages: ["first haystack text"])
        try await store.replaceMessages(sessionRow: row, excerpts: excerpts(["second haystack text"]))

        let stale = try await store.search(text: "first hay")
        let fresh = try await store.search(text: "second hay")
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(try ftsRowCount(), 1)
    }

    func testPruneMissingDropsVanishedFilesAndTheirSessions() async throws {
        let store = try makeStore()
        let kept = try await seed(store, summary: summary(path: "/a"), messages: ["kept text"])
        let gone = try await seed(store, summary: summary(id: "gone", path: "/b"), messages: ["gone text"])
        try await store.saveFileCursor(
            pathHash: "hash-a", path: "/a", provider: .claude,
            mtimeNanos: 1, size: 2, sessionRow: kept
        )
        try await store.saveFileCursor(
            pathHash: "hash-b", path: "/b", provider: .claude,
            mtimeNanos: 3, size: 4, sessionRow: gone
        )

        let pruned = try await store.pruneMissing(existingPathHashes: ["hash-a"])
        XCTAssertEqual(pruned, 1)

        let remaining = try await store.allSummaries().map(\.sessionID)
        let cursor = try await store.fileCursor(pathHash: "hash-b")
        let hits = try await store.search(text: "gone text")
        XCTAssertEqual(remaining, ["11111111-2222-3333-4444-555555555555"])
        XCTAssertNil(cursor)
        XCTAssertTrue(hits.isEmpty)
    }

    func testFileCursorRoundTrip() async throws {
        let store = try makeStore()
        let missing = try await store.fileCursor(pathHash: "hash")
        XCTAssertNil(missing)

        try await store.saveFileCursor(
            pathHash: "hash", path: "/a", provider: .grok,
            mtimeNanos: 1_234_567_890_123, size: 99, sessionRow: nil
        )
        let cursor = try await store.fileCursor(pathHash: "hash")
        XCTAssertEqual(cursor?.mtimeNanos, 1_234_567_890_123)
        XCTAssertEqual(cursor?.size, 99)
        XCTAssertNil(cursor?.sessionRow)

        try await store.saveFileCursor(
            pathHash: "hash", path: "/a", provider: .grok,
            mtimeNanos: 2, size: 3, sessionRow: nil
        )
        let updated = try await store.fileCursor(pathHash: "hash")
        XCTAssertEqual(updated?.mtimeNanos, 2)
    }

    func testDropBodyIndexKeepsSessionsSearchableByMetadata() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: ["needle in the transcript"])

        try await store.dropBodyIndex()

        let sessions = try await store.sessionCount()
        let messages = try await store.messageCount()
        let body = try await store.search(text: "needle")
        let metadata = try await store.search(text: "session list")
        XCTAssertEqual(sessions, 1)
        XCTAssertEqual(messages, 0)
        XCTAssertEqual(try ftsRowCount(), 0)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(metadata.count, 1)
    }

    func testBodyIndexingModeAndCursorResetRoundTrip() async throws {
        let store = try makeStore()
        let unset = try await store.bodyIndexingMode()
        XCTAssertNil(unset)

        let row = try await seed(store, summary: summary(), messages: ["needle"])
        try await store.saveFileCursor(
            pathHash: "hash", path: "/a", provider: .claude,
            mtimeNanos: 1, size: 2, sessionRow: row
        )
        try await store.setBodyIndexingMode(false)
        let off = try await store.bodyIndexingMode()
        XCTAssertEqual(off, false)

        try await store.resetFileCursors()

        // Cursors are gone; the sessions they produced are not.
        let cursor = try await store.fileCursor(pathHash: "hash")
        let sessions = try await store.sessionCount()
        XCTAssertNil(cursor)
        XCTAssertEqual(sessions, 1)

        try await store.setBodyIndexingMode(true)
        let on = try await store.bodyIndexingMode()
        XCTAssertEqual(on, true)
    }

    func testEraseAllEmptiesEveryTableButKeepsTheSchema() async throws {
        let store = try makeStore()
        try await seed(store, summary: summary(), messages: ["needle"])
        try await store.saveFileCursor(
            pathHash: "hash", path: "/a", provider: .claude, mtimeNanos: 1, size: 2, sessionRow: nil
        )

        try await store.eraseAll()

        let sessions = try await store.sessionCount()
        let messages = try await store.messageCount()
        let cursor = try await store.fileCursor(pathHash: "hash")
        let mode = try await store.bodyIndexingMode()
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(messages, 0)
        XCTAssertNil(cursor)
        XCTAssertNil(mode)

        // Still writable: the tables are empty, not gone.
        try await store.upsertSession(summary())
        let rebuilt = try await store.sessionCount()
        XCTAssertEqual(rebuilt, 1)
    }

    // MARK: - Schema versioning

    /// v2 is what introduced `harness` / `model`. A v1 database therefore has
    /// to be dropped rather than adopted — its rows have no harness at all,
    /// and a filter over them would silently show nothing.
    func testAV1DatabaseIsRebuiltRatherThanAdopted() async throws {
        do {
            let store = try makeStore()
            try await seed(store, summary: summary(), messages: ["needle"])
        }
        try setUserVersion(1)

        let rebuilt = try makeStore()
        let remaining = try await rebuilt.sessionCount()
        XCTAssertEqual(SessionIndexStore.schemaVersion, 2)
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(try userVersion(), 2)

        try await rebuilt.upsertSession(summary(harness: .claudeCode, model: "claude-fable-5"))
        let model = try await rebuilt.allSummaries().first?.model
        XCTAssertEqual(model, "claude-fable-5")
    }

    func testASchemaVersionMismatchDropsAndRebuilds() async throws {
        do {
            let store = try makeStore()
            try await seed(store, summary: summary(), messages: ["needle"])
            let seeded = try await store.sessionCount()
            XCTAssertEqual(seeded, 1)
        }
        try setUserVersion(SessionIndexStore.schemaVersion + 1)

        let rebuilt = try makeStore()
        let sessions = try await rebuilt.sessionCount()
        let messages = try await rebuilt.messageCount()
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(messages, 0)
        XCTAssertEqual(try userVersion(), SessionIndexStore.schemaVersion)

        // The rebuilt schema still has working triggers.
        try await seed(rebuilt, summary: summary(), messages: ["needle again"])
        let hits = try await rebuilt.search(text: "needle")
        XCTAssertEqual(hits.count, 1)
    }

    func testReopeningAtTheCurrentVersionKeepsEveryRow() async throws {
        do {
            let store = try makeStore()
            try await seed(store, summary: summary(), messages: ["needle"])
        }
        let reopened = try makeStore()
        let sessions = try await reopened.sessionCount()
        let hits = try await reopened.search(text: "needle")
        XCTAssertEqual(sessions, 1)
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: - Raw SQLite helpers

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle
        else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close_v2(handle) }
        return try body(handle)
    }

    private func scalar(_ sql: String) throws -> Int {
        try withDatabase { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
            else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func ftsRowCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM session_fts")
    }

    private func userVersion() throws -> Int {
        try scalar("PRAGMA user_version")
    }

    private func setUserVersion(_ version: Int) throws {
        try withDatabase { handle in
            guard sqlite3_exec(
                handle, "PRAGMA user_version = \(version)", nil, nil, nil
            ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
