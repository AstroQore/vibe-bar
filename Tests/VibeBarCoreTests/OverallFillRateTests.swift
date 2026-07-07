import XCTest
@testable import VibeBarCore

final class OverallFillRateTests: XCTestCase {
    private func bucket(id: String, usedPercent: Double, groupTitle: String? = nil) -> QuotaBucket {
        QuotaBucket(
            id: id,
            title: id,
            shortLabel: id,
            usedPercent: usedPercent,
            resetAt: Date(),
            rawWindowSeconds: nil,
            groupTitle: groupTitle
        )
    }

    private func quota(accountId: String, tool: ToolType, buckets: [QuotaBucket]) -> AccountQuota {
        AccountQuota(accountId: accountId, tool: tool, buckets: buckets)
    }

    func testFourProvidersFullCoverage() {
        let quotas: [String: AccountQuota] = [
            "acct-claude": quota(accountId: "acct-claude", tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 50),
                bucket(id: "weekly_sonnet", usedPercent: 80, groupTitle: "Sonnet")
            ]),
            "acct-codex": quota(accountId: "acct-codex", tool: .codex, buckets: [
                bucket(id: "weekly", usedPercent: 70)
            ]),
            "acct-grok": quota(accountId: "acct-grok", tool: .grok, buckets: [
                bucket(id: "weekly", usedPercent: 30)
            ]),
            "acct-gemini": quota(accountId: "acct-gemini", tool: .gemini, buckets: [
                bucket(id: "gemini-2.5-pro", usedPercent: 60),
                bucket(id: "gemini-2.5-flash", usedPercent: 40)
            ])
        ]
        let mean = try? XCTUnwrap(OverallFillRate.average(quotas))
        // Claude weekly headline = 50, sub-buckets ignored.
        // Codex weekly = 70.
        // Grok weekly = 30.
        // Gemini = (60 + 40) / 2 = 50.
        // Overall = (50 + 70 + 30 + 50) / 4 = 50.
        XCTAssertEqual(mean ?? -1, 50, accuracy: 0.001)
    }

    func testEmptyQuotasReturnsNil() {
        XCTAssertNil(OverallFillRate.average([:]))
    }

    func testTwoProvidersOnly() {
        let quotas: [String: AccountQuota] = [
            "acct-claude": quota(accountId: "acct-claude", tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 80)
            ]),
            "acct-grok": quota(accountId: "acct-grok", tool: .grok, buckets: [
                bucket(id: "weekly", usedPercent: 20)
            ])
        ]
        let mean = try? XCTUnwrap(OverallFillRate.average(quotas))
        XCTAssertEqual(mean ?? -1, 50, accuracy: 0.001)
    }

    func testClaudeMissingHeadlineWeeklyIsSkipped() {
        let quotas: [String: AccountQuota] = [
            "acct-claude": quota(accountId: "acct-claude", tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 30),
                bucket(id: "weekly_sonnet", usedPercent: 90, groupTitle: "Sonnet")
            ]),
            "acct-grok": quota(accountId: "acct-grok", tool: .grok, buckets: [
                bucket(id: "weekly", usedPercent: 20)
            ])
        ]
        let mean = try? XCTUnwrap(OverallFillRate.average(quotas))
        // Claude contributes nothing (no headline weekly), so only Grok.
        XCTAssertEqual(mean ?? -1, 20, accuracy: 0.001)
    }

    func testMiscProvidersIgnored() {
        let quotas: [String: AccountQuota] = [
            "acct-kimi": quota(accountId: "acct-kimi", tool: .kimi, buckets: [
                bucket(id: "weekly", usedPercent: 99)
            ]),
            "acct-claude": quota(accountId: "acct-claude", tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 40)
            ])
        ]
        let mean = try? XCTUnwrap(OverallFillRate.average(quotas))
        XCTAssertEqual(mean ?? -1, 40, accuracy: 0.001)
    }

    func testMultipleAccountsPerToolAverageWithinTool() {
        let quotas: [String: AccountQuota] = [
            "acct-claude-a": quota(accountId: "acct-claude-a", tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 30)
            ]),
            "acct-claude-b": quota(accountId: "acct-claude-b", tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 70)
            ])
        ]
        let mean = try? XCTUnwrap(OverallFillRate.average(quotas))
        // Two claude accounts average inside the tool to (30+70)/2 = 50,
        // and that's the only tool, so overall = 50.
        XCTAssertEqual(mean ?? -1, 50, accuracy: 0.001)
    }
}
