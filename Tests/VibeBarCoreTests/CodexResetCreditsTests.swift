import XCTest
@testable import VibeBarCore

final class CodexResetCreditsTests: XCTestCase {
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
            resetCredits: CodexResetCredits(availableCount: 2, nextExpiresAt: expiry)
        )
        let data = try JSONEncoder().encode(quota)
        let decoded = try JSONDecoder().decode(AccountQuota.self, from: data)
        XCTAssertEqual(decoded.resetCredits?.availableCount, 2)
        XCTAssertEqual(decoded.resetCredits?.nextExpiresAt, expiry)
    }
}
