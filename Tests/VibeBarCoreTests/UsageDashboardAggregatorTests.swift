import XCTest
@testable import VibeBarCore

/// The aggregator end to end: a synthetic ledger, two session files on
/// disk, a throwaway structure sidecar and activity cache. Checks that the
/// first snapshot needs no parse, that one enrichment pass fills both caches,
/// and that the next snapshot reads them.
final class UsageDashboardAggregatorTests: XCTestCase {
    private struct FixedSessions: UsageDashboardSessionSource {
        let rows: [SessionSummary]
        func sessions(activeSince since: Date) async -> [SessionSummary] {
            rows.filter { ($0.lastActiveAt ?? .distantFuture) >= since }
        }
        func totalSessionCount() async -> Int { rows.count }
    }

    /// A sidecar with a tiny size cap and nothing in it.
    private actor TinyStructures: UsageDashboardStructureSource {
        nonisolated let maxFileBytes: Int64 = 1_024
        private(set) var filled: [String] = []
        func freshStats(for summaries: [SessionSummary]) async -> [String: SessionStats] { [:] }
        func fill(_ summaries: [SessionSummary]) async -> Int {
            filled += summaries.map(\.sourcePath)
            return 0
        }
    }

    func testASessionAboveTheStructureCapIsCountedAsSkipped() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let directory = try SessionStructureFixtures.temporaryDirectory("AggregatorCap")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Larger than the structure cap, far below the activity cap.
        let lines = codexRollout() + Array(repeating: codexRollout()[3], count: 40)
        let url = try SessionStructureFixtures.write(lines, to: directory.appendingPathComponent("codex/rollout-big.jsonl"))
        let start = ISO8601DateFormatter().date(from: "2026-05-01T10:00:00Z")!
        let codex = SessionSummary(
            provider: .codex, sessionID: SessionStructureFixtures.codexThreadID, harness: .codex,
            createdAt: start, lastActiveAt: start.addingTimeInterval(600),
            // The index still has the size from before the file grew.
            sourcePath: url.path, sizeBytes: 512
        )
        let structures = TinyStructures()
        let aggregator = UsageDashboardAggregator(
            ledger: nil,
            sessions: FixedSessions(rows: [codex]),
            structures: structures,
            activity: SessionActivityStore(url: nil, calendar: utc),
            calendar: utc
        )
        let now = start.addingTimeInterval(3_600)
        let query = UsageDashboardQuery(range: .week, interval: await aggregator.interval(for: .week, harnesses: nil, now: now))
        let report = await aggregator.enrich(query, now: now)
        XCTAssertFalse(report.hasMore, "nothing the fill can still do")
        let snapshot = await aggregator.snapshot(query, now: now)
        XCTAssertEqual(snapshot.coverage.analyzable, 1)
        XCTAssertEqual(snapshot.coverage.activityReady, 1, "the activity scan reaches it")
        XCTAssertEqual(snapshot.coverage.structureReady, 0)
        XCTAssertEqual(snapshot.coverage.skipped, 1, "its structure never will, so it is skipped, not pending")
        XCTAssertTrue(snapshot.coverage.isComplete)
        XCTAssertNil(snapshot.recentSessions.first?.tokens)
    }

    func testProjectSpellingsFoldIntoOneProject() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("AggregatorProjects")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = ISO8601DateFormatter().date(from: "2026-05-01T10:00:00Z")!
        func event(_ offset: TimeInterval, session: String, project: String, harness: Harness, id: String) -> PricedUsageEvent {
            PricedUsageEvent(
                event: CostUsageScanCache.ParsedEvent(
                    date: start.addingTimeInterval(offset), model: "claude-sonnet-4-5", input: 100, output: 10, cache: 0,
                    sessionId: session, messageId: id, requestId: id, harness: harness, projectPath: project
                ),
                costUSD: 0.01
            )
        }
        // Devin keeps its working directory as written (here, a trailing
        // slash); a Claude session ran in an agent worktree of the same repo.
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .devin, path: "/Users/example/.devin/sessions.db",
            events: [event(0, session: "dev-1", project: "/Users/example/Code/beta/", harness: .devin, id: "d1")]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude, path: "/Users/example/.claude/projects/beta/cl-1.jsonl",
            events: [
                event(60, session: "cl-1", project: "/Users/example/Code/beta/.agents/worktrees/fix", harness: .claudeCode, id: "c1"),
                event(120, session: "cl-1", project: "/Users/example/Code/alpha", harness: .claudeCode, id: "c2"),
            ]
        ))
        let devin = SessionSummary(
            provider: .devin, sessionID: "dev-1", harness: .devin, projectDir: "/Users/example/Code/beta/",
            createdAt: start, lastActiveAt: start.addingTimeInterval(30), sourcePath: "/Users/example/.devin/dev-1"
        )
        let claude = SessionSummary(
            provider: .claude, sessionID: "cl-1", harness: .claudeCode,
            projectDir: "/Users/example/Code/beta/.agents/worktrees/fix",
            createdAt: start, lastActiveAt: start.addingTimeInterval(130), sourcePath: "/Users/example/.claude/cl-1.jsonl"
        )
        let aggregator = UsageDashboardAggregator(
            ledger: ledger, sessions: FixedSessions(rows: [devin, claude]), structures: nil, activity: nil
        )
        let now = start.addingTimeInterval(3_600)
        let interval = await aggregator.interval(for: .week, harnesses: nil, now: now)

        let all = await aggregator.snapshot(UsageDashboardQuery(range: .week, interval: interval), now: now)
        XCTAssertEqual(all.options.projects.map(\.path), ["/Users/example/Code/beta", "/Users/example/Code/alpha"])
        XCTAssertEqual(all.projects.rows.first?.id, "/Users/example/Code/beta")
        XCTAssertEqual(all.projects.rows.first?.tokens, 220)
        XCTAssertEqual(all.projects.rows.first?.sessions, 2)
        XCTAssertEqual(all.hero.projectCount, 2)

        let beta = UsageDashboardQuery(range: .week, interval: interval, project: "/Users/example/Code/beta")
        let raws = await aggregator.ledgerProjects(for: beta)
        XCTAssertEqual(Set(raws ?? []), ["/Users/example/Code/beta", "/Users/example/Code/beta/", "/Users/example/Code/beta/.agents/worktrees/fix"])
        let narrowed = await aggregator.snapshot(beta, now: now)
        XCTAssertEqual(narrowed.hero.requests, 2, "both spellings' rows, not alpha's")
        XCTAssertEqual(narrowed.hero.tokens.total, 220)
        XCTAssertEqual(Set(narrowed.recentSessions.map(\.summary.sessionID)), ["dev-1", "cl-1"])
        let page = try await ledger.requestPage(beta.ledgerFilter, projects: raws, pageSize: 10)
        XCTAssertEqual(page.rows.count, 2)
    }

    private func codexRollout() -> [String] {
        let builder = CodexRolloutBuilder()
        builder.meta()
            .taskStarted("t1")
            .turnContext(model: "gpt-5", turnID: "t1")
            .prompt("Tidy the parser", turnID: "t1")
            .raw(#"{"timestamp":"2026-05-01T10:00:05.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","name":"exec","input":"ls","call_id":"c1","status":"completed"}}"#)
            .raw(#"{"timestamp":"2026-05-01T10:00:06.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"ok"}}"#)
            .tokenCount(input: 12_000, cached: 8_000, output: 500)
            .assistant("Done.")
            .taskComplete("t1")
        return builder.lines
    }

    private func claudeLog() -> [String] {
        let builder = ClaudeLogBuilder()
        builder.prompt("Check the tests")
        builder.assistant(messageID: "msg_1", blocks: [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "swift test"]]])
        builder.toolResult(id: "toolu_1", content: "ok")
        builder.assistant(messageID: "msg_2", blocks: [["type": "text", "text": "All green."]])
        return builder.lines
    }

    func testFirstSnapshotNeedsNoParseAndEnrichmentFillsTheCaches() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let directory = try SessionStructureFixtures.temporaryDirectory("Aggregator")
        defer { try? FileManager.default.removeItem(at: directory) }

        let codexURL = try SessionStructureFixtures.write(codexRollout(), to: directory.appendingPathComponent("codex/rollout-a.jsonl"))
        let claudeURL = try SessionStructureFixtures.write(claudeLog(), to: directory.appendingPathComponent("claude/beta.jsonl"))
        let start = ISO8601DateFormatter().date(from: "2026-05-01T10:00:00Z")!
        let codex = SessionSummary(
            provider: .codex, sessionID: SessionStructureFixtures.codexThreadID, harness: .codex,
            title: "Tidy the parser", projectDir: "/Users/example/project",
            createdAt: start, lastActiveAt: start.addingTimeInterval(600), sourcePath: codexURL.path, sizeBytes: 4_096
        )
        let claude = SessionSummary(
            provider: .claude, sessionID: SessionStructureFixtures.claudeSessionID, harness: .claudeCode,
            title: "Check the tests", projectDir: "/Users/example/project",
            createdAt: start, lastActiveAt: start.addingTimeInterval(300), sourcePath: claudeURL.path, sizeBytes: 4_096
        )

        let (ledger, ledgerDirectory) = try UsageLedgerFixtures.makeLedger("Aggregator")
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: claudeURL.path,
            events: [
                UsageLedgerFixtures.priced(UsageLedgerFixtures.event(
                    date: start.addingTimeInterval(4), model: "claude-sonnet-4-5", input: 10, output: 50,
                    cache: 1_100, cacheCreation: 100, sessionId: SessionStructureFixtures.claudeSessionID,
                    messageId: "msg_1", requestId: "req_1", isSidechain: false, harness: .claudeCode
                ), costUSD: 0.02),
            ]
        ))

        let store = SessionStructureStore(url: directory.appendingPathComponent("structure.sqlite3"))
        let aggregator = UsageDashboardAggregator(
            ledger: ledger,
            sessions: FixedSessions(rows: [codex, claude]),
            structures: SessionStructureDashboardSource(store: store, service: SessionStructureService(store: store)),
            activity: SessionActivityStore(url: directory.appendingPathComponent("activity.sqlite3"), calendar: utc),
            calendar: utc
        )
        let now = start.addingTimeInterval(3_600)
        let interval = await aggregator.interval(for: .week, harnesses: nil, now: now)
        let query = UsageDashboardQuery(range: .week, interval: interval)

        let before = await aggregator.snapshot(query, now: now)
        XCTAssertEqual(before.hero.sessions, 2)
        XCTAssertEqual(before.hero.requests, 1)
        XCTAssertEqual(before.coverage.structureReady, 0)
        XCTAssertEqual(before.coverage.activityReady, 0)
        XCTAssertTrue(before.tools.rows.isEmpty)
        let claudeBefore = try XCTUnwrap(before.recentSessions.first { $0.harness == .claudeCode })
        XCTAssertEqual(claudeBefore.tokens?.total, 1_160, "the ledger's session total stands in until the sidecar has a row")
        XCTAssertNil(before.recentSessions.first { $0.harness == .codex }?.tokens, "Codex rows carry no session id")

        let report = await aggregator.enrich(query, now: now)
        XCTAssertTrue(report.changed)
        let again = await aggregator.enrich(query, now: now)
        XCTAssertFalse(again.changed, "a second pass finds nothing to do")

        let after = await aggregator.snapshot(query, now: now)
        XCTAssertEqual(after.coverage.structureReady, 2)
        XCTAssertEqual(after.coverage.activityReady, 2)
        let codexRow = try XCTUnwrap(after.recentSessions.first { $0.harness == .codex })
        XCTAssertEqual(codexRow.tokens?.total, 12_500)
        XCTAssertEqual(codexRow.toolCalls, 1)
        XCTAssertEqual(codexRow.model, "gpt-5")
        XCTAssertNotNil(codexRow.costMicros, "Codex session cost comes from the sidecar's estimate")
        XCTAssertEqual(Set(after.tools.rows.map(\.name)), ["exec", "Bash"])
        let claudeAfter = try XCTUnwrap(after.recentSessions.first { $0.harness == .claudeCode })
        XCTAssertEqual(claudeAfter.tokens?.total, 1_160, "one source per harness: parsing the log does not move the figure")
        XCTAssertEqual(claudeAfter.tokenSource, .ledger)
        let codexHealth = try XCTUnwrap(after.health.first { $0.harness == .codex })
        XCTAssertEqual(codexHealth.startSize, 12_000)
        XCTAssertEqual(codexHealth.contextWindow, 272_000)

        // Narrowing to one harness keeps every chip.
        let claudeOnly = UsageDashboardQuery(range: .week, interval: interval, harnesses: [.claudeCode])
        let narrowed = await aggregator.snapshot(claudeOnly, now: now)
        XCTAssertEqual(narrowed.recentSessions.map(\.harness), [.claudeCode])
        XCTAssertEqual(Set(narrowed.options.harnesses.map(\.harness)), [.codex, .claudeCode])

        let nothing = await aggregator.snapshot(UsageDashboardQuery(range: .week, interval: interval, harnesses: []), now: now)
        XCTAssertEqual(nothing.hero.sessions, 0)
    }
}
