import XCTest
@testable import VibeBarCore

final class UsageQueryMetricsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_339_200)
    private let calendar = UsageLedgerFixtures.calendar

    // MARK: - Pure formulas

    func testRealTotalTokensSumsEveryNonOverlappingColumn() {
        let metrics = UsageSummaryMetrics(
            requests: 3, unpricedRequests: 0, costMicros: 1,
            freshInput: 100, output: 20, cacheRead: 700, cacheCreation: 80
        )
        XCTAssertEqual(metrics.realTotalTokens, 900)
    }

    func testCacheHitRateExcludesOutputAndIsNilWithoutInputTraffic() throws {
        let hot = UsageSummaryMetrics(
            requests: 1, unpricedRequests: 0, costMicros: 0,
            freshInput: 100, output: 9_999, cacheRead: 300, cacheCreation: 100
        )
        XCTAssertEqual(try XCTUnwrap(hot.cacheHitRate), 0.6, accuracy: 0.000_001)

        let outputOnly = UsageSummaryMetrics(
            requests: 1, unpricedRequests: 0, costMicros: 0,
            freshInput: 0, output: 500, cacheRead: 0, cacheCreation: 0
        )
        XCTAssertNil(outputOnly.cacheHitRate)
        XCTAssertNil(UsageSummaryMetrics.empty.cacheHitRate)
    }

    func testAverageMicrosRoundsHalfUpAndGuardsZeroRequests() {
        XCTAssertEqual(UsageModelStat.averageMicros(total: 10, requests: 4), 3)
        XCTAssertEqual(UsageModelStat.averageMicros(total: 1_500_000, requests: 2), 750_000)
        XCTAssertEqual(UsageModelStat.averageMicros(total: -10, requests: 4), -3)
        XCTAssertEqual(UsageModelStat.averageMicros(total: 99, requests: 0), 0)
    }

    func testTrendBucketRuleSwitchesAtTwentyFourHours() {
        let start = Date(timeIntervalSince1970: 1_762_300_000)
        XCTAssertEqual(
            UsageTrendBucket.recommended(for: DateInterval(start: start, duration: 3_600)), .hour
        )
        XCTAssertEqual(
            UsageTrendBucket.recommended(for: DateInterval(start: start, duration: 24 * 3_600)), .hour
        )
        XCTAssertEqual(
            UsageTrendBucket.recommended(for: DateInterval(start: start, duration: 24 * 3_600 + 1)), .day
        )
        XCTAssertEqual(
            UsageTrendBucket.recommended(for: DateInterval(start: start, duration: 30 * 86_400)), .day
        )
        XCTAssertEqual(
            UsageTrendBucket.recommended(for: DateInterval(start: start, duration: 46 * 86_400)), .week
        )
    }


    func testProviderStatsMergeAtCompanyLevel() {
        let rows = [
            UsageProviderStat(tool: .gemini, requests: 2, totalTokens: 100, costMicros: 10),
            UsageProviderStat(tool: .antigravity, requests: 3, totalTokens: 200, costMicros: 20),
            UsageProviderStat(tool: .grok, requests: 4, totalTokens: 400, costMicros: 40),
            UsageProviderStat(tool: .cursor, requests: 5, totalTokens: 500, costMicros: 50),
            UsageProviderStat(tool: .codex, requests: 1, totalTokens: 50, costMicros: 5)
        ]
        let merged = UsageProviderStat.mergedByCompany(rows)
        XCTAssertEqual(merged.map(\.tool), [.grok, .gemini, .codex])
        XCTAssertEqual(merged[0].requests, 9)
        XCTAssertEqual(merged[0].totalTokens, 900)
        XCTAssertEqual(merged[1].requests, 5)
        XCTAssertEqual(merged[1].totalTokens, 300)
    }

    func testHarnessStatsMergeDuplicateGroups() {
        // A migrated ledger can hold a backfilled group and a freshly stamped
        // one for the same harness; the merge is what puts them back together.
        let rows = [
            UsageHarnessStat(harness: .codex, requests: 2, totalTokens: 100, costMicros: 10),
            UsageHarnessStat(harness: .codex, requests: 3, totalTokens: 150, costMicros: 15),
            UsageHarnessStat(harness: .chatgptWork, requests: 4, totalTokens: 400, costMicros: 40),
            UsageHarnessStat(harness: .claudeCowork, requests: 1, totalTokens: 400, costMicros: 4)
        ]
        let merged = UsageHarnessStat.mergedByHarness(rows)
        XCTAssertEqual(merged.map(\.harness), [.chatgptWork, .claudeCowork, .codex])
        XCTAssertEqual(merged[0].requests, 4)
        XCTAssertEqual(merged[2].requests, 5)
        XCTAssertEqual(merged[2].totalTokens, 250)
        XCTAssertEqual(merged[2].costMicros, 25)
    }

    func testEarliestUsageDateUsesActualRowsAndToolFilter() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsEarliest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = now.addingTimeInterval(-20 * 86_400)
        let recent = now.addingTimeInterval(-2 * 86_400)
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/old.jsonl",
            events: [UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: old))]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .codex,
            path: "/Users/example/.codex/sessions/recent.jsonl",
            events: [UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: recent))]
        ))

        let allStart = try await ledger.earliestUsageDate()
        let codexStart = try await ledger.earliestUsageDate(tools: [.codex])
        let emptyStart = try await ledger.earliestUsageDate(tools: [])
        XCTAssertEqual(allStart, old)
        XCTAssertEqual(codexStart, recent)
        XCTAssertNil(emptyStart)
    }

    func testBlankLegacyModelRemainsInTotalsButNotModelFiltersOrRows() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsBlankModel")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: now, model: "", input: 300, output: 30),
                costUSD: 0.3
            ),
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(
                    date: now.addingTimeInterval(-60),
                    model: "gpt-5.5",
                    input: 700,
                    output: 70
                ),
                costUSD: 0.7
            )
        ]))
        let filter = UsageLedgerFixtures.wideFilter(around: now)
        let summary = try await ledger.summary(filter)
        let available = try await ledger.availableModels()
        let models = try await ledger.modelStats(filter)
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(available, ["gpt-5.5"])
        XCTAssertEqual(models.map(\.model), ["gpt-5.5"])
    }

    // MARK: - Zero-filled trend

    func testHourlyTrendZeroFillsEveryBucketInRange() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsHourly")
        defer { try? FileManager.default.removeItem(at: directory) }

        let hourStart = try XCTUnwrap(calendar.dateInterval(of: .hour, for: now)).start
        let start = try XCTUnwrap(calendar.date(byAdding: .hour, value: -23, to: hourStart))
        let end = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: hourStart))
        let inFirstHour = start.addingTimeInterval(120)
        let inLastHour = hourStart.addingTimeInterval(120)

        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: inFirstHour, input: 300, output: 30), costUSD: 0.3
            ),
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: inLastHour, input: 700, output: 70), costUSD: 0.7
            )
        ]))

        let filter = UsageQueryFilter(range: DateInterval(start: start, end: end))
        XCTAssertEqual(UsageTrendBucket.recommended(for: filter.range), .hour)

        let series = try await ledger.trend(filter)
        XCTAssertEqual(series.bucket, .hour)
        XCTAssertEqual(series.points.count, 24)
        XCTAssertEqual(series.points.first?.bucketStart, start)
        XCTAssertEqual(series.points.first?.freshInput, 300)
        XCTAssertEqual(series.points.last?.bucketStart, hourStart)
        XCTAssertEqual(series.points.last?.freshInput, 700)
        XCTAssertEqual(series.points.filter { $0.totalTokens == 0 }.count, 22)
        XCTAssertEqual(series.points.reduce(Int64(0)) { $0 + $1.costMicros }, 1_000_000)
    }

    func testHourlyTrendFallsBackToDailyWhenRangeCrossesActualDetailFloor() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsHourlyFloor")
        defer { try? FileManager.default.removeItem(at: directory) }

        let today = calendar.startOfDay(for: now)
        let rolledUpDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -35, to: today))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: rolledUpDay))
        let event = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: rolledUpDay))

        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: event, input: 300, output: 30), costUSD: 0.3
            )
        ]))
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 365)

        let filter = UsageQueryFilter(range: DateInterval(start: rolledUpDay, end: end))
        // This is only 24 buckets, so bucket-count gating alone would still
        // offer Hourly. The ledger's stored floor must force the day fallback.
        let series = try await ledger.trend(filter, bucket: .hour)
        let supportsHourly = try await ledger.supportsHourlyTrend(filter)
        XCTAssertFalse(supportsHourly)
        XCTAssertEqual(series.bucket, .day)
        XCTAssertEqual(series.points.map(\.totalTokens), [330])
        XCTAssertEqual(series.points.map(\.costMicros), [300_000])
    }

    func testDailyTrendZeroFillsEveryDayInRange() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsDaily")
        defer { try? FileManager.default.removeItem(at: directory) }

        let today = calendar.startOfDay(for: now)
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let midday = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: start))

        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: midday, input: 10, output: 1), costUSD: 0.01
            )
        ]))

        let filter = UsageQueryFilter(range: DateInterval(start: start, end: end))
        XCTAssertEqual(UsageTrendBucket.recommended(for: filter.range), .day)

        let series = try await ledger.trend(filter)
        XCTAssertEqual(series.bucket, .day)
        XCTAssertEqual(series.points.count, 7)
        XCTAssertEqual(series.points.first?.bucketStart, start)
        XCTAssertEqual(series.points.first?.totalTokens, 11)
        XCTAssertEqual(series.points.dropFirst().reduce(Int64(0)) { $0 + $1.totalTokens }, 0)
    }

    func testWeeklyTrendGroupsProviderSeriesOnTheSameBuckets() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsWeeklyProviders")
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: now)).start
        let end = try XCTUnwrap(calendar.date(byAdding: .weekOfYear, value: 2, to: start))
        let first = try XCTUnwrap(calendar.date(byAdding: .hour, value: 4, to: start))
        let second = try XCTUnwrap(calendar.date(byAdding: .day, value: 8, to: start))

        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .codex,
            path: "/Users/example/.codex/sessions/weekly.jsonl",
            events: [UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: first, input: 100, output: 10), costUSD: 0.10
            )]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .grok,
            path: "/Users/example/.grok/sessions/weekly.jsonl",
            events: [UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: second, input: 200, output: 20), costUSD: 0.20
            )]
        ))

        let series = try await ledger.trend(
            UsageQueryFilter(range: DateInterval(start: start, end: end)), bucket: .week
        )
        XCTAssertEqual(series.bucket, .week)
        XCTAssertEqual(series.points.count, 2)
        XCTAssertEqual(series.points.map(\.totalTokens), [110, 220])
        XCTAssertEqual(series.providerSeries.map(\.tool), [.codex, .grok])
        XCTAssertEqual(series.providerSeries[0].points.map(\.totalTokens), [110, 0])
        XCTAssertEqual(series.providerSeries[1].points.map(\.totalTokens), [0, 220])
    }

    func testWeeklyTrendKeepsPartialBoundaryWeeksButExcludesOutOfRangeRows() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsPartialWeeks")
        defer { try? FileManager.default.removeItem(at: directory) }

        let weekStart = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: now)).start
        let rangeStart = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: weekStart))
        let rangeEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 10, to: weekStart))
        let beforeRange = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: weekStart))
        let insideFirstPartialWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: weekStart))
        let insideLastPartialWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 8, to: weekStart))

        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: beforeRange, input: 900, output: 90), costUSD: 0.90
            ),
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: insideFirstPartialWeek, input: 100, output: 10),
                costUSD: 0.10
            ),
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(date: insideLastPartialWeek, input: 200, output: 20),
                costUSD: 0.20
            ),
        ]))

        let series = try await ledger.trend(
            UsageQueryFilter(range: DateInterval(start: rangeStart, end: rangeEnd)), bucket: .week
        )
        let secondWeek = try XCTUnwrap(calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart))
        XCTAssertEqual(series.points.map(\.bucketStart), [weekStart, secondWeek])
        XCTAssertEqual(series.points.map(\.totalTokens), [110, 220])
        XCTAssertEqual(series.points.reduce(Int64(0)) { $0 + $1.costMicros }, 300_000)
    }

    // MARK: - Filters

    func testToolAndModelFiltersNarrowEveryQuery() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsFilters")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .codex,
            path: "/Users/example/.codex/sessions/mixed.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(date: now, model: "gpt-5", input: 100, output: 10),
                    costUSD: 0.1
                ),
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now.addingTimeInterval(-60), model: "gpt-5-mini", input: 200, output: 20
                    ),
                    costUSD: 0.2
                )
            ]
        ))
        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/demo/mixed.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: now, model: "claude-sonnet-4-5", input: 400, output: 40,
                        messageId: "msg-f", requestId: "req-f"
                    ),
                    costUSD: 0.4
                )
            ]
        ))

        let all = try await ledger.summary(UsageLedgerFixtures.wideFilter(around: now))
        XCTAssertEqual(all.requests, 3)

        let codexOnly = try await ledger.summary(
            UsageLedgerFixtures.wideFilter(around: now, tools: [.codex])
        )
        XCTAssertEqual(codexOnly.requests, 2)
        XCTAssertEqual(codexOnly.costMicros, 300_000)

        let miniOnly = try await ledger.summary(
            UsageLedgerFixtures.wideFilter(around: now, models: ["gpt-5-mini"])
        )
        XCTAssertEqual(miniOnly.requests, 1)
        XCTAssertEqual(miniOnly.freshInput, 200)

        let bothNarrowed = try await ledger.summary(
            UsageLedgerFixtures.wideFilter(around: now, tools: [.claude], models: ["gpt-5"])
        )
        XCTAssertEqual(bothNarrowed.requests, 0)

        // An empty list means "nothing selected", not "everything".
        let noTools = try await ledger.summary(
            UsageLedgerFixtures.wideFilter(around: now, tools: [])
        )
        XCTAssertEqual(noTools.requests, 0)
        XCTAssertNil(noTools.costMicros)

        let providers = try await ledger.providerStats(
            UsageLedgerFixtures.wideFilter(around: now, tools: [.claude])
        )
        XCTAssertEqual(providers.map(\.tool), [.claude])

        // Out-of-range: everything is older than this window.
        let future = UsageQueryFilter(
            range: DateInterval(
                start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(2 * 86_400)
            )
        )
        let futureRequests = try await ledger.summary(future).requests
        XCTAssertEqual(futureRequests, 0)
    }

    // MARK: - Pagination

    func testRequestPageWalksTheWholeRunByCursor() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsPaging")
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = (0..<10).map { index in
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(
                    date: now.addingTimeInterval(TimeInterval(-60 * index)),
                    input: 100 + index, output: 1
                ),
                costUSD: 0.01
            )
        }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: events))
        let filter = UsageLedgerFixtures.wideFilter(around: now)

        let first = try await ledger.requestPage(filter, pageSize: 5)
        XCTAssertEqual(first.totalCount, 10)
        XCTAssertEqual(first.rows.count, 5)
        XCTAssertNil(first.cursor)
        // Newest first.
        XCTAssertEqual(first.rows.first?.date, now)
        XCTAssertEqual(first.rows.first?.freshInput, 100)
        XCTAssertEqual(first.rows.first?.tool, .codex)
        XCTAssertEqual(first.rows.first?.costMicros, 10_000)

        let firstCursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(firstCursor.ts, Int64(first.rows.last!.date.timeIntervalSince1970))
        XCTAssertEqual(firstCursor.id, first.rows.last?.id)

        let second = try await ledger.requestPage(filter, after: firstCursor, pageSize: 5)
        XCTAssertEqual(second.cursor, firstCursor)
        XCTAssertEqual(second.rows.count, 5)
        XCTAssertEqual(second.rows.last?.freshInput, 109)

        // Full run, in order, with nothing repeated or missed.
        XCTAssertEqual(
            (first.rows + second.rows).map(\.freshInput),
            (0..<10).map { Int64(100 + $0) }
        )

        // The page after the last full one is empty but still reports the
        // real total, and ends the sequence.
        let past = try await ledger.requestPage(
            filter, after: try XCTUnwrap(second.nextCursor), pageSize: 5
        )
        XCTAssertTrue(past.rows.isEmpty)
        XCTAssertEqual(past.totalCount, 10)
        XCTAssertNil(past.nextCursor)

        // A zero page size is clamped, never fatal.
        let clamped = try await ledger.requestPage(filter, pageSize: 0)
        XCTAssertEqual(clamped.pageSize, 1)
        XCTAssertEqual(clamped.rows.count, 1)
    }

    /// COUNT(*) visits every matched row, so it costs the same on page 40 as
    /// on page 0 — and returns the same number, because the filter a run
    /// pages through is pinned. Continuing a run must be able to skip it.
    func testRequestPageOmitsTheTotalWhenTheCallerDeclinesIt() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsCountOnce")
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = (0..<10).map { index in
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(
                    date: now.addingTimeInterval(TimeInterval(-60 * index)),
                    input: 100 + index, output: 1
                ),
                costUSD: 0.01
            )
        }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: events))
        let filter = UsageLedgerFixtures.wideFilter(around: now)

        let counted = try await ledger.requestPage(filter, pageSize: 4)
        XCTAssertEqual(counted.totalCount, 10)

        let cursor = try XCTUnwrap(counted.nextCursor)
        let uncounted = try await ledger.requestPage(
            filter, after: cursor, pageSize: 4, includeTotal: false
        )
        XCTAssertNil(uncounted.totalCount, "the caller kept the first page's number")

        // Skipping the count changes nothing else about the page.
        let recounted = try await ledger.requestPage(filter, after: cursor, pageSize: 4)
        XCTAssertEqual(recounted.totalCount, 10)
        XCTAssertEqual(uncounted.rows.map(\.id), recounted.rows.map(\.id))
        XCTAssertEqual(uncounted.nextCursor, recounted.nextCursor)
    }

    /// Ten events in the same second. `ts` alone cannot order them, so a
    /// cursor that only carried the timestamp would either re-serve the whole
    /// second on every page or skip the rest of it.
    func testRequestPagingIsStableAcrossRowsSharingOneTimestamp() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("MetricsPagingTies")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Distinct `input` values give each row an identity; identical dates
        // force every tie-break through `id`.
        let events = (0..<10).map { index in
            UsageLedgerFixtures.priced(
                UsageLedgerFixtures.event(
                    date: now, input: 500 + index, output: 1,
                    messageId: "tie-\(index)"
                ),
                costUSD: 0.01
            )
        }
        try await ledger.ingest(UsageLedgerFixtures.batch(events: events))
        let filter = UsageLedgerFixtures.wideFilter(around: now)

        var collected: [UsageRequestRow] = []
        var cursor: UsageRequestCursor?
        for _ in 0..<10 {
            let page = try await ledger.requestPage(filter, after: cursor, pageSize: 3)
            collected.append(contentsOf: page.rows)
            guard let next = page.nextCursor else { break }
            cursor = next
        }

        XCTAssertEqual(collected.count, 10)
        XCTAssertEqual(Set(collected.map(\.id)).count, 10, "no row served twice")
        XCTAssertEqual(
            Set(collected.map(\.freshInput)),
            Set((0..<10).map { Int64(500 + $0) },
            ), "no row skipped"
        )
        // Every row shares the second, so the run must descend by id.
        XCTAssertEqual(collected.map(\.id), collected.map(\.id).sorted(by: >))
    }

    // MARK: - Result reuse

    /// What the Usage Stats page compares on re-entry. Each of these is an
    /// input the ledger actually reads, so each has to move the signature.
    func testSignatureChangesForEveryQueryInput() {
        let base = UsageQuerySignature(
            rangeKey: UsageQuerySignature.rangeKey(
                preset: "day7", windowStart: nil, customStart: now, customEnd: now
            ),
            tools: [.codex],
            harnesses: [.codex],
            models: ["gpt-5"],
            granularity: .day,
            revision: 7
        )

        var range = base
        range.rangeKey = UsageQuerySignature.rangeKey(
            preset: "day30", windowStart: nil, customStart: now, customEnd: now
        )
        XCTAssertNotEqual(base, range)

        var tools = base
        tools.tools = [.claude]
        XCTAssertNotEqual(base, tools)

        var harnesses = base
        harnesses.harnesses = [.claudeCode]
        XCTAssertNotEqual(base, harnesses)

        var models = base
        models.models = ["gpt-5-codex"]
        XCTAssertNotEqual(base, models)

        var granularity = base
        granularity.granularity = .hour
        XCTAssertNotEqual(base, granularity)

        var revision = base
        revision.revision = 8
        XCTAssertNotEqual(base, revision, "a scan that wrote rows must force a re-query")
    }

    /// A rolling preset's window slides with the wall clock, but no row can
    /// appear inside it without the ledger's revision moving too — so the
    /// clock alone must not invalidate a result set.
    func testSignatureIgnoresClockDriftWithinTheSamePreset() {
        let first = UsageQuerySignature.rangeKey(
            preset: "day7", windowStart: nil, customStart: now, customEnd: now
        )
        let later = UsageQuerySignature.rangeKey(
            preset: "day7", windowStart: nil, customStart: now, customEnd: now
        )
        XCTAssertEqual(first, later)

        // A back / forward step *is* a different window, and must not fold
        // into the same key.
        let stepped = UsageQuerySignature.rangeKey(
            preset: "day7",
            windowStart: now.addingTimeInterval(-7 * 86_400),
            customStart: now,
            customEnd: now
        )
        XCTAssertNotEqual(first, stepped)
    }

    /// The regression this type exists to prevent.
    ///
    /// Opening the Requests tab runs only its own deferred page query — it
    /// changes nothing in the shared analytic set. When the active breakdown
    /// was part of the signature, doing so left the stored signature saying
    /// "Periods" while the page said "Requests", and the next entry re-ran
    /// all eleven ledger queries against an unchanged ledger. The signature
    /// carries no tab, so the two moments are identical values.
    func testSignatureIsUnchangedByOpeningADifferentBreakdownTab() {
        func signature() -> UsageQuerySignature {
            UsageQuerySignature(
                rangeKey: UsageQuerySignature.rangeKey(
                    preset: "day7", windowStart: nil, customStart: now, customEnd: now
                ),
                tools: nil,
                harnesses: nil,
                models: nil,
                granularity: nil,
                revision: 3
            )
        }
        // Before opening Requests, and after: same inputs, same value.
        XCTAssertEqual(signature(), signature())
    }
}
