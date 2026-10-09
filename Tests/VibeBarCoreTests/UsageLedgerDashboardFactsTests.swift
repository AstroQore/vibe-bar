import XCTest
@testable import VibeBarCore

/// `UsageEventLedger.dashboardFacts` / `dashboardSessionTotals` against a
/// synthetic ledger. Every id and path is made up.
final class UsageLedgerDashboardFactsTests: XCTestCase {
    /// A multiple of the 900 s slot width.
    private let t0 = Date(timeIntervalSince1970: 1_777_593_600)

    private func claude(
        _ offset: TimeInterval,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int = 0,
        model: String = "claude-sonnet-4-5",
        sidechain: Bool = false,
        message: String,
        project: String? = "/Users/example/Code/beta"
    ) -> PricedUsageEvent {
        PricedUsageEvent(
            event: CostUsageScanCache.ParsedEvent(
                date: t0.addingTimeInterval(offset),
                model: model,
                input: input,
                output: output,
                cache: cacheRead + cacheWrite,
                cacheCreation: cacheWrite,
                sessionId: "s1",
                messageId: message,
                requestId: "req-" + message,
                isSidechain: sidechain,
                harness: .claudeCode,
                projectPath: project
            ),
            costUSD: 0.01
        )
    }

    private func makeLedger() async throws -> (UsageEventLedger, URL) {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("DashboardFacts")
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/beta/s1.jsonl",
            events: [
                claude(0, input: 100, output: 50, cacheRead: 900, cacheWrite: 100, message: "m1"),
                claude(400, input: 200, output: 20, cacheRead: 0, model: "claude-haiku-4-5", sidechain: true, message: "m2", project: nil),
                claude(3_600, input: 50, output: 10, cacheRead: 2_000, message: "m3"),
            ]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .codex,
            path: "/Users/example/.codex/sessions/rollout-a.jsonl",
            events: [
                PricedUsageEvent(
                    event: CostUsageScanCache.ParsedEvent(
                        date: t0.addingTimeInterval(60),
                        model: "gpt-5",
                        input: 500,
                        output: 100,
                        cache: 1_500,
                        harness: .codex,
                        projectPath: "/Users/example/Code/alpha"
                    ),
                    costUSD: nil
                ),
            ]
        ))
        return (ledger, directory)
    }

    private var filter: UsageQueryFilter {
        UsageQueryFilter(range: DateInterval(start: t0.addingTimeInterval(-86_400), end: t0.addingTimeInterval(86_400)))
    }

    func testSlotsCarryTheFullSplitPerHarness() async throws {
        let (ledger, directory) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facts = try await ledger.dashboardFacts(filter)

        let claudeSlots = facts.slots.filter { $0.harness == .claudeCode }.sorted { $0.start < $1.start }
        XCTAssertEqual(claudeSlots.map(\.start), [Int64(t0.timeIntervalSince1970), Int64(t0.timeIntervalSince1970) + 3_600])
        XCTAssertEqual(claudeSlots.map(\.requests), [2, 1])
        XCTAssertEqual(claudeSlots[0].tokens, UsageTokenSplit(input: 300, output: 70, cacheRead: 900, cacheWrite: 100))
        XCTAssertEqual(claudeSlots[0].costMicros, 20_000)

        let codex = try XCTUnwrap(facts.slots.first { $0.harness == .codex })
        XCTAssertEqual(codex.tokens, UsageTokenSplit(input: 500, output: 100, cacheRead: 1_500, cacheWrite: 0))
        XCTAssertEqual(codex.unpriced, 1)
        XCTAssertEqual(codex.costMicros, 0)
    }

    func testDaysFollowTheRowsOwnDayKey() async throws {
        let (ledger, directory) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facts = try await ledger.dashboardFacts(filter)
        let summary = try await ledger.summary(filter)
        XCTAssertEqual(facts.days.reduce(0) { $0 + $1.requests }, summary.requests)
        XCTAssertEqual(facts.days.reduce(Int64(0)) { $0 + $1.tokens.total }, summary.realTotalTokens)
        XCTAssertEqual(facts.days.first { $0.harness == .claudeCode }?.requests, 3)
    }

    func testProjectsModelsAndPromptBuckets() async throws {
        let (ledger, directory) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facts = try await ledger.dashboardFacts(filter)

        let projects = Dictionary(uniqueKeysWithValues: facts.projects.map { ($0.key, $0) })
        XCTAssertEqual(projects["/Users/example/Code/beta"]?.requests, 2)
        XCTAssertEqual(projects["/Users/example/Code/beta"]?.tokens, 1_150 + 2_060)
        XCTAssertEqual(projects["/Users/example/Code/alpha"]?.tokens, 2_100)
        XCTAssertEqual(projects["/Users/example/Code/alpha"]?.harness, .codex)

        let models = Dictionary(uniqueKeysWithValues: facts.models.map { ($0.key, $0) })
        XCTAssertEqual(models["claude-sonnet-4-5"]?.requests, 2)
        XCTAssertEqual(models["claude-haiku-4-5"]?.requests, 1)
        XCTAssertEqual(models["gpt-5"]?.unpriced, 1)

        // Prompt = fresh + cache read + cache write, bucketed by 1 024.
        let claudeBuckets = facts.promptBuckets.filter { $0.harness == .claudeCode }.sorted { $0.bucket < $1.bucket }
        XCTAssertEqual(claudeBuckets.map(\.bucket), [0, 1, 2])
        XCTAssertEqual(claudeBuckets.map(\.maxPrompt), [200, 1_100, 2_050])
        XCTAssertEqual(facts.promptBuckets.first { $0.harness == .codex }?.bucket, 1)
        XCTAssertTrue(facts.includesRollups)
    }

    func testProjectFilterNarrowsDetailAndDropsRollups() async throws {
        let (ledger, directory) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facts = try await ledger.dashboardFacts(filter, projects: ["/Users/example/Code/alpha"])
        XCTAssertFalse(facts.includesRollups)
        XCTAssertEqual(facts.slots.map(\.harness), [.codex])
        // Request days only, and only the project's.
        XCTAssertEqual(facts.days.map(\.harness), [.codex])
        XCTAssertEqual(facts.days.first?.requests, 1)
    }

    func testSessionTotalsAreWholeSessionAndSkipSidechainForTheFirstPrompt() async throws {
        let (ledger, directory) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await ledger.dashboardSessionTotals()
        XCTAssertEqual(rows.count, 1, "Codex rows carry no session id")
        let session = try XCTUnwrap(rows.first)
        XCTAssertEqual(session.sessionID, "s1")
        XCTAssertEqual(session.harness, .claudeCode)
        XCTAssertEqual(session.requests, 3)
        XCTAssertEqual(session.tokens, UsageTokenSplit(input: 350, output: 80, cacheRead: 2_900, cacheWrite: 100))
        XCTAssertEqual(session.firstPrompt, 1_100)
        XCTAssertEqual(session.maxPrompt, 2_050)
        // t0, t0+400 and t0+3 600 fall in three different five-minute slots.
        XCTAssertEqual(session.activeSlots, 3)
        XCTAssertEqual(session.model, "claude-sonnet-4-5")
        XCTAssertEqual(session.project, "/Users/example/Code/beta")
        XCTAssertEqual(session.firstAt, t0)
        XCTAssertEqual(session.lastAt, t0.addingTimeInterval(3_600))

        var haiku = filter
        haiku.models = ["claude-haiku-4-5"]
        let ids = try await ledger.dashboardSessionIDs(haiku)
        XCTAssertEqual(ids, ["s1"])
        var gpt = filter
        gpt.models = ["gpt-5"]
        let none = try await ledger.dashboardSessionIDs(gpt)
        XCTAssertTrue(none.isEmpty)
    }
}
