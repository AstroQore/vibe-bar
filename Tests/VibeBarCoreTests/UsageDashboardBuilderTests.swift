import XCTest
@testable import VibeBarCore

/// Every card's numbers, from hand-built inputs: a synthetic ledger reading,
/// three index sessions, one structure row and two activity tallies. All in
/// UTC so the clock-based cards do not depend on the machine's time zone.
final class UsageDashboardBuilderTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func ts(_ iso: String) -> Int64 { Int64(date(iso).timeIntervalSince1970) }

    private var sessionA: SessionSummary {
        SessionSummary(
            provider: .codex, sessionID: "codex-a", harness: .codex, model: "gpt-5", title: "Alpha refactor",
            projectDir: "/Users/example/Code/alpha",
            createdAt: date("2026-05-04T08:50:00Z"), lastActiveAt: date("2026-05-04T10:00:00Z"),
            sourcePath: "/Users/example/.codex/sessions/a.jsonl"
        )
    }

    private var sessionB: SessionSummary {
        SessionSummary(
            provider: .claude, sessionID: "claude-b", harness: .claudeCode, title: "Beta fix",
            projectDir: "/Users/example/Code/beta/.claude/worktrees/x",
            createdAt: date("2026-05-04T09:10:00Z"), lastActiveAt: date("2026-05-05T14:40:00Z"),
            sourcePath: "/Users/example/.claude/projects/beta/claude-b.jsonl"
        )
    }

    private var sessionC: SessionSummary {
        SessionSummary(
            provider: .grok, sessionID: "grok-c", harness: .grokBuild, title: "Grok notes",
            createdAt: date("2026-05-06T10:00:00Z"), lastActiveAt: date("2026-05-06T10:30:00Z"),
            sourcePath: "/Users/example/.grok/sessions/c/updates.jsonl", messageCount: 12
        )
    }

    private var oldSession: SessionSummary {
        SessionSummary(
            provider: .codex, sessionID: "codex-old", harness: .codex,
            createdAt: date("2026-04-20T08:00:00Z"), lastActiveAt: date("2026-04-25T08:00:00Z"),
            sourcePath: "/Users/example/.codex/sessions/old.jsonl"
        )
    }

    private func inputs(harnesses: [Harness]? = nil, model: String? = nil, project: String? = nil) -> UsageDashboardInputs {
        let interval = DateInterval(start: date("2026-05-01T00:00:00Z"), end: date("2026-05-07T12:00:00Z"))
        var facts = UsageLedgerDashboardFacts()
        facts.slots = [
            .init(start: ts("2026-05-04T09:00:00Z"), harness: .codex, requests: 3,
                  tokens: UsageTokenSplit(input: 1_000, output: 200, cacheRead: 3_000), costMicros: 50_000, unpriced: 0),
            .init(start: ts("2026-05-04T09:15:00Z"), harness: .claudeCode, requests: 2,
                  tokens: UsageTokenSplit(input: 100, output: 50, cacheRead: 900, cacheWrite: 100), costMicros: 20_000, unpriced: 0),
            .init(start: ts("2026-05-05T14:30:00Z"), harness: .claudeCode, requests: 1,
                  tokens: UsageTokenSplit(input: 200, output: 100), costMicros: 0, unpriced: 1),
        ]
        // Request rows by their own `day` key (as the ledger reads them) and
        // one rollup day; the ledger's predicates already bound both.
        facts.days = [
            .init(day: "2026-05-04", harness: .codex, requests: 3,
                  tokens: UsageTokenSplit(input: 1_000, output: 200, cacheRead: 3_000), costMicros: 50_000, unpriced: 0),
            .init(day: "2026-05-04", harness: .claudeCode, requests: 2,
                  tokens: UsageTokenSplit(input: 100, output: 50, cacheRead: 900, cacheWrite: 100), costMicros: 20_000, unpriced: 0),
            .init(day: "2026-05-05", harness: .claudeCode, requests: 1,
                  tokens: UsageTokenSplit(input: 200, output: 100), costMicros: 0, unpriced: 1),
            .init(day: "2026-05-01", harness: .codex, requests: 10,
                  tokens: UsageTokenSplit(input: 5_000, output: 1_000), costMicros: 100_000, unpriced: 0),
        ]
        facts.projects = [
            .init(key: "/Users/example/Code/alpha", harness: .codex, requests: 3, tokens: 4_200, costMicros: 50_000, unpriced: 0),
            .init(key: "/Users/example/Code/beta", harness: .claudeCode, requests: 3, tokens: 1_450, costMicros: 20_000, unpriced: 1),
        ]
        facts.models = [
            .init(key: "gpt-5", harness: .codex, requests: 13, tokens: 10_200, costMicros: 150_000, unpriced: 0),
            .init(key: "claude-sonnet-4-5", harness: .claudeCode, requests: 3, tokens: 1_450, costMicros: 20_000, unpriced: 1),
        ]
        facts.promptBuckets = [
            .init(harness: .codex, bucket: 3, requests: 2, maxPrompt: 4_000),
            .init(harness: .codex, bucket: 10, requests: 1, maxPrompt: 10_500),
            .init(harness: .claudeCode, bucket: 0, requests: 3, maxPrompt: 1_000),
        ]
        facts.detailFloorDay = "2026-05-01"

        let ledgerB = UsageLedgerDashboardFacts.SessionRow(
            sessionID: "claude-b", harness: .claudeCode, requests: 3,
            firstAt: date("2026-05-04T09:15:00Z"), lastAt: date("2026-05-05T14:31:00Z"),
            tokens: UsageTokenSplit(input: 300, output: 150, cacheRead: 900, cacheWrite: 100),
            costMicros: 20_000, unpriced: 1, firstPrompt: 1_000, maxPrompt: 1_100, activeSlots: 2,
            model: "claude-sonnet-4-5", project: "/Users/example/Code/beta"
        )
        var statsA = SessionStats(
            promptCount: 4, turnCount: 4, toolCallCount: 30, failedToolCount: 3, models: ["gpt-5"],
            totalUsage: SessionStructure.TokenUsage(input: 1_000, cacheRead: 3_000, output: 200),
            totalTokens: 4_200, estimatedCostUSD: 0.05, durationMs: 4_200_000
        )
        statsA.modelUsage = [SessionModelUsage(model: "gpt-5", usage: statsA.totalUsage, costUSD: 0.05)]
        let tallyA = SessionActivityTally(
            days: ["2026-05-04": .init(tools: ["exec": 20, "js": 10], skills: ["alpha-skill": 2])],
            skillLastUsed: ["alpha-skill": date("2026-05-04T09:30:00Z")],
            firstPromptTokens: 3_500, maxPromptTokens: 10_500, requests: 3, contextWindow: 272_000,
            activeSlots: 6, activeDays: ["2026-05-04"]
        )
        let tallyB = SessionActivityTally(
            days: ["2026-05-04": .init(tools: ["Bash": 5, "Read": 5], skills: ["alpha-skill": 1, "beta-skill": 3])],
            activeSlots: 2, activeDays: ["2026-05-04", "2026-05-05"]
        )
        return UsageDashboardInputs(
            query: UsageDashboardQuery(range: .week, interval: interval, harnesses: harnesses, model: model, project: project),
            now: interval.end,
            calendar: utc,
            ledger: facts,
            ledgerSessions: [ledgerB],
            ledgerSessionIDsInQuery: model == nil ? [] : ["claude-b"],
            sessions: [sessionA, sessionB, sessionC, oldSession],
            structures: [sessionA.sourcePath: statsA],
            activity: [sessionA.sourcePath: tallyA, sessionB.sourcePath: tallyB],
            availableModels: ["claude-sonnet-4-5", "gpt-5"],
            projectOptions: ["/Users/example/Code/alpha": 4_200, "/Users/example/Code/beta": 1_450]
        )
    }

    func testHero() {
        let hero = UsageDashboardBuilder.build(inputs()).hero
        XCTAssertEqual(hero.sessions, 3)
        XCTAssertEqual(hero.medianSessionTokens, 2_825)
        XCTAssertEqual(hero.p90SessionTokens, 3_925)
        // Request days plus the one rollup day.
        XCTAssertEqual(hero.tokens, UsageTokenSplit(input: 6_300, output: 1_350, cacheRead: 3_900, cacheWrite: 100))
        XCTAssertEqual(hero.requests, 16)
        XCTAssertEqual(hero.costMicros, 170_000)
        XCTAssertTrue(hero.hasUnpricedUsage)
        XCTAssertEqual(hero.activeHours, 2, "09:00 and 09:15 share an hour")
        XCTAssertEqual(hero.activeDays, 3)
        XCTAssertEqual(hero.projectCount, 2)
        XCTAssertEqual(hero.topProjectName, "alpha")
        XCTAssertEqual(hero.topProjectShare ?? 0, 4_200.0 / 5_650.0, accuracy: 1e-9)
        XCTAssertEqual(hero.tokens.cacheHitRate ?? 0, 3_900.0 / 10_300.0, accuracy: 1e-9)
    }

    func testTodayIsHourly() throws {
        var input = inputs()
        input.query = UsageDashboardQuery(
            range: .today,
            interval: DateInterval(start: date("2026-05-04T00:00:00Z"), end: date("2026-05-04T12:00:00Z"))
        )
        let trend = UsageDashboardBuilder.build(input).trend
        XCTAssertEqual(trend.bucket, .hour)
        XCTAssertEqual(trend.points.count, 12)
        let nine = try XCTUnwrap(trend.points.first { $0.start == date("2026-05-04T09:00:00Z") })
        XCTAssertEqual(nine.requests, 5)
        XCTAssertEqual(nine.byHarness.map(\.harness), [.codex, .claudeCode])
        XCTAssertEqual(nine.byHarness.first?.tokens, 4_200)
    }

    func testMix() {
        let mix = UsageDashboardBuilder.build(inputs()).mix
        XCTAssertEqual(mix.harnesses.map(\.id), ["codex", "claudeCode"])
        XCTAssertEqual(mix.harnesses.map(\.tokens), [10_200, 1_450])
        XCTAssertEqual(mix.harnesses.map(\.requests), [13, 3])
        XCTAssertEqual(mix.companies.map(\.company), [Harness.codex.company, Harness.claudeCode.company])
    }

    func testTrend() throws {
        let trend = UsageDashboardBuilder.build(inputs()).trend
        XCTAssertEqual(trend.bucket, .day)
        XCTAssertEqual(trend.points.count, 7)
        let byDay = Dictionary(uniqueKeysWithValues: trend.points.map { ($0.start, $0) })
        let first = try XCTUnwrap(byDay[date("2026-05-01T00:00:00Z")])
        XCTAssertEqual(first.promptTokens, 5_000)
        XCTAssertEqual(first.outputTokens, 1_000)
        XCTAssertEqual(first.requests, 10)
        XCTAssertEqual(first.costMicros, 100_000)
        XCTAssertEqual(first.activeHours, 0, "a rollup day has no clock")
        let monday = try XCTUnwrap(byDay[date("2026-05-04T00:00:00Z")])
        XCTAssertEqual(monday.promptTokens, 5_100)
        XCTAssertEqual(monday.outputTokens, 250)
        XCTAssertEqual(monday.requests, 5)
        XCTAssertEqual(monday.costMicros, 70_000)
        XCTAssertEqual(monday.activeHours, 1)
        XCTAssertEqual(monday.sessions, 2)
        XCTAssertEqual(monday.byHarness.map(\.harness), [.codex, .claudeCode])
        XCTAssertEqual(byDay[date("2026-05-05T00:00:00Z")]?.sessions, 1)
        XCTAssertEqual(byDay[date("2026-05-05T00:00:00Z")]?.activeHours, 1)
        XCTAssertEqual(byDay[date("2026-05-06T00:00:00Z")]?.sessions, 1, "no scan: the session's own dates")
        XCTAssertEqual(byDay[date("2026-05-07T00:00:00Z")]?.requests, 0)
    }

    func testRankings() {
        let snapshot = UsageDashboardBuilder.build(inputs())
        XCTAssertEqual(snapshot.projects.rows.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(snapshot.projects.rows.map(\.tokens), [4_200, 1_450])
        XCTAssertEqual(snapshot.projects.rows.map(\.sessions), [1, 1])
        XCTAssertEqual(snapshot.projects.rows.first?.costMicros, 50_000)
        XCTAssertEqual(snapshot.projects.remainderCount, 0)
        XCTAssertEqual(snapshot.models.rows.map(\.id), ["gpt-5", "claude-sonnet-4-5"])
        XCTAssertEqual(snapshot.models.rows.first?.share ?? 0, 10_200.0 / 11_650.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.models.rows.map(\.sessions), [1, 1])
    }

    func testRankingFoldsPastSixIntoTheRemainder() {
        var input = inputs()
        input.ledger.projects = (0..<9).map {
            .init(key: "/Users/example/Code/p\($0)", harness: .codex, requests: 1, tokens: Int64(100 * (9 - $0)), costMicros: 0, unpriced: 1)
        }
        let ranking = UsageDashboardBuilder.build(input).projects
        XCTAssertEqual(ranking.rows.count, 6)
        // Only the ledger's projects rank; a session's directory never adds one.
        XCTAssertEqual(ranking.remainderCount, 9 - 6)
        XCTAssertNil(ranking.rows.first?.costMicros, "an all-unpriced project has no cost")
    }

    func testHeatmap() {
        let heatmap = UsageDashboardBuilder.build(inputs()).heatmap
        // 2026-05-04 is a Monday (row 0), 2026-05-05 a Tuesday (row 1).
        XCTAssertEqual(heatmap.value(weekday: 0, hour: 9), 5)
        XCTAssertEqual(heatmap.value(weekday: 1, hour: 14), 1)
        XCTAssertEqual(heatmap.totalRequests, 6)
        XCTAssertEqual(heatmap.busiestWeekday, 0)
        XCTAssertEqual(heatmap.busiestHour, 9)
        XCTAssertEqual(heatmap.coversFrom, date("2026-05-02T00:00:00Z"))
    }

    func testSessionRowsAndTopLists() throws {
        let snapshot = UsageDashboardBuilder.build(inputs())
        XCTAssertEqual(snapshot.recentSessions.map(\.summary.sessionID), ["grok-c", "claude-b", "codex-a"])
        let a = try XCTUnwrap(snapshot.recentSessions.first { $0.summary.sessionID == "codex-a" })
        XCTAssertEqual(a.tokens?.total, 4_200)
        XCTAssertEqual(a.costMicros, 50_000)
        XCTAssertEqual(a.messages, 8)
        XCTAssertEqual(a.durationSeconds, 4_200)
        XCTAssertEqual(a.activeSeconds, 1_800)
        XCTAssertEqual(a.toolCalls, 30)
        XCTAssertEqual(a.model, "gpt-5")
        XCTAssertEqual(a.projectName, "alpha")
        XCTAssertEqual(a.tokenSource, .sessionLog, "Codex rows carry no session id")
        let b = try XCTUnwrap(snapshot.recentSessions.first { $0.summary.sessionID == "claude-b" })
        XCTAssertEqual(b.tokens?.total, 1_450)
        XCTAssertEqual(b.tokenSource, .ledger)
        XCTAssertTrue(b.costIsPartial)
        XCTAssertEqual(b.messages, 3)
        XCTAssertEqual(b.projectPath, "/Users/example/Code/beta", "worktrees fold into the repository")
        XCTAssertEqual(b.activeSeconds, 600)
        XCTAssertEqual(b.toolCalls, 10)
        XCTAssertEqual(b.model, "claude-sonnet-4-5")
        let c = try XCTUnwrap(snapshot.recentSessions.first { $0.summary.sessionID == "grok-c" })
        XCTAssertNil(c.tokens)
        XCTAssertEqual(c.tokenSource, .none)
        XCTAssertEqual(c.messages, 12)
        XCTAssertEqual(c.durationSeconds, 1_800)

        XCTAssertEqual(snapshot.topSessions.byTokens.map(\.summary.sessionID), ["codex-a", "claude-b"])
        XCTAssertEqual(snapshot.topSessions.byCost.map(\.summary.sessionID), ["codex-a", "claude-b"])
        // C has no active time but a 30-minute span, tying A; the newer wins.
        XCTAssertEqual(snapshot.topSessions.byActive.map(\.summary.sessionID), ["grok-c", "codex-a", "claude-b"])
    }

    func testSessionShape() {
        let shape = UsageDashboardBuilder.build(inputs()).shape
        XCTAssertEqual(shape.messages.bins.map(\.count), [1, 2, 0, 0, 0, 0])
        XCTAssertEqual(shape.messages.median, 8)
        XCTAssertEqual(shape.duration.bins.map(\.count), [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(shape.duration.median, 4_200)
        XCTAssertEqual(shape.toolCalls.bins.map(\.count), [0, 1, 1, 0, 0, 0])
        XCTAssertEqual(shape.toolCalls.median, 20)
        XCTAssertEqual(shape.toolCalls.sampleCount, 2)
    }

    func testSkillsAndTools() throws {
        let snapshot = UsageDashboardBuilder.build(inputs())
        XCTAssertEqual(snapshot.skills.map(\.name), ["alpha-skill", "beta-skill"])
        let alpha = try XCTUnwrap(snapshot.skills.first)
        XCTAssertEqual(alpha.invocations, 3)
        XCTAssertEqual(alpha.sessions, 2)
        XCTAssertEqual(alpha.harnesses, [.init(harness: .codex, count: 2), .init(harness: .claudeCode, count: 1)])
        XCTAssertEqual(alpha.projects, ["alpha", "beta"])
        XCTAssertEqual(alpha.lastUsedAt, date("2026-05-04T09:30:00Z"))

        let tools = snapshot.tools
        XCTAssertEqual(tools.totalCalls, 40)
        XCTAssertEqual(tools.rows.map(\.name), ["exec", "js", "Bash", "Read"])
        XCTAssertEqual(tools.rows.map(\.calls), [20, 10, 5, 5])
        XCTAssertEqual(tools.rows.first?.share, 0.5)
        XCTAssertEqual(tools.rows.map(\.category), [.shell, .shell, .shell, .read])
        let week = try XCTUnwrap(tools.weeks.first)
        XCTAssertEqual(tools.weeks.count, 1)
        XCTAssertEqual(week.count(.shell), 35)
        XCTAssertEqual(week.count(.read), 5)
        XCTAssertEqual(week.start, utc.dateInterval(of: .weekOfYear, for: date("2026-05-04T00:00:00Z"))?.start)
    }

    func testHealthCards() throws {
        let health = UsageDashboardBuilder.build(inputs()).health
        XCTAssertEqual(health.map(\.harness), [.codex, .claudeCode, .grokBuild])

        let codex = try XCTUnwrap(health.first)
        XCTAssertEqual(codex.requests, 13)
        XCTAssertEqual(codex.sessions, 1)
        XCTAssertEqual(codex.typicalPrompt, 3 * 1_024 + 512)
        XCTAssertEqual(codex.maxPrompt, 10_500)
        XCTAssertEqual(codex.startSize, 3_500)
        XCTAssertEqual(codex.growthPerRequest, 3_500)
        XCTAssertEqual(codex.cacheHitRate ?? 0, 3_000.0 / 9_000.0, accuracy: 1e-9)
        XCTAssertEqual(codex.contextWindow, 272_000)
        XCTAssertEqual(codex.toolFailureRate ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(codex.cacheScore, 39)
        XCTAssertEqual(codex.leanStartScore, 100)
        XCTAssertEqual(codex.paceScore, 40)
        XCTAssertEqual(codex.reliabilityScore, 60)
        XCTAssertEqual(codex.score, 57)
        XCTAssertEqual(codex.rating, .fair)
        XCTAssertEqual(codex.models, ["gpt-5"])

        let claude = try XCTUnwrap(health.first { $0.harness == .claudeCode })
        XCTAssertEqual(claude.startSize, 1_000)
        XCTAssertEqual(claude.growthPerRequest, 50)
        XCTAssertEqual(claude.contextWindow, 200_000, "from the model table")
        XCTAssertNil(claude.reliabilityScore)
        XCTAssertEqual(claude.cacheScore, 81)
        XCTAssertEqual(claude.score, 91)
        XCTAssertEqual(claude.rating, .excellent)

        let grok = try XCTUnwrap(health.last)
        XCTAssertNil(grok.score)
        XCTAssertEqual(grok.rating, .unknown)
        XCTAssertEqual(grok.sessions, 1)
    }

    func testAHarnessWithNoCacheTokensHasNoCachePart() throws {
        var input = inputs()
        input.ledger.slots.append(.init(
            start: ts("2026-05-06T10:00:00Z"), harness: .grokBuild, requests: 4,
            tokens: UsageTokenSplit(input: 40_000, output: 6_000), costMicros: 1_000, unpriced: 0
        ))
        input.ledger.days.append(.init(
            day: "2026-05-06", harness: .grokBuild, requests: 4,
            tokens: UsageTokenSplit(input: 40_000, output: 6_000), costMicros: 1_000, unpriced: 0
        ))
        let grok = try XCTUnwrap(UsageDashboardBuilder.build(input).health.first { $0.harness == .grokBuild })
        XCTAssertEqual(grok.requests, 4)
        XCTAssertNil(grok.cacheHitRate)
        XCTAssertNil(grok.cacheScore)
    }

    func testHealthScoreFormula() {
        let perfect = UsageDashboardBuilder.healthScores(
            cacheHitRate: 0.9, startSize: 5_000, growthPerRequest: 100, contextWindow: 200_000, toolFailureRate: 0
        )
        XCTAssertEqual(perfect.score, 100)
        let unknownWindow = UsageDashboardBuilder.healthScores(
            cacheHitRate: nil, startSize: 45_000, growthPerRequest: 2_750, contextWindow: nil, toolFailureRate: nil
        )
        XCTAssertEqual(unknownWindow.leanStart, 50)
        XCTAssertEqual(unknownWindow.pace, 50)
        XCTAssertEqual(unknownWindow.score, 50)
        let nothing = UsageDashboardBuilder.healthScores(
            cacheHitRate: nil, startSize: nil, growthPerRequest: nil, contextWindow: nil, toolFailureRate: nil
        )
        XCTAssertNil(nothing.score)
    }

    func testOptionsAndCoverage() {
        let snapshot = UsageDashboardBuilder.build(inputs())
        XCTAssertEqual(snapshot.options.harnesses.map(\.harness), [.codex, .claudeCode, .grokBuild])
        XCTAssertEqual(snapshot.options.harnesses.map(\.sessions), [1, 1, 1])
        XCTAssertEqual(snapshot.options.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(snapshot.options.models, ["claude-sonnet-4-5", "gpt-5"])
        XCTAssertEqual(snapshot.coverage.sessionsInRange, 3)
        XCTAssertEqual(snapshot.coverage.structureEligible, 2)
        XCTAssertEqual(snapshot.coverage.structureReady, 1)
        XCTAssertEqual(snapshot.coverage.activityEligible, 2)
        XCTAssertEqual(snapshot.coverage.activityReady, 2)
        XCTAssertEqual(snapshot.coverage.analyzable, 2)
        XCTAssertEqual(snapshot.coverage.analyzed, 1, "B still waits for its structure row")
        XCTAssertEqual(snapshot.coverage.skipped, 0)
        XCTAssertEqual(snapshot.coverage.pending, 1)
        XCTAssertEqual(snapshot.coverage.hourlyFrom, date("2026-05-02T00:00:00Z"))
    }

    func testASessionMissingAReadingItCannotGetIsSkipped() {
        var input = inputs()
        input.unreachablePaths = [sessionB.sourcePath]
        let coverage = UsageDashboardBuilder.build(input).coverage
        XCTAssertEqual(coverage.skipped, 1)
        XCTAssertEqual(coverage.pending, 0)
        XCTAssertTrue(coverage.isComplete)
    }

    func testFiltersNarrowTheSessions() {
        let claudeOnly = UsageDashboardBuilder.build(inputs(harnesses: [.claudeCode]))
        XCTAssertEqual(claudeOnly.recentSessions.map(\.summary.sessionID), ["claude-b"])
        XCTAssertEqual(claudeOnly.options.harnesses.count, 3, "the chips keep every harness")

        let project = UsageDashboardBuilder.build(inputs(project: "/Users/example/Code/beta"))
        XCTAssertEqual(project.recentSessions.map(\.summary.sessionID), ["claude-b"])

        let model = UsageDashboardBuilder.build(inputs(model: "claude-sonnet-4-5"))
        XCTAssertEqual(model.recentSessions.map(\.summary.sessionID), ["claude-b"])
    }

    func testWideRangesSwitchToWeeklyBars() {
        var input = inputs()
        input.query = UsageDashboardQuery(
            range: .all,
            interval: DateInterval(start: date("2025-10-01T00:00:00Z"), end: date("2026-05-07T12:00:00Z"))
        )
        input.ledger.days.append(.init(
            day: "2026-04-20", harness: .codex, requests: 99,
            tokens: UsageTokenSplit(input: 9_999), costMicros: 9_999, unpriced: 0
        ))
        let trend = UsageDashboardBuilder.build(input).trend
        XCTAssertEqual(trend.bucket, .week)
        XCTAssertLessThanOrEqual(trend.points.count, 40)
        XCTAssertEqual(trend.points.reduce(0) { $0 + $1.requests }, 16 + 99)
        // Weeks start where the ledger's do (Sunday, en_US_POSIX Gregorian).
        XCTAssertTrue(trend.points.allSatisfy { utc.component(.weekday, from: $0.start) == 1 })
    }

    func testRangePresets() {
        let now = date("2026-05-07T12:00:00Z")
        XCTAssertEqual(UsageDashboardRange.today.interval(now: now, earliest: nil, calendar: utc).start, date("2026-05-07T00:00:00Z"))
        XCTAssertEqual(UsageDashboardRange.week.interval(now: now, earliest: nil, calendar: utc).start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(UsageDashboardRange.quarter.interval(now: now, earliest: nil, calendar: utc).start, date("2026-02-07T00:00:00Z"))
        XCTAssertEqual(
            UsageDashboardRange.all.interval(now: now, earliest: date("2025-09-24T13:00:00Z"), calendar: utc).start,
            date("2025-09-24T00:00:00Z")
        )
    }
}
