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
          "seven_day_omelette": {"utilization": 50, "resets_at": "2026-05-01T00:00:00Z"},
          "seven_day_fable": {"utilization": 60, "resets_at": "2026-05-01T00:00:00Z"}
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

        let fable = buckets.first { $0.id == "weekly_fable" }!
        XCTAssertEqual(fable.usedPercent, 60)
        XCTAssertEqual(fable.groupTitle, "Fable")
        XCTAssertEqual(fable.shortLabel, "Fable wk")
        XCTAssertEqual(fable.rawWindowSeconds, 604_800)
    }

    /// Mirrors the live 2026-07 payload: legacy `seven_day_<model>` keys all
    /// null, per-model limits moved into the `limits` array. The Fable scoped
    /// entry must surface as `weekly_fable` with its own group.
    func testLimitsArraySurfacesScopedModel() throws {
        let json = """
        {
          "five_hour": {"utilization": 23.0, "resets_at": "2026-07-02T07:30:00Z"},
          "seven_day": {"utilization": 7.0, "resets_at": "2026-07-02T20:00:00Z"},
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 23, "severity": "normal",
             "resets_at": "2026-07-02T07:30:00Z", "scope": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 7, "severity": "normal",
             "resets_at": "2026-07-02T20:00:00Z", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 1, "severity": "normal",
             "resets_at": "2026-07-02T20:00:01Z",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": false}
          ]
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))

        // Legacy headline keys win — no duplicates from limits[].
        XCTAssertEqual(buckets.filter { $0.id == "five_hour" }.count, 1)
        XCTAssertEqual(buckets.filter { $0.id == "weekly" }.count, 1)
        XCTAssertEqual(buckets.first { $0.id == "five_hour" }?.usedPercent, 23.0)

        let fable = buckets.first { $0.id == "weekly_fable" }
        XCTAssertNotNil(fable)
        XCTAssertEqual(fable?.usedPercent, 1)
        XCTAssertEqual(fable?.groupTitle, "Fable")
        XCTAssertEqual(fable?.shortLabel, "Fable wk")
        XCTAssertEqual(fable?.rawWindowSeconds, 604_800)
        XCTAssertNotNil(fable?.resetAt)
    }

    /// When the legacy keys disappear entirely, the headline session /
    /// weekly_all entries in limits[] synthesize five_hour / weekly.
    func testLimitsArrayHeadlineFallback() throws {
        let json = """
        {
          "limits": [
            {"kind": "session", "group": "session", "percent": 41, "resets_at": "2026-07-02T07:30:00Z"},
            {"kind": "weekly_all", "group": "weekly", "percent": 12, "resets_at": "2026-07-02T20:00:00Z"}
          ]
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        let five = buckets.first { $0.id == "five_hour" }
        XCTAssertEqual(five?.usedPercent, 41)
        XCTAssertEqual(five?.rawWindowSeconds, 18_000)
        XCTAssertNil(five?.groupTitle)
        let weekly = buckets.first { $0.id == "weekly" }
        XCTAssertEqual(weekly?.usedPercent, 12)
        XCTAssertEqual(weekly?.shortLabel, "All models")
    }

    /// A scoped model Vibe Bar has never heard of still surfaces with a
    /// derived id and its display name as the group — zero code changes.
    func testLimitsArrayAutoSurfacesUnknownModel() throws {
        let json = """
        {
          "five_hour": {"utilization": 5},
          "seven_day": {"utilization": 6},
          "limits": [
            {"kind": "weekly_scoped", "group": "weekly", "percent": 33,
             "resets_at": "2026-07-02T20:00:01Z",
             "scope": {"model": {"id": "claude-zephyr-9", "display_name": "Zephyr 9"}, "surface": null}}
          ]
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        let zephyr = buckets.first { $0.id == "weekly_zephyr_9" }
        XCTAssertEqual(zephyr?.usedPercent, 33)
        XCTAssertEqual(zephyr?.groupTitle, "Zephyr 9")
    }

    /// Malformed / percent-less limits entries are skipped without throwing.
    func testLimitsArrayToleratesMalformedEntries() throws {
        let json = """
        {
          "five_hour": {"utilization": 5},
          "limits": [
            {"kind": "weekly_scoped", "group": "weekly",
             "scope": {"model": {"display_name": "Fable"}}},
            {"kind": 12},
            "not an object"
          ]
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        XCTAssertNil(buckets.first { $0.id == "weekly_fable" })
        XCTAssertEqual(buckets.first { $0.id == "five_hour" }?.usedPercent, 5)
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

    /// A present-but-null routine alias must NOT synthesize a misleading
    /// "0% used" Daily Routines section. Claude dropped Daily Routines from the
    /// usage payload, so absence of a real number means "don't show it".
    func testNullRoutineAliasDoesNotShowRoutineFallback() throws {
        let json = """
        {
          "five_hour": {"utilization": 5},
          "seven_day": {"utilization": 10},
          "seven_day_routines": null
        }
        """
        let buckets = try ClaudeResponseParser.parse(data: Data(json.utf8))
        XCTAssertNil(buckets.first { $0.id == "daily_routines" })
        XCTAssertEqual(buckets.count, 2)
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
        let raw = "Cookie: sessionKey=sk-ant-test-session-key; other=value"
        XCTAssertEqual(
            ClaudeWebCookieStore.normalizedCookieHeader(from: raw),
            "sessionKey=sk-ant-test-session-key; other=value"
        )
        XCTAssertEqual(
            ClaudeWebCookieStore.sessionKeyHeader(from: raw),
            "sessionKey=sk-ant-test-session-key"
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

    func testClaudeOrganizationIDPrefersChatCapableOrganization() throws {
        let json = """
        [
          {"uuid":"org-api","name":"API","capabilities":["api"]},
          {"uuid":"org-chat","name":"Claude","capabilities":["chat","api"]}
        ]
        """
        XCTAssertEqual(
            try ClaudeQuotaAdapter.parseOrganizationID(data: Data(json.utf8)),
            "org-chat"
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
          "seven_day_fable": null,
          "seven_day_sonnet": {
            "utilization": 1.0,
            "resets_at": "2026-04-30T20:00:00.765522+00:00"
          },
          "seven_day_cowork": null,
          "seven_day_omelette": {
            "utilization": 42.0,
            "resets_at": "2026-04-30T20:00:00.765533+00:00"
          },
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

        // Null routine-like keys (e.g. `seven_day_cowork: null`) no longer
        // synthesize a placeholder Daily Routines section — only a real
        // utilization number surfaces the group.
        XCTAssertNil(buckets.first { $0.id == "daily_routines" })

        // A present-but-null `seven_day_fable` (model exists in the schema but
        // is unused on this account) must not synthesize a bogus 0% section.
        XCTAssertNil(buckets.first { $0.id == "weekly_fable" })
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
