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
    }

    func testRequestPageCountReportsWholePages() {
        XCTAssertEqual(UsageRequestPage(rows: [], totalCount: 10, page: 0, pageSize: 5).pageCount, 2)
        XCTAssertEqual(UsageRequestPage(rows: [], totalCount: 11, page: 0, pageSize: 5).pageCount, 3)
        XCTAssertEqual(UsageRequestPage(rows: [], totalCount: 0, page: 0, pageSize: 5).pageCount, 0)
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

    func testRequestPageBoundaries() async throws {
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

        let first = try await ledger.requestPage(filter, page: 0, pageSize: 5)
        XCTAssertEqual(first.totalCount, 10)
        XCTAssertEqual(first.rows.count, 5)
        XCTAssertEqual(first.pageCount, 2)
        // Newest first.
        XCTAssertEqual(first.rows.first?.date, now)
        XCTAssertEqual(first.rows.first?.freshInput, 100)
        XCTAssertEqual(first.rows.first?.tool, .codex)
        XCTAssertEqual(first.rows.first?.costMicros, 10_000)

        let second = try await ledger.requestPage(filter, page: 1, pageSize: 5)
        XCTAssertEqual(second.rows.count, 5)
        XCTAssertEqual(second.rows.last?.freshInput, 109)

        // Exact multiple: the page right after the last full one is empty
        // but still reports the real total.
        let past = try await ledger.requestPage(filter, page: 2, pageSize: 5)
        XCTAssertTrue(past.rows.isEmpty)
        XCTAssertEqual(past.totalCount, 10)
        XCTAssertEqual(past.page, 2)

        let wayPast = try await ledger.requestPage(filter, page: 99, pageSize: 5)
        XCTAssertTrue(wayPast.rows.isEmpty)
        XCTAssertEqual(wayPast.totalCount, 10)

        // Negative page and zero page size are clamped, never fatal.
        let clamped = try await ledger.requestPage(filter, page: -3, pageSize: 0)
        XCTAssertEqual(clamped.page, 0)
        XCTAssertEqual(clamped.pageSize, 1)
        XCTAssertEqual(clamped.rows.count, 1)
    }
}
