import XCTest
@testable import VibeBarCore

private struct FakeUsageLedger: EInkUsageQuerying {
    var summaries: [UsageSummaryMetrics]
    var harnessRows: [UsageHarnessStat]
    var trendPoints: [UsageTrendPoint]
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ranges: [DateInterval] = []
        func record(_ range: DateInterval) {
            lock.lock(); defer { lock.unlock() }
            ranges.append(range)
        }
        var recorded: [DateInterval] {
            lock.lock(); defer { lock.unlock() }
            return ranges
        }
    }
    var recorder = Recorder()

    func summary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics {
        recorder.record(filter.range)
        return summaries[min(recorder.recorded.count - 1, summaries.count - 1)]
    }

    func harnessStats(_ filter: UsageQueryFilter) async throws -> [UsageHarnessStat] { harnessRows }

    func trend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket) async throws -> UsageTrendSeries {
        UsageTrendSeries(bucket: bucket, points: trendPoints)
    }
}

final class EInkDataAssemblerTests: XCTestCase {
    private let now = EInkFixtures.referenceDate.addingTimeInterval(13 * 3600 + 42 * 60)

    private func metrics(costMicros: Int64, tokens: Int64, requests: Int) -> UsageSummaryMetrics {
        UsageSummaryMetrics(
            requests: requests,
            unpricedRequests: 0,
            costMicros: costMicros,
            freshInput: tokens,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0
        )
    }

    private func assembler(
        accounts: [ToolType: AccountQuota],
        ledger: FakeUsageLedger,
        snapshots: [CostSnapshot] = []
    ) -> EInkDataAssembler {
        EInkDataAssembler(
            quotaLookup: { tool in accounts[tool] },
            usage: ledger,
            allTimeCostSnapshots: { snapshots },
            calendar: EInkFixtures.calendar()
        )
    }

    private func account(tool: ToolType, buckets: [QuotaBucket]) -> AccountQuota {
        AccountQuota(accountId: "synthetic-account", tool: tool, buckets: buckets, plan: "Test Plan")
    }

