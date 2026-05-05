import XCTest
@testable import VibeBarCore

final class ClaudeParserTests: XCTestCase {
    /// Daily Routines prefers the separate run-budget endpoint (see
    /// `ClaudeRoutinesFetcher`), but this parser keeps the usage-payload
    /// routine aliases as a visible fallback.

    func testSpecExampleProducesFiveHourAndWeekly() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 56.0,
            "resets_at": "2026-04-29T12:00:00Z"
          },
          "seven_day": {
            "utilization": 13.0,
            "resets_at": "2026-05-04T12:00:00Z"
          }
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(buckets.count, 2)

        let five = buckets.first { $0.id == "five_hour" }!
        XCTAssertEqual(five.title, "5 Hours")
        XCTAssertEqual(five.shortLabel, "5h")
        XCTAssertEqual(five.usedPercent, 56)
        XCTAssertEqual(five.remainingPercent, 44)
        XCTAssertNil(five.groupTitle)

        let weekly = buckets.first { $0.id == "weekly" }!
        XCTAssertEqual(weekly.title, "Weekly")
        XCTAssertEqual(weekly.shortLabel, "All models")
        XCTAssertEqual(weekly.usedPercent, 13)
        XCTAssertEqual(weekly.remainingPercent, 87)
        XCTAssertNil(weekly.groupTitle)

        // Sanity: ISO8601 reset parses
        XCTAssertNotNil(five.resetAt)
        XCTAssertNotNil(weekly.resetAt)

        // No routine alias in this payload, so the fallback bucket is absent.
        XCTAssertNil(buckets.first { $0.id == "daily_routines" })
    }

    /// Each Claude model dimension is filed under its own group title (Sonnet,
    /// Designs, Opus, …) so the popover renders one section per model.
    func testEachModelGetsItsOwnGroup() throws {
        let json = """
        {
          "five_hour": {"utilization": 10},
          "seven_day": {"utilization": 20},
          "seven_day_opus": {"utilization": 30, "resets_at": "2026-05-01T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 40, "resets_at": "2026-05-01T00:00:00Z"},
          "seven_day_omelette": {"utilization": 50, "resets_at": "2026-05-01T00:00:00Z"}
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))

        let sonnet = buckets.first { $0.id == "weekly_sonnet" }!
        XCTAssertEqual(sonnet.usedPercent, 40)
        XCTAssertEqual(sonnet.groupTitle, "Sonnet")

        let designs = buckets.first { $0.id == "weekly_design" }!
        XCTAssertEqual(designs.usedPercent, 50)
        XCTAssertEqual(designs.groupTitle, "Designs")

        let opus = buckets.first { $0.id == "weekly_opus" }!
        XCTAssertEqual(opus.usedPercent, 30)
        XCTAssertEqual(opus.groupTitle, "Opus")
    }

    /// `seven_day_cowork` is kept as a visible fallback for Daily Routines
    /// when the dedicated `/v1/code/routines/run-budget` cookie fetch fails.
    func testCoworkKeyProducesRoutineFallback() throws {
        let json = """
        {
          "five_hour": {"utilization": 5},
          "seven_day": {"utilization": 10},
          "seven_day_cowork": {"utilization": 33.3, "resets_at": "2026-05-01T00:00:00Z"}
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        let routine = buckets.first { $0.id == "daily_routines" }!
        XCTAssertEqual(routine.groupTitle, "Daily Routines")
        XCTAssertEqual(routine.shortLabel, "Routine wk")
        XCTAssertEqual(routine.title, "Weekly")
        XCTAssertEqual(routine.usedPercent, 33.3)
        XCTAssertEqual(routine.rawWindowSeconds, 604_800)
        XCTAssertEqual(buckets.count, 3)
    }

    func testNullRoutineAliasStillShowsRoutineFallback() throws {
        let json = """
        {
          "five_hour": {"utilization": 5},
          "seven_day": {"utilization": 10},
          "seven_day_routines": null
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        let routine = buckets.first { $0.id == "daily_routines" }!
        XCTAssertEqual(routine.usedPercent, 0)
        XCTAssertEqual(routine.title, "Weekly")
        XCTAssertEqual(routine.shortLabel, "Routine wk")
        XCTAssertEqual(routine.rawWindowSeconds, 604_800)
        XCTAssertEqual(routine.groupTitle, "Daily Routines")
    }

    func testRoutinesFetcherParsesStringFields() {
        // The live API returns `used` and `limit` as strings.
        let json = """
        {"limit":"15","unified_billing_enabled":true,"used":"3"}
        """
        let result = ClaudeRoutinesFetcher.parse(data: Data(json.utf8))!
        XCTAssertEqual(result.used, 3)
        XCTAssertEqual(result.limit, 15)
        XCTAssertEqual(result.usedPercent, 20.0)
        XCTAssertTrue(result.unifiedBillingEnabled)
    }

    func testRoutinesFetcherToleratesIntFields() {
        let json = """
        {"limit":15,"unified_billing_enabled":false,"used":7}
        """
        let result = ClaudeRoutinesFetcher.parse(data: Data(json.utf8))!
        XCTAssertEqual(result.used, 7)
        XCTAssertEqual(result.limit, 15)
        XCTAssertFalse(result.unifiedBillingEnabled)
    }

    func testRoutinesFetcherReturnsNilWhenLimitIsZero() {
        let json = """
        {"limit":"0","used":"0"}
        """
        XCTAssertNil(ClaudeRoutinesFetcher.parse(data: Data(json.utf8)))
    }

    func testClaudeCookieStoreNormalizesCookieHeader() {
        let raw = "Cookie: sessionKey=sk-ant-test; other=value"
        XCTAssertEqual(
            ClaudeWebCookieStore.normalizedCookieHeader(from: raw),
            "sessionKey=sk-ant-test; other=value"
        )
        XCTAssertEqual(
            ClaudeWebCookieStore.sessionKeyHeader(from: raw),
            "sessionKey=sk-ant-test"
        )
    }

    func testClaudeOrganizationIDParsesArrayResponse() throws {
        let json = """
        [{"uuid":"org-123","name":"Primary"}]
        """
        XCTAssertEqual(
            try ClaudeQuotaAdapter.parseOrganizationID(data: Data(json.utf8)),
            "org-123"
        )
    }

    func testClaudeOrganizationIDParsesNestedResponse() throws {
        let json = """
        {"organizations":[{"id":"org-456"}]}
        """
        XCTAssertEqual(
            try ClaudeQuotaAdapter.parseOrganizationID(data: Data(json.utf8)),
            "org-456"
        )
    }

    func testWebUsageBucketsIncludeDesignWhenPresent() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 11.0,
            "resets_at": "2026-04-29T08:50:00.765492+00:00"
          },
          "seven_day": {
            "utilization": 13.0,
            "resets_at": "2026-04-30T20:00:00.765512+00:00"
          },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": {
            "utilization": 1.0,
            "resets_at": "2026-04-30T20:00:00.765522+00:00"
          },
          "seven_day_cowork": null,
          "seven_day_omelette": {
            "utilization": 42.0,
            "resets_at": "2026-04-30T20:00:00.765533+00:00"
          },
          "iguana_necktie": null,
          "omelette_promotional": null,
          "extra_usage": {
            "is_enabled": false,
            "monthly_limit": null,
            "used_credits": null,
            "utilization": 9,
            "currency": null
          }
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))

        // Sonnet has its own group
        let sonnet = buckets.first { $0.id == "weekly_sonnet" }!
        XCTAssertEqual(sonnet.groupTitle, "Sonnet")
        XCTAssertEqual(sonnet.usedPercent, 1)

        // Designs has its own group
        let design = buckets.first { $0.id == "weekly_design" }!
        XCTAssertEqual(design.groupTitle, "Designs")
        XCTAssertEqual(design.usedPercent, 42)
        XCTAssertNotNil(design.resetAt)

        // Null routine-like keys still keep the Daily Routines group visible.
        let routine = buckets.first { $0.id == "daily_routines" }!
        XCTAssertEqual(routine.usedPercent, 0)
        XCTAssertEqual(routine.groupTitle, "Daily Routines")
    }

    func testParseExtraUsageDecodesCentToDollar() {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 5000,
            "used_credits": 1234,
            "utilization": 24.68,
            "currency": "USD"
          }
        }
        """
        let extras = ClaudeResponseParser.parseExtraUsage(data: Data(json.utf8))
        XCTAssertNotNil(extras)
        XCTAssertEqual(extras?.tool, .claude)
        XCTAssertEqual(extras?.extraUsageEnabled, true)
        XCTAssertEqual(extras?.extraUsageSpendUSD ?? -1, 12.34, accuracy: 0.0001)
        XCTAssertEqual(extras?.extraUsageLimitUSD ?? -1, 50.0, accuracy: 0.0001)
    }

    func testEmptyResponseThrowsParseFailure() {
        // Empty `{}` produces no buckets — parseFailure.
        let data = Data("{}".utf8)
        XCTAssertThrowsError(try ClaudeResponseParser.parse(data: data)) { error in
            guard case QuotaError.parseFailure = error else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
        }
    }

    func testParseFailureOnInvalidJSON() {
        XCTAssertThrowsError(try ClaudeResponseParser.parse(data: Data("not json".utf8))) { error in
            guard case QuotaError.parseFailure = error else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
        }
    }

    func testFractionalSecondsISO() throws {
        let json = """
        {"five_hour": {"utilization": 50, "resets_at": "2026-04-29T12:00:00.500Z"}}
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        let five = buckets.first { $0.id == "five_hour" }!
        XCTAssertNotNil(five.resetAt)
    }

    func testFallbackResetAtKeyAndUsedPercent() throws {
        let json = """
        {"five_hour": {"used_percent": 25, "reset_at": "2026-04-29T12:00:00Z"}}
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        let five = buckets.first { $0.id == "five_hour" }!
        XCTAssertEqual(five.usedPercent, 25)
        XCTAssertEqual(five.remainingPercent, 75)
        XCTAssertNotNil(five.resetAt)
    }
}
