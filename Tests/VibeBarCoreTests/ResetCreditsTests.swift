import XCTest
@testable import VibeBarCore

final class ResetCreditsTests: XCTestCase {
    // MARK: Inline count from /wham/usage

    func testInlineAvailableCountFromUsagePayload() {
        let json = """
        {
          "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000}},
          "rate_limit_reset_credits": {"available_count": 2}
        }
        """
        XCTAssertEqual(CodexResponseParser.parseResetCreditsAvailableCount(data: Data(json.utf8)), 2)
    }

    func testInlineAvailableCountAbsentReturnsNil() {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000}}}
        """
        XCTAssertNil(CodexResponseParser.parseResetCreditsAvailableCount(data: Data(json.utf8)))
    }

    // MARK: Dedicated /wham/rate-limit-reset-credits endpoint

    func testDedicatedEndpointDecodesCountAndSkipsStaleOrUnavailableExpiry() {
        let now = ISO8601DateFormatter().date(from: "2026-06-22T00:00:00Z")!
        // Four credits: one available-but-already-expired, two available in the
        // future, and one future-dated but not "available". Next expiry must be
        // the earliest *available, non-expired* one ("earlier", 2026-07-12) —
        // NOT the earlier-but-unavailable "future_status" (2026-07-10).
        let json = """
        {
          "credits": [
            {"id": "expired", "reset_type": "codex_rate_limits", "status": "available",
             "granted_at": "2026-05-18T00:39:53Z", "expires_at": "2026-06-17T00:39:53Z"},
            {"id": "later", "reset_type": "codex_rate_limits", "status": "available",
             "granted_at": "2026-06-18T00:39:53.731630Z", "expires_at": "2026-07-18T00:39:53.731630Z"},
            {"id": "earlier", "reset_type": "codex_rate_limits", "status": "available",
             "granted_at": "2026-06-12T04:03:43.263391Z", "expires_at": "2026-07-12T04:03:43.263391Z"},
            {"id": "future_status", "reset_type": "codex_rate_limits", "status": "future_status",
             "granted_at": "2026-06-12T04:03:43Z", "expires_at": "2026-07-10T04:03:43Z"}
          ],
          "available_count": 2
        }
        """
        let snapshot = CodexResetCreditsFetcher.parse(data: Data(json.utf8), now: now)
        XCTAssertEqual(snapshot?.availableCount, 2)
        XCTAssertEqual(snapshot?.availableExpirations?.count, 2)
        XCTAssertEqual(snapshot?.availableExpirations, snapshot?.availableExpirations?.sorted())

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(snapshot?.nextExpiresAt, fractional.date(from: "2026-07-12T04:03:43.263391Z"))
    }

    func testDedicatedEndpointEmptyCreditsGivesZeroCountNoExpiry() {
        let snapshot = CodexResetCreditsFetcher.parse(data: Data(#"{"credits":[],"available_count":0}"#.utf8))
        XCTAssertEqual(snapshot?.availableCount, 0)
        XCTAssertNil(snapshot?.nextExpiresAt)
    }

    func testDedicatedEndpointRejectsNegativeCount() {
        XCTAssertNil(CodexResetCreditsFetcher.parse(data: Data(#"{"credits":[],"available_count":-1}"#.utf8)))
    }

    // MARK: AccountQuota persistence

    func testAccountQuotaRoundTripsResetCredits() throws {
        let expiry = ISO8601DateFormatter().date(from: "2026-07-12T04:03:43Z")!
        let quota = AccountQuota(
            accountId: "codex",
            tool: .codex,
            buckets: [],
            resetCredits: ResetCredits(availableCount: 2, nextExpiresAt: expiry)
        )
        let data = try JSONEncoder().encode(quota)
        let decoded = try JSONDecoder().decode(AccountQuota.self, from: data)
        XCTAssertEqual(decoded.resetCredits?.availableCount, 2)
        XCTAssertEqual(decoded.resetCredits?.nextExpiresAt, expiry)
    }

    func testCarriedForwardDropsGrantsThatHaveLapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = now.addingTimeInterval(3_600)
        let credits = ResetCredits(
            availableCount: 3,
            availableExpirations: [now.addingTimeInterval(-60), soon, soon],
            tokens: [
                ResetCreditToken(id: "lapsed", remaining: 1, expiresAt: now.addingTimeInterval(-60)),
                ResetCreditToken(id: "live", remaining: 2, expiresAt: soon)
            ]
        )
        let carried = credits.carriedForward(now: now)
        XCTAssertEqual(carried.availableCount, 2)
        XCTAssertEqual(carried.availableExpirations, [soon, soon])
        XCTAssertEqual(carried.nextExpiresAt, soon)
        XCTAssertEqual(carried.tokens, credits.tokens)
    }

    func testSpendableCreditsKeepTheirOwnReach() {
        let sooner = Date(timeIntervalSince1970: 1_800_000_000)
        let later = sooner.addingTimeInterval(86_400)
        let credits = ResetCredits(
            availableCount: 3,
            availableExpirations: [later, sooner, later],
            tokens: [
                ResetCreditToken(id: "full", remaining: 2, expiresAt: later,
                                 clears: ["five_hour", "weekly", "weekly_fable"]),
                ResetCreditToken(id: "fable", remaining: 1, expiresAt: sooner, clears: ["weekly_fable"]),
                ResetCreditToken(id: "spent", remaining: 0, expiresAt: sooner, clears: ["five_hour"])
            ]
        )
        XCTAssertEqual(credits.spendable.map(\.expiresAt), [sooner, later, later])
        XCTAssertEqual(credits.spendable.map(\.clears), [
            ["weekly_fable"],
            ["five_hour", "weekly", "weekly_fable"],
            ["five_hour", "weekly", "weekly_fable"]
        ])
        // A provider with no per-credit reach still lists each credit.
        XCTAssertEqual(ResetCredits(availableCount: 1, availableExpirations: [sooner]).spendable.map(\.clears), [[]])
    }

    func testQuotaGetCarriesResetCreditsWithoutGrantIds() throws {
        let sooner = Date(timeIntervalSince1970: 1_800_000_000)
        let later = sooner.addingTimeInterval(86_400)
        let quota = AccountQuota(
            accountId: "web-claude", tool: .claude,
            buckets: [QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Wk", usedPercent: 10)],
            queriedAt: sooner,
            resetCredits: ResetCredits(
                availableCount: 2,
                availableExpirations: [later, sooner],
                tokens: [
                    ResetCreditToken(id: "reset-grant-secret", remaining: 1, expiresAt: later,
                                     clears: ["five_hour", "weekly", "weekly_fable"]),
                    ResetCreditToken(id: "reset-grant-other", remaining: 1, expiresAt: sooner, clears: ["weekly_fable"])
                ]
            )
        )
        let dto = MCPQuotaAccountDTO(quota: quota, lastUpdated: sooner, lastAttempted: sooner, inFlight: false, error: nil)
        let data = try JSONEncoder().encode(dto)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("reset-grant"))

        let wire = try XCTUnwrap(JSONDecoder().decode(MCPQuotaAccountDTO.self, from: data).resetCredits)
        XCTAssertEqual(wire.availableCount, 2)
        XCTAssertEqual(wire.nextExpiresAt, sooner)
        XCTAssertEqual(wire.credits.map(\.expiresAt), [sooner, later])
        XCTAssertEqual(wire.credits.map(\.clears), [["weekly_fable"], ["five_hour", "weekly", "weekly_fable"]])

        // No credits reported is absent, not an empty object; none left is zero.
        var none = quota
        none.resetCredits = nil
        XCTAssertNil(MCPQuotaAccountDTO(quota: none, lastUpdated: nil, lastAttempted: nil, inFlight: false, error: nil).resetCredits)
        none.resetCredits = ResetCredits(availableCount: 0, tokens: [])
        let spent = MCPQuotaAccountDTO(quota: none, lastUpdated: nil, lastAttempted: nil, inFlight: false, error: nil).resetCredits
        XCTAssertEqual(spent?.availableCount, 0)
        XCTAssertEqual(spent?.credits, [])
    }
}
