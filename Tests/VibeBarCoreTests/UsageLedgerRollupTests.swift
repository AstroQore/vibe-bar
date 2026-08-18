import XCTest
@testable import VibeBarCore

final class UsageLedgerRollupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_762_339_200)
    private let calendar = UsageLedgerFixtures.calendar

    /// Local noon `offset` days from today, so a day bucket is never
    /// ambiguous across time zones.
    private func day(_ offset: Int) throws -> Date {
        let today = calendar.startOfDay(for: now)
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
        return try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: start))
    }

    private func seedBatch(size: Int64 = 4_096) throws -> UsageEventFileBatch {
        UsageLedgerFixtures.batch(
            size: size,
            events: try [-40, -35, -5, 0].map { offset in
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: try day(offset), model: "gpt-5", input: 1_000, output: 100
                    ),
                    costUSD: 1.0
                )
            }
        )
    }

    private var fullRange: UsageQueryFilter {
        UsageLedgerFixtures.wideFilter(around: now)
    }

    func testRollupMovesOldDetailIntoRollupsExactlyOnce() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RollupOnce")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(try seedBatch())
        let before = try await ledger.summary(fullRange)
        XCTAssertEqual(before.requests, 4)
        XCTAssertEqual(before.costMicros, 4_000_000)
        let seededPage = try await ledger.requestPage(fullRange, pageSize: 50)
        XCTAssertEqual(seededPage.totalCount, 4)

        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)

        // Totals survive the fold; only the request-level rows shrink.
        let after = try await ledger.summary(fullRange)
        XCTAssertEqual(after.requests, 4)
        XCTAssertEqual(after.costMicros, 4_000_000)
        XCTAssertEqual(after.realTotalTokens, before.realTotalTokens)
        let foldedPage = try await ledger.requestPage(fullRange, pageSize: 50)
        XCTAssertEqual(foldedPage.totalCount, 2)

        // Running it again must not double count the rows it already folded.
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)
        let again = try await ledger.summary(fullRange)
        XCTAssertEqual(again.requests, 4)
        XCTAssertEqual(again.costMicros, 4_000_000)
    }

    func testReconsumingPreFloorEventsIsDropped() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RollupFloor")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(try seedBatch())
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)

        let floor = try await ledger.detailFloorDay(for: .codex)
        XCTAssertNotNil(floor)

        // Same file, changed fingerprint — a full re-parse after a scan
        // cache reset. The two pre-floor events must not come back.
        try await ledger.ingest(try seedBatch(size: 8_192))

        let summary = try await ledger.summary(fullRange)
        XCTAssertEqual(summary.requests, 4)
        XCTAssertEqual(summary.costMicros, 4_000_000)
        let reconsumedPage = try await ledger.requestPage(fullRange, pageSize: 50)
        XCTAssertEqual(reconsumedPage.totalCount, 2)
    }

    func testRetentionPrunesRollupsAndStragglingDetail() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RollupRetention")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(try seedBatch())
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)
        let foldedRequests = try await ledger.summary(fullRange).requests
        XCTAssertEqual(foldedRequests, 4)

        // A 7-day window keeps today and the day-5 event only.
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 7)

        let summary = try await ledger.summary(fullRange)
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(summary.costMicros, 2_000_000)
    }

    /// The chart has to read straight across the detail/rollup boundary
    /// without a visible seam.
    func testTrendStitchesRollupDaysAndDetailDays() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RollupTrend")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(try seedBatch())
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)

        let start = calendar.startOfDay(for: try day(-45))
        let end = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        )
        let filter = UsageQueryFilter(range: DateInterval(start: start, end: end))
        let series = try await ledger.trend(filter, bucket: .day)

        XCTAssertEqual(series.bucket, .day)
        XCTAssertEqual(series.points.count, 46)
        let nonEmpty = series.points.filter { $0.totalTokens > 0 }
        XCTAssertEqual(nonEmpty.count, 4)
        XCTAssertEqual(nonEmpty.map(\.costMicros), [1_000_000, 1_000_000, 1_000_000, 1_000_000])
        XCTAssertEqual(series.points.reduce(Int64(0)) { $0 + $1.totalTokens }, 4_400)

        // The two oldest are rollup-backed, the two newest detail-backed.
        let oldest = try day(-40)
        let recent = try day(-5)
        let rolledUp = try XCTUnwrap(
            nonEmpty.first { calendar.isDate($0.bucketStart, inSameDayAs: oldest) }
        )
        XCTAssertEqual(rolledUp.freshInput, 1_000)
        XCTAssertEqual(rolledUp.output, 100)
        let detailed = try XCTUnwrap(
            nonEmpty.first { calendar.isDate($0.bucketStart, inSameDayAs: recent) }
        )
        XCTAssertEqual(detailed.freshInput, 1_000)

        let summary = try await ledger.summary(filter)
        XCTAssertEqual(summary.requests, 4)
        XCTAssertEqual(summary.costMicros, 4_000_000)
    }

    /// Rollups are whole days, so a range that only covers part of a day
    /// must not pick that day's rollup up.
    func testPartialDayRangeDoesNotReadWholeDayRollups() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RollupPartial")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(try seedBatch())
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)

        let noon = try day(-40)
        let partial = UsageQueryFilter(
            range: DateInterval(start: noon.addingTimeInterval(-3_600), end: noon.addingTimeInterval(3_600))
        )
        let partialRequests = try await ledger.summary(partial).requests
        XCTAssertEqual(partialRequests, 0)

        let wholeDay = try XCTUnwrap(calendar.dateInterval(of: .day, for: noon))
        let wholeDayRequests = try await ledger.summary(UsageQueryFilter(range: wholeDay)).requests
        XCTAssertEqual(wholeDayRequests, 1)
    }

    /// A provider whose first ingest lands after another provider's rollup
    /// must still be allowed to backfill its own history.
    func testFloorIsPerToolSoALateProviderStillBackfills() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RollupPerTool")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ledger.ingest(try seedBatch())
        try await ledger.rollupAndPrune(now: now, detailDays: 30, retentionDays: 0)
        let claudeFloor = try await ledger.detailFloorDay(for: .claude)
        XCTAssertNil(claudeFloor)

        try await ledger.ingest(UsageLedgerFixtures.batch(
            tool: .claude,
            path: "/Users/example/.claude/projects/demo/old.jsonl",
            events: [
                UsageLedgerFixtures.priced(
                    UsageLedgerFixtures.event(
                        date: try day(-60), model: "claude-sonnet-4-5", input: 7, output: 3,
                        messageId: "msg-old", requestId: "req-old"
                    ),
                    costUSD: 0.01
                )
            ]
        ))

        let claudeOnly = UsageLedgerFixtures.wideFilter(around: now, tools: [.claude])
        let claudeRequests = try await ledger.summary(claudeOnly).requests
        XCTAssertEqual(claudeRequests, 1)
        let claudeTokens = try await ledger.summary(claudeOnly).realTotalTokens
        XCTAssertEqual(claudeTokens, 10)
    }
}