    func testQuotaRowsFollowThePriorityOrderAndReportRemaining() async {
        let resetAt = now.addingTimeInterval(5 * 86_400 + 23 * 3600)
        let accounts: [ToolType: AccountQuota] = [
            .claude: account(tool: .claude, buckets: [
                QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h", usedPercent: 38, resetAt: resetAt),
                QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "7d", usedPercent: 59, resetAt: resetAt)
            ]),
            .antigravity: account(tool: .antigravity, buckets: [
                QuotaBucket(id: "claude_gpt_weekly", title: "Weekly", shortLabel: "7d", usedPercent: 27, resetAt: nil)
            ])
        ]
        let ledger = FakeUsageLedger(summaries: [.empty], harnessRows: [], trendPoints: [])
        let rows = await assembler(accounts: accounts, ledger: ledger).quotaRows(now: now)
        XCTAssertEqual(rows.map(\.fieldID), ["claude.five_hour", "claude.weekly", "antigravity.claude_gpt_weekly"])
        XCTAssertEqual(rows[0].providerDisplayName, "Claude")
        XCTAssertEqual(rows[0].windowTitle, "5 Hours")
        XCTAssertEqual(rows[0].remainingPercent, 62)
        XCTAssertEqual(rows[0].countdown, "5d 23h")
        XCTAssertEqual(rows[2].providerDisplayName, "AntiGravity")
        XCTAssertEqual(rows[2].countdown, "")
    }

    /// Deliberately short, and deliberately not `ToolType.hierarchy` — see
    /// the doc comment on `EInkProviderLabel`.
    func testProviderLabelsAreTheShortPanelForms() {
        XCTAssertEqual(EInkProviderLabel.short(for: .codex), "Codex")
        XCTAssertEqual(EInkProviderLabel.short(for: .claude), "Claude")
        XCTAssertEqual(EInkProviderLabel.short(for: .grok), "Grok")
        XCTAssertEqual(EInkProviderLabel.short(for: .antigravity), "AntiGravity")
        XCTAssertEqual(EInkProviderLabel.short(for: .gemini), "Gemini")
        XCTAssertEqual(EInkProviderLabel.short(for: .cursor), "Cursor")
        for tool in ToolType.allCases {
            XCTAssertLessThanOrEqual(
                EInkTextMetrics.width(EInkProviderLabel.short(for: tool), font: .pixel12(bold: false)),
                126,
                "\(tool.rawValue) does not fit the ledger's provider column"
            )
        }
    }

    func testUsageWindowsAreTodayFromLocalMidnightPlusRollingSevenAndThirtyDays() async throws {
        let ledger = FakeUsageLedger(
            summaries: [
                metrics(costMicros: 67_900_000, tokens: 315_556_500, requests: 42),
                metrics(costMicros: 6_299_200_000, tokens: 4_841_587_557, requests: 900),
                metrics(costMicros: 121_216_300_000, tokens: 9_000_000_000, requests: 9_000)
            ],
            harnessRows: [],
            trendPoints: []
        )
        var codex = CostSnapshot.empty(tool: .codex, now: now)
        codex = CostSnapshot(
            tool: .codex,
            todayCostUSD: 0,
            last7DaysCostUSD: 0,
            last30DaysCostUSD: 0,
            allTimeCostUSD: 280.4,
            todayTokens: 0,
            last7DaysTokens: 0,
            last30DaysTokens: 0,
            allTimeTokens: 42_000_000,
            allTimeRequests: 17,
            dailyHistory: [],
            heatmap: codex.heatmap,
            modelBreakdowns: [],
            jsonlFilesFound: 0,
            updatedAt: now
        )
        let snapshots = [CostSnapshot.empty(tool: .claude, now: now), codex]
        let snapshot = try await assembler(accounts: [:], ledger: ledger, snapshots: snapshots).usageSet(now: now)
        XCTAssertEqual(snapshot.today.costUSD, 67.9, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.today.tokens, 315_556_500)
        XCTAssertEqual(snapshot.week.costUSD, 6299.2, accuracy: 0.001)
        XCTAssertEqual(snapshot.month.costUSD, 121_216.3, accuracy: 0.01)
        XCTAssertEqual(snapshot.allTime.costUSD, 280.4, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.allTime.tokens, 42_000_000)
        XCTAssertEqual(snapshot.allTime.requests, 17)

        let ranges = ledger.recorder.recorded
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].start, EInkFixtures.calendar().startOfDay(for: now))
        XCTAssertEqual(ranges[0].end, now)
        XCTAssertEqual(ranges[1].end.timeIntervalSince(ranges[1].start), 7 * 86_400, accuracy: 1)
        XCTAssertEqual(ranges[2].end.timeIntervalSince(ranges[2].start), 30 * 86_400, accuracy: 1)
    }

    func testHarnessRowsAreMergedAndSortedByCost() async throws {
        let ledger = FakeUsageLedger(
            summaries: [metrics(costMicros: 1, tokens: 1, requests: 1)],
            harnessRows: [
                UsageHarnessStat(harness: .claudeCode, requests: 5, totalTokens: 100, costMicros: 5_000_000),
                UsageHarnessStat(harness: .codex, requests: 3, totalTokens: 300, costMicros: 9_000_000),
                UsageHarnessStat(harness: .claudeCode, requests: 2, totalTokens: 50, costMicros: 1_000_000)
            ],
            trendPoints: []
        )
        let set = try await assembler(accounts: [:], ledger: ledger).usageSet(now: now)
        XCTAssertEqual(set.today.rows.count, 2)
        XCTAssertEqual(set.today.rows[0].costUSD, 9, accuracy: 0.000_1)
        XCTAssertEqual(set.today.rows[1].costUSD, 6, accuracy: 0.000_1, "the two Claude Code groups merge")
        XCTAssertEqual(set.today.rows[1].requests, 7)
    }

    func testTrendKeepsTheLastSevenDailyPointsWithLabels() async throws {
        let midnight = EInkFixtures.calendar().startOfDay(for: now)
        let points = (0..<9).map { index in
            UsageTrendPoint(
                bucketStart: midnight.addingTimeInterval(TimeInterval(index - 8) * 86_400),
                freshInput: Int64(index * 1000),
                output: 0,
                cacheRead: 0,
                cacheCreation: 0,
                costMicros: Int64(index) * 1_000_000
            )
        }
        let ledger = FakeUsageLedger(summaries: [.empty], harnessRows: [], trendPoints: points)
        let trend = try await assembler(accounts: [:], ledger: ledger).trendPoints(now: now)
        XCTAssertEqual(trend.count, 7)
        XCTAssertEqual(trend.last?.costUSD, 8)
        XCTAssertEqual(trend.last?.tokens, 8000)
        XCTAssertEqual(trend.last?.dayLabel.count, 2)
        XCTAssertEqual(trend.last?.weekdayLabel.count, 3)
    }

    func testSnapshotFillsEveryHeaderField() async throws {
        let ledger = FakeUsageLedger(summaries: [.empty], harnessRows: [], trendPoints: [])
        let snapshot = try await assembler(accounts: [:], ledger: ledger).snapshot(now: now)
        XCTAssertEqual(snapshot.generatedAt, now)
        XCTAssertEqual(snapshot.generatedAtLabel, "01-01 13:42")
        XCTAssertTrue(snapshot.generatedAtISO.hasPrefix("2026-01-01"))
        XCTAssertTrue(snapshot.quota.isEmpty)
    }

    func testDefaultPriorityMatchesTheVerifiedDemo() {
        XCTAssertEqual(
            EInkDataAssembler.defaultQuotaPriority.map(\.fieldID),
            [
                "claude.five_hour", "claude.weekly", "codex.weekly", "grok.weekly",
                "antigravity.claude_gpt_weekly", "gemini.weekly", "cursor.models"
            ]
        )
    }
}

// MARK: - The panel never abbreviates

extension EInkDataAssemblerTests {
    /// `shortLabel` is the menu bar's vocabulary — "5h", "WK", "TOK". The
    /// panel writes windows out in full, so the assembler must never reach for
    /// it, not even as a fallback.
    func testWindowTitlesAreWrittenOutInFullAndNeverFallBackToShortLabel() async {
        let accounts: [ToolType: AccountQuota] = [
            .claude: AccountQuota(
                accountId: "synthetic-account",
                tool: .claude,
                buckets: [
                    QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h", usedPercent: 10),
                    QuotaBucket(
                        id: "weekly",
                        title: "",
                        shortLabel: "WK",
                        usedPercent: 20,
                        groupTitle: "Weekly"
                    )
                ],
                plan: "Test Plan"
            ),
            .codex: AccountQuota(
                accountId: "synthetic-account-2",
                tool: .codex,
                buckets: [QuotaBucket(id: "weekly", title: "", shortLabel: "WK", usedPercent: 30)],
                plan: "Test Plan"
            )
        ]
        let ledger = FakeUsageLedger(summaries: [.empty], harnessRows: [], trendPoints: [])
        let rows = await assembler(accounts: accounts, ledger: ledger).quotaRows(now: now)
        XCTAssertEqual(rows.map(\.windowTitle), ["5 Hours", "Weekly", ""])
        for row in rows {
            XCTAssertFalse(row.windowTitle == "5h" || row.windowTitle == "WK")
        }
    }
}
