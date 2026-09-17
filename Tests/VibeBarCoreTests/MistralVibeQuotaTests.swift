import XCTest
@testable import VibeBarCore

/// Mistral Vibe's Monthly quota comes from the console's `billing.vibeUsage`
/// query, authorised by the console's `ory_session_*` and `csrftoken`
/// cookies; the plan name comes from the CLI's whoami cache.
final class MistralVibeQuotaTests: XCTestCase {
    func testUsageResponseBecomesTheMonthlyBucket() throws {
        let data = Data(#"[{"result":{"data":{"json":{"usage_percentage":37.5,"reset_at":"2026-10-01T00:00:00.000Z"}}}}]"#.utf8)
        let bucket = try MistralVibeResponseParser.parse(data: data)
        XCTAssertEqual(bucket.id, "monthly")
        XCTAssertEqual(bucket.title, "Monthly")
        XCTAssertEqual(bucket.usedPercent, 37.5)
        XCTAssertEqual(bucket.resetAt, ServiceStatusClient.flexibleDate(from: "2026-10-01T00:00:00.000Z"))
    }

    func testAMissingResetIsAllowedButABadPercentIsNot() throws {
        XCTAssertNil(try MistralVibeResponseParser.parse(
            data: Data(#"[{"result":{"data":{"json":{"usage_percentage":0,"reset_at":null}}}}]"#.utf8)
        ).resetAt)
        for body in [
            #"[{"result":{"data":{"json":{"usage_percentage":140}}}}]"#,
            #"[{"result":{"data":{"json":{"usage_percentage":true}}}}]"#,
            #"{"error":{"message":"UNAUTHORIZED"}}"#,
            #"[]"#
        ] {
            XCTAssertThrowsError(try MistralVibeResponseParser.parse(data: Data(body.utf8)), body)
        }
    }

    /// Only the session and CSRF cookies travel, and the CSRF token is
    /// echoed in its header.
    func testTheRequestCarriesOnlyTheConsoleSessionCookies() throws {
        let header = "_ga=GA1.1.1; ory_session_examplestack=synthetic-session; csrftoken=synthetic-csrf; intercom-id=abc"
        let request = try XCTUnwrap(MistralVibeQuotaAdapter.makeRequest(cookieHeader: header))
        XCTAssertEqual(request.url?.host, "console.mistral.ai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
                       "csrftoken=synthetic-csrf; ory_session_examplestack=synthetic-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRFToken"), "synthetic-csrf")
        XCTAssertFalse(request.httpShouldHandleCookies)

        XCTAssertNil(MistralVibeQuotaAdapter.makeRequest(cookieHeader: "csrftoken=only"))
        XCTAssertNil(MistralVibeQuotaAdapter.makeRequest(cookieHeader: "ory_session_x=only"))
        XCTAssertNil(MistralVibeQuotaAdapter.makeRequest(cookieHeader: "ory_session_x=s; csrftoken=bad\r\ninjected"))
    }

    /// The session cookie's name carries a per-deployment suffix, so the
    /// spec keeps it by prefix and needs both cookies to count as signed in.
    func testTheCookieSpecKeepsTheSessionByPrefix() {
        let spec = MistralVibeQuotaAdapter.cookieSpec
        XCTAssertEqual(
            spec.minimizedHeader(from: "a=1; ory_session_examplestack=s; csrftoken=c; b=2"),
            "ory_session_examplestack=s; csrftoken=c"
        )
        XCTAssertNil(spec.minimizedHeader(from: "csrftoken=c; b=2"))
        XCTAssertNil(spec.minimizedHeader(from: "ory_session_examplestack=s"))
        XCTAssertEqual(MiscCookieSpecCatalog.spec(for: .mistralVibe)?.tool, .mistralVibe)
    }

    /// A pasted header keeps the prefixed session cookie the refresh needs,
    /// and a paste without it is refused rather than stored half-usable.
    func testAManualPasteKeepsThePrefixedSessionCookie() {
        let spec = MistralVibeQuotaAdapter.cookieSpec
        XCTAssertEqual(
            spec.manualPasteHeader(from: "ory_session_examplestack=s; csrftoken=c; _ga=GA1.1.1"),
            "ory_session_examplestack=s; csrftoken=c"
        )
        XCTAssertNil(spec.manualPasteHeader(from: "csrftoken=c; _ga=GA1.1.1"))
    }

    /// A spec without prefixes keeps its old any-one-name rule.
    func testSpecsWithoutPrefixesAreUnchanged() {
        let spec = MiscCookieResolver.Spec(
            tool: .kimi, domains: ["example.com"],
            requiredNames: ["a", "b"], credentialNames: ["a", "b"]
        )
        XCTAssertEqual(spec.minimizedHeader(from: "a=1; c=3"), "a=1")
        XCTAssertEqual(spec.manualPasteHeader(from: "a=1; c=3"), "a=1")
    }

    func testWhoAmIPlanTitlesFollowTheCLI() {
        XCTAssertEqual(MistralVibeWhoAmICache.planTitle(type: "chat", name: "INDIVIDUAL"), "Pro")
        XCTAssertEqual(MistralVibeWhoAmICache.planTitle(type: "chat", name: "TEAM"), "Pro")
        XCTAssertEqual(MistralVibeWhoAmICache.planTitle(type: "chat", name: "FREE"), "Free")
        XCTAssertEqual(MistralVibeWhoAmICache.planTitle(type: "api", name: "SCALE"), "Scale")
        XCTAssertEqual(MistralVibeWhoAmICache.planTitle(type: "mistral_code", name: "E"), "Mistral Code Enterprise")
        XCTAssertNil(MistralVibeWhoAmICache.planTitle(type: "chat", name: "SOMETHING_NEW"))

        let cache = Data(#"""
        {
          "old": {"stored_at_timestamp": 100, "payload": {"plan_type": "chat", "plan_name": "FREE", "customer_id": "cus_example"}},
          "new": {"stored_at_timestamp": 200, "payload": {"plan_type": "chat", "plan_name": "individual"}}
        }
        """#.utf8)
        XCTAssertEqual(MistralVibeWhoAmICache.planTitle(cacheData: cache), "Pro")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .mistralVibe, rawPlan: "Pro"), "Mistral Vibe Pro")
    }
}
