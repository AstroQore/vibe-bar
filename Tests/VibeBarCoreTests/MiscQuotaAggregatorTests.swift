import XCTest
@testable import VibeBarCore

final class MiscQuotaAggregatorTests: XCTestCase {
    private let account = AccountIdentity(
        id: "acct-1",
        tool: .volcengine,
        email: "user@example.com",
        source: .browserCookie
    )

    private let queriedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testTwoSlotsAverageZeroAndHundredToFifty() {
        let resetA = queriedAt.addingTimeInterval(3600)
        let resetB = queriedAt.addingTimeInterval(7200)

        let quotaA = AccountQuota(
            accountId: account.id,
            tool: .volcengine,
            buckets: [
                QuotaBucket(
                    id: "volcengine.session",
                    title: "5 Hours",
                    shortLabel: "5h",
                    usedPercent: 0,
                    resetAt: resetA,
                    rawWindowSeconds: 5 * 3600
                )
            ],
            plan: "Coding Plan Pro"
        )
        let quotaB = AccountQuota(
            accountId: account.id,
            tool: .volcengine,
            buckets: [
                QuotaBucket(
                    id: "volcengine.session",
                    title: "5 Hours",
                    shortLabel: "5h",
                    usedPercent: 100,
                    resetAt: resetB,
                    rawWindowSeconds: 5 * 3600
                )
            ],
            plan: "Coding Plan Lite"
        )

        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .volcengine,
            account: account,
            results: [
                .init(slotID: UUID(), sourceLabel: "Chrome (Default)", outcome: .success(quotaA)),
                .init(slotID: UUID(), sourceLabel: "Manual paste", outcome: .success(quotaB))
            ],
            queriedAt: queriedAt
        )

        XCTAssertNil(aggregated.error)
        XCTAssertEqual(aggregated.buckets.count, 1)
        XCTAssertEqual(aggregated.buckets[0].usedPercent, 50, accuracy: 0.0001)
        XCTAssertEqual(aggregated.buckets[0].resetAt, resetA)
        XCTAssertEqual(aggregated.plan, "Coding Plan Pro")
        XCTAssertEqual(aggregated.email, "user@example.com")
    }

    func testTwoSlotsAverageTwentyAndEightyToFifty() {
        let bucketA = QuotaBucket(
            id: "tencentHunyuan.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            usedPercent: 20
        )
        let bucketB = QuotaBucket(
            id: "tencentHunyuan.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            usedPercent: 80
        )

        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .tencentHunyuan,
            account: account,
            results: [
                .init(slotID: nil, sourceLabel: "A", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .tencentHunyuan, buckets: [bucketA]
                ))),
                .init(slotID: nil, sourceLabel: "B", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .tencentHunyuan, buckets: [bucketB]
                )))
            ],
            queriedAt: queriedAt
        )

        XCTAssertEqual(aggregated.buckets.first?.usedPercent ?? 0, 50, accuracy: 0.0001)
    }

    func testNonOverlappingBucketIdsRetainBoth() {
        let session = QuotaBucket(
            id: "volcengine.session",
            title: "5 Hours",
            shortLabel: "5h",
            usedPercent: 10
        )
        let weekly = QuotaBucket(
            id: "volcengine.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            usedPercent: 75
        )
        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .volcengine,
            account: account,
            results: [
                .init(slotID: nil, sourceLabel: "A", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .volcengine, buckets: [session]
                ))),
                .init(slotID: nil, sourceLabel: "B", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .volcengine, buckets: [weekly]
                )))
            ],
            queriedAt: queriedAt
        )

        XCTAssertEqual(aggregated.buckets.count, 2)
        let bySession = aggregated.buckets.first(where: { $0.id == "volcengine.session" })
        let byWeekly = aggregated.buckets.first(where: { $0.id == "volcengine.weekly" })
        XCTAssertEqual(bySession?.usedPercent ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(byWeekly?.usedPercent ?? 0, 75, accuracy: 0.0001)
    }

    func testOneSuccessAndOneFailureUsesOnlySuccess() {
        let bucket = QuotaBucket(
            id: "kimi.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            usedPercent: 42
        )
        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .kimi,
            account: account,
            results: [
                .init(slotID: nil, sourceLabel: "Good", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .kimi, buckets: [bucket]
                ))),
                .init(slotID: nil, sourceLabel: "Stale", outcome: .failure(.needsLogin))
            ],
            queriedAt: queriedAt
        )

        XCTAssertNil(aggregated.error)
        XCTAssertEqual(aggregated.buckets.count, 1)
        XCTAssertEqual(aggregated.buckets[0].usedPercent, 42, accuracy: 0.0001)
    }

    func testAllFailuresSurfaceFirstError() {
        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .volcengine,
            account: account,
            results: [
                .init(slotID: nil, sourceLabel: "A", outcome: .failure(.needsLogin)),
                .init(slotID: nil, sourceLabel: "B", outcome: .failure(.rateLimited))
            ],
            queriedAt: queriedAt
        )

        XCTAssertEqual(aggregated.error, QuotaError.needsLogin)
        XCTAssertTrue(aggregated.buckets.isEmpty)
    }

    func testEarliestResetWins() {
        let early = queriedAt.addingTimeInterval(60)
        let late = queriedAt.addingTimeInterval(3600)

        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .mimo,
            account: account,
            results: [
                .init(slotID: nil, sourceLabel: "Late", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .mimo, buckets: [
                        QuotaBucket(id: "mimo.month", title: "Monthly", shortLabel: "Mo", usedPercent: 30, resetAt: late)
                    ]
                ))),
                .init(slotID: nil, sourceLabel: "Early", outcome: .success(AccountQuota(
                    accountId: account.id, tool: .mimo, buckets: [
                        QuotaBucket(id: "mimo.month", title: "Monthly", shortLabel: "Mo", usedPercent: 70, resetAt: early)
                    ]
                )))
            ],
            queriedAt: queriedAt
        )

        XCTAssertEqual(aggregated.buckets.first?.resetAt, early)
        XCTAssertEqual(aggregated.buckets.first?.usedPercent ?? 0, 50, accuracy: 0.0001)
    }
}
