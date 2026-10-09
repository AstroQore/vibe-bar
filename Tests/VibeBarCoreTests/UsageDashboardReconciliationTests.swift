import XCTest
@testable import VibeBarCore

/// The Usage page must say what every other surface over the ledger says.
/// One synthetic ledger — five harnesses, priced and unpriced rows, projects,
/// 150 days of which the older 120 are folded into daily rollups — and for
/// every range preset and a few filters, the snapshot is checked figure by
/// figure against the queries the old Usage page, the Overview and the MCP
/// `usage.*` tools read: `summary`, `trend`, `modelStats`, `projectStats`,
/// `harnessStats` and `providerStats`.
final class UsageDashboardReconciliationTests: XCTestCase {
    private var calendar: Calendar { UsageDashboardCalendar.local }

    /// Mid-afternoon local time, so "today" has detail on both sides of noon.
    private var now: Date {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_778_000_000))
        return today.addingTimeInterval(15 * 3_600 + 20 * 60)
    }

    private func makeLedger() async throws -> (UsageEventLedger, URL) {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("Reconcile")
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let harnesses: [(ToolType, Harness, [String], [String?])] = [
            (.codex, .codex, ["gpt-5", "gpt-5.3-codex"], ["/Users/example/Code/alpha", "/Users/example/Code/beta"]),
            (.codex, .chatgptWork, ["gpt-5"], ["/Users/example/Code/gamma"]),
            (.claude, .claudeCode, ["claude-sonnet-4-5", "claude-opus-4-5"], ["/Users/example/Code/alpha", nil]),
            (.grok, .grokBuild, ["grok-code-fast-1"], [nil]),
            (.cursor, .cursor, ["grok-4.20", " "], [nil]),
        ]
        var batches: [ToolType: [PricedUsageEvent]] = [:]
        for dayOffset in 0..<150 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now))!
            for (index, entry) in harnesses.enumerated() where next(3) != 0 {
                for request in 0..<(1 + next(4)) {
                    let at = day.addingTimeInterval(TimeInterval(3_600 * (8 + next(14)) + 61 * request + index))
                    guard at <= now else { continue }
                    let model = entry.2[next(entry.2.count)]
                    let event = CostUsageScanCache.ParsedEvent(
                        date: at,
                        model: model,
                        input: 100 + next(5_000),
                        output: 10 + next(800),
                        cache: next(20_000),
                        cacheCreation: entry.1 == .claudeCode ? next(500) : nil,
                        sessionId: entry.1 == .claudeCode ? "claude-\(dayOffset)-\(request % 2)" : nil,
                        messageId: "m-\(dayOffset)-\(index)-\(request)",
                        requestId: "r-\(dayOffset)-\(index)-\(request)",
                        harness: entry.1,
                        projectPath: entry.3[next(entry.3.count)]
                    )
                    let priced = next(5) == 0 ? nil : Double(1 + next(900)) / 10_000
                    batches[entry.0, default: []].append(PricedUsageEvent(event: event, costUSD: priced))
                }
            }
        }
        for (tool, events) in batches {
            try await ledger.ingest(UsageLedgerFixtures.batch(
                tool: tool, path: "/Users/example/.synthetic/\(tool.rawValue).jsonl", events: events
            ))
        }
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 365)
        return (ledger, directory)
    }

    private func check(
        _ snapshot: UsageDashboardSnapshot,
        against ledger: UsageEventLedger,
        filter: UsageQueryFilter,
        label: String
    ) async throws {
        let summary = try await ledger.summary(filter)
        let hero = snapshot.hero
        XCTAssertEqual(hero.requests, summary.requests, "requests \(label)")
        XCTAssertEqual(hero.tokens.input, summary.freshInput, "fresh input \(label)")
        XCTAssertEqual(hero.tokens.output, summary.output, "output \(label)")
        XCTAssertEqual(hero.tokens.cacheRead, summary.cacheRead, "cache read \(label)")
        XCTAssertEqual(hero.tokens.cacheWrite, summary.cacheCreation, "cache write \(label)")
        XCTAssertEqual(hero.costMicros, summary.costMicros, "cost \(label)")
        XCTAssertEqual(hero.hasUnpricedUsage, summary.unpricedRequests > 0, "unpriced \(label)")
        XCTAssertEqual(hero.tokens.cacheHitRate, summary.cacheHitRate, "cache hit rate \(label)")

        let bucket: UsageTrendBucket = switch snapshot.trend.bucket {
        case .hour: .hour
        case .day: .day
        case .week: .week
        }
        let trend = try await ledger.trend(filter, bucket: bucket)
        XCTAssertEqual(trend.bucket, bucket, "bucket \(label)")
        XCTAssertEqual(snapshot.trend.points.map(\.start), trend.points.map(\.bucketStart), "bucket starts \(label)")
        for (mine, theirs) in zip(snapshot.trend.points, trend.points) {
            XCTAssertEqual(mine.promptTokens, theirs.freshInput + theirs.cacheRead + theirs.cacheCreation, "prompt \(label) \(theirs.bucketStart)")
            XCTAssertEqual(mine.outputTokens, theirs.output, "output \(label) \(theirs.bucketStart)")
            XCTAssertEqual(mine.costMicros, theirs.costMicros, "cost \(label) \(theirs.bucketStart)")
            XCTAssertEqual(mine.byHarness.reduce(0) { $0 + $1.tokens }, mine.totalTokens, "split \(label)")
        }

        let models = try await ledger.modelStats(filter)
        XCTAssertEqual(snapshot.models.rows.map(\.id), models.prefix(UsageDashboardBuilder.rankingLimit).map(\.model), "model order \(label)")
        XCTAssertEqual(snapshot.models.rows.map(\.tokens), models.prefix(UsageDashboardBuilder.rankingLimit).map(\.totalTokens), "model tokens \(label)")
        XCTAssertEqual(snapshot.models.rows.map(\.requests), models.prefix(UsageDashboardBuilder.rankingLimit).map(\.requests), "model requests \(label)")
        XCTAssertEqual(snapshot.models.totalTokens, models.reduce(0) { $0 + $1.totalTokens }, "model total \(label)")
        XCTAssertEqual(snapshot.models.remainderCount, max(0, models.count - UsageDashboardBuilder.rankingLimit), "model remainder \(label)")
        for row in snapshot.models.rows {
            let theirs = try XCTUnwrap(models.first { $0.model == row.id })
            XCTAssertEqual(row.costMicros ?? 0, theirs.costMicros, "model cost \(label) \(row.id)")
        }

        let projects = try await ledger.projectStats(filter)
        XCTAssertEqual(snapshot.projects.rows.map(\.id), projects.prefix(UsageDashboardBuilder.rankingLimit).map(\.path), "project order \(label)")
        XCTAssertEqual(snapshot.projects.rows.map(\.tokens), projects.prefix(UsageDashboardBuilder.rankingLimit).map(\.totalTokens), "project tokens \(label)")
        XCTAssertEqual(snapshot.projects.totalTokens, projects.reduce(0) { $0 + $1.totalTokens }, "project total \(label)")
        XCTAssertEqual(snapshot.hero.projectCount, projects.count, "project count \(label)")

        let harnesses = UsageHarnessStat.mergedByHarness(try await ledger.harnessStats(filter)).filter { $0.totalTokens > 0 }
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: snapshot.mix.harnesses.map { ($0.harness!, $0.tokens) }),
            Dictionary(uniqueKeysWithValues: harnesses.map { ($0.harness, $0.totalTokens) }),
            "harness mix \(label)"
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: snapshot.mix.harnesses.map { ($0.harness!, $0.costMicros) }),
            Dictionary(uniqueKeysWithValues: harnesses.map { ($0.harness, $0.costMicros) }),
            "harness cost \(label)"
        )
        let companies = UsageProviderStat.mergedByCompany(try await ledger.providerStats(filter)).filter { $0.totalTokens > 0 }
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: snapshot.mix.companies.map { ($0.company!, $0.tokens) }),
            Dictionary(uniqueKeysWithValues: companies.map { ($0.tool, $0.totalTokens) }),
            "company mix \(label)"
        )
    }

    func testEveryRangeMatchesTheLedgersOwnQueries() async throws {
        let (ledger, directory) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let aggregator = UsageDashboardAggregator(ledger: ledger, sessions: nil, structures: nil, activity: nil)
        for range in UsageDashboardRange.allCases {
            let interval = await aggregator.interval(for: range, harnesses: nil, now: now)
            for (harnesses, model) in [(nil, nil), ([Harness.codex, .claudeCode], nil), (nil, "gpt-5"), ([.cursor], nil)] as [([Harness]?, String?)] {
                let query = UsageDashboardQuery(range: range, interval: interval, harnesses: harnesses, model: model)
                let snapshot = await aggregator.snapshot(query, now: now)
                try await check(snapshot, against: ledger, filter: query.ledgerFilter, label: "\(range) \(harnesses ?? []) \(model ?? "-")")
            }
            // Chips: tokens per harness with no harness filter, whatever is selected.
            let narrowed = await aggregator.snapshot(
                UsageDashboardQuery(range: range, interval: interval, harnesses: [.grokBuild]), now: now
            )
            let unfiltered = UsageHarnessStat.mergedByHarness(try await ledger.harnessStats(UsageQueryFilter(range: interval)))
            for option in narrowed.options.harnesses where option.tokens > 0 {
                XCTAssertEqual(option.tokens, unfiltered.first { $0.harness == option.harness }?.totalTokens, "chip \(range) \(option.harness)")
            }
        }
    }

    func testPresetsStartWhereTheCostSnapshotWindowsStart() async throws {
        let aggregator = UsageDashboardAggregator(ledger: nil, sessions: nil, structures: nil, activity: nil)
        let today = calendar.startOfDay(for: now)
        let week = await aggregator.interval(for: .week, harnesses: nil, now: now)
        let month = await aggregator.interval(for: .month, harnesses: nil, now: now)
        let todayRange = await aggregator.interval(for: .today, harnesses: nil, now: now)
        // `CostAggregator`: last 7 days = today and the six before it.
        XCTAssertEqual(week.start, calendar.date(byAdding: .day, value: -6, to: today))
        XCTAssertEqual(month.start, calendar.date(byAdding: .day, value: -29, to: today))
        XCTAssertEqual(todayRange.start, today)
        XCTAssertEqual(week.end, now)
    }
}
