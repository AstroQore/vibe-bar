import XCTest
@testable import VibeBarCore

/// Every tool, called through the real dispatch path against fixed fixtures.
final class MCPToolCallTests: XCTestCase {
    private var source = FakeMCPDataSource()
    private var server = MCPServer(dataSource: FakeMCPDataSource())

    override func setUp() {
        super.setUp()
        source = FakeMCPDataSource()
        server = MCPServer(dataSource: source, now: { FakeMCPDataSource.epoch })
    }

    private func call(_ tool: String, _ arguments: MCPJSON = .object([:])) async throws -> MCPJSON {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(id: 1, tool: tool, arguments: arguments))
        )
        if let error = response["error"] {
            throw MCPTestError("Unexpected JSON-RPC error: \(error)")
        }
        XCTAssertFalse(MCPTestSupport.isError(response), "\(MCPTestSupport.errorText(response) ?? "")")
        return try MCPTestSupport.structured(response)
    }

    // MARK: - quota

    func testQuotaGetProjectsBothAxesAndMasksTheEmail() async throws {
        let result = try await call("quota.get")
        XCTAssertEqual(result["generatedAt"]?.stringValue, "2026-01-01T00:00:00Z")
        let accounts = try XCTUnwrap(result["accounts"]?.arrayValue)
        XCTAssertEqual(accounts.count, 2)

        let claude = try XCTUnwrap(accounts.first { $0["tool"]?.stringValue == "claude" })
        XCTAssertEqual(claude["company"]?.stringValue, "Anthropic")
        XCTAssertEqual(claude["subProvider"]?.stringValue, "Claude")
        XCTAssertEqual(claude["plan"]?.stringValue, "Max")
        XCTAssertEqual(claude["email"]?.stringValue, "s••••@example.com")
        XCTAssertEqual(claude["inFlight"]?.boolValue, false)

        let buckets = try XCTUnwrap(claude["buckets"]?.arrayValue)
        let fiveHour = try XCTUnwrap(buckets.first { $0["id"]?.stringValue == "five_hour" })
        XCTAssertEqual(fiveHour["usedPercent"]?.doubleValue, 42.5)
        XCTAssertEqual(fiveHour["remainingPercent"]?.doubleValue, 57.5)
        // The bucket label is expanded by QuotaBucket, not by the projection.
        XCTAssertEqual(fiveHour["shortLabel"]?.stringValue, "5 Hours")
        XCTAssertEqual(fiveHour["windowSeconds"]?.intValue, 18_000)
        XCTAssertNil(fiveHour["forecast"], "Forecasts are opt-in.")
    }

    func testQuotaGetFiltersByTool() async throws {
        let result = try await call("quota.get", .object(["tools": .array([.string("codex")])]))
        let accounts = try XCTUnwrap(result["accounts"]?.arrayValue)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?["tool"]?.stringValue, "codex")
    }

    func testQuotaRefreshDefaultsToStaleOnly() async throws {
        let result = try await call("quota.refresh")
        XCTAssertEqual(result["mode"]?.stringValue, "stale-only")
        XCTAssertEqual(result["triggered"]?.boolValue, true)
        XCTAssertEqual(source.refreshCalls.count, 1)
        XCTAssertEqual(source.refreshCalls.first?.force, false)
    }

    /// A forced refresh hits every provider's API, so a second one inside the
    /// window is answered rather than performed.
    func testForcedRefreshIsThrottled() async throws {
        let first = try await call("quota.refresh", .object(["force": .bool(true)]))
        XCTAssertEqual(first["triggered"]?.boolValue, true)

        let second = try await call("quota.refresh", .object(["force": .bool(true)]))
        XCTAssertEqual(second["triggered"]?.boolValue, false)
        XCTAssertTrue(second["message"]?.stringValue?.contains("Try again") ?? false)
        XCTAssertEqual(source.refreshCalls.count, 1, "The second force must not reach the app.")

        // The stale-only path is self-limiting and stays available.
        _ = try await call("quota.refresh")
        XCTAssertEqual(source.refreshCalls.count, 2)
    }

    /// A refresh the app declined never starts the clock, or one disabled
    /// toggle would lock the tool out for twenty seconds at a time.
    func testARefusedForcedRefreshDoesNotStartTheThrottle() async throws {
        source.refreshTriggered = false
        _ = try await call("quota.refresh", .object(["force": .bool(true)]))
        let second = try await call("quota.refresh", .object(["force": .bool(true)]))
        XCTAssertEqual(source.refreshCalls.count, 2)
        XCTAssertFalse(second["message"]?.stringValue?.contains("Try again") ?? false)
    }

    /// Two agents can call `quota.refresh {force:true}` at the same instant.
    /// Admission has to be decided before the data source is awaited, or both
    /// read an expired timestamp, both pass, and every provider's API is hit
    /// twice — the exact thing the throttle exists to prevent.
    func testConcurrentForcedRefreshesAdmitExactlyOne() async throws {
        source.refreshDuration = .milliseconds(200)
        async let first = call("quota.refresh", .object(["force": .bool(true)]))
        async let second = call("quota.refresh", .object(["force": .bool(true)]))
        let results = try await [first, second]

        XCTAssertEqual(
            results.filter { $0["triggered"]?.boolValue == true }.count,
            1,
            "Exactly one of two simultaneous forced refreshes may trigger."
        )
        XCTAssertEqual(source.refreshCalls.count, 1, "The loser must not reach the app at all.")
        XCTAssertTrue(
            results.contains { $0["message"]?.stringValue?.contains("Try again") ?? false },
            "The loser is told when to retry."
        )
    }

    /// The stale-only path takes the same `tools` filter as the forced one:
    /// asking about one provider must not refresh the rest.
    func testStaleOnlyRefreshPassesTheToolsFilterThrough() async throws {
        let result = try await call("quota.refresh", .object(["tools": .array([.string("codex")])]))
        XCTAssertEqual(result["mode"]?.stringValue, "stale-only")
        XCTAssertEqual(source.refreshCalls.count, 1)
        XCTAssertEqual(source.refreshCalls.first?.tools, [.codex])
        XCTAssertEqual(source.refreshCalls.first?.force, false)
    }

    /// An explicitly empty list is a no-op rather than "everything", the same
    /// rule `optionalEnumList` applies everywhere else.
    func testStaleOnlyRefreshKeepsAnEmptyToolsListEmpty() async throws {
        _ = try await call("quota.refresh", .object(["tools": .array([])]))
        XCTAssertEqual(source.refreshCalls.first?.tools, [])
    }

    // MARK: - usage

    func testUsageSummaryDefaultsToThirtyDaysAndReportsBothMoneyUnits() async throws {
        let result = try await call("usage.summary")
        XCTAssertEqual(result["requests"]?.intValue, 120)
        XCTAssertEqual(result["unpricedRequests"]?.intValue, 3)
        XCTAssertEqual(result["costMicros"]?.intValue, 4_560_000)
        XCTAssertEqual(result["costUSD"]?.doubleValue, 4.56)
        XCTAssertEqual(result["totalTokens"]?.intValue, 10_000)
        XCTAssertNil(result["rows"], "Rows only exist for an explicit groupBy.")

        let filter = try XCTUnwrap(source.lastUsageFilter)
        XCTAssertEqual(filter.range.end, FakeMCPDataSource.epoch)
        XCTAssertEqual(filter.range.duration, 30 * 86_400, accuracy: 1)
        XCTAssertNil(filter.tools)
        XCTAssertNil(filter.harnesses)
    }

    func testUsageSummaryGroupedByHarnessSpeaksTheUsageAxis() async throws {
        let result = try await call("usage.summary", .object(["groupBy": .string("harness")]))
        XCTAssertEqual(result["groupBy"]?.stringValue, "harness")
        let row = try XCTUnwrap(result["rows"]?.arrayValue?.first)
        XCTAssertEqual(row["key"]?.stringValue, "claudeCode")
        XCTAssertEqual(row["label"]?.stringValue, "Claude Code")
        XCTAssertEqual(row["company"]?.stringValue, "Anthropic")
        XCTAssertEqual(row["costUSD"]?.doubleValue, 3.0)
    }

    func testUsageSummaryHonoursExplicitRangeAndFilters() async throws {
        _ = try await call("usage.summary", .object([
            "from": .string("2025-12-01T00:00:00Z"),
            "to": .string("2025-12-08T00:00:00Z"),
            "tools": .array([.string("claude")]),
            "harnesses": .array([.string("claudeCode"), .string("claudeCowork")]),
            "models": .array([.string("claude-opus-4-7")])
        ]))
        let filter = try XCTUnwrap(source.lastUsageFilter)
        XCTAssertEqual(filter.range.duration, 7 * 86_400, accuracy: 1)
        XCTAssertEqual(filter.tools, [.claude])
        XCTAssertEqual(filter.harnesses, [.claudeCode, .claudeCowork])
        XCTAssertEqual(filter.models, ["claude-opus-4-7"])
    }

    /// An empty list means "nothing matches" to the ledger. Widening it to
    /// "everything" would answer a different question than the one asked.
    func testAnEmptyFilterListStaysEmpty() async throws {
        _ = try await call("usage.summary", .object(["tools": .array([])]))
        XCTAssertEqual(source.lastUsageFilter?.tools, [])
    }

    func testAnInvertedWindowIsRejected() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(
                id: 1,
                tool: "usage.summary",
                arguments: .object([
                    "from": .string("2026-02-01T00:00:00Z"),
                    "to": .string("2026-01-01T00:00:00Z")
                ])
            ))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    func testABareCalendarDayParses() async throws {
        _ = try await call("usage.summary", .object(["from": .string("2025-12-25")]))
        XCTAssertNotNil(source.lastUsageFilter)
    }

    func testUsageTrendPassesTheBucketThroughAndReportsTheResolvedOne() async throws {
        let result = try await call("usage.trend", .object([
            "days": .int(2),
            "bucket": .string("hour")
        ]))
        XCTAssertEqual(source.lastTrendBucket, .hour)
        XCTAssertEqual(result["bucket"]?.stringValue, "hour")
        let point = try XCTUnwrap(result["points"]?.arrayValue?.first)
        XCTAssertEqual(point["totalTokens"]?.intValue, 100)
        XCTAssertEqual(point["costUSD"]?.doubleValue, 1.5)
    }

    func testUsageRequestsRoundTripsAnOpaqueCursor() async throws {
        let first = try await call("usage.requests", .object(["pageSize": .int(25)]))
        XCTAssertEqual(source.lastRequestPageSize, 25)
        XCTAssertNil(source.lastRequestCursor)
        let cursor = try XCTUnwrap(first["nextCursor"]?.stringValue)

        _ = try await call("usage.requests", .object(["cursor": .string(cursor)]))
        XCTAssertEqual(source.lastRequestCursor, UsageRequestCursor(ts: 1_767_225_600, id: 7))
    }

    func testAHandEditedCursorIsRejected() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(
                id: 1,
                tool: "usage.requests",
                arguments: .object(["cursor": .string("1767225600.7")])
            ))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    func testUsageRequestsRowsCarryTheHarnessNotJustTheTool() async throws {
        let result = try await call("usage.requests")
        let row = try XCTUnwrap(result["rows"]?.arrayValue?.first)
        XCTAssertEqual(row["tool"]?.stringValue, "claude")
        XCTAssertEqual(row["harness"]?.stringValue, "claudeCode")
        XCTAssertEqual(row["harnessName"]?.stringValue, "Claude Code")
        XCTAssertEqual(row["model"]?.stringValue, "claude-opus-4-7")
        XCTAssertEqual(row["costUSD"]?.doubleValue, 0.25)
    }

    func testPageSizeAboveTheCapIsRejected() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(
                id: 1,
                tool: "usage.requests",
                arguments: .object(["pageSize": .int(500)])
            ))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    // MARK: - cost

    func testCostSnapshotReportsEveryWindowAndThePrivacyFlag() async throws {
        let result = try await call("cost.snapshot")
        XCTAssertEqual(result["privacyModeEnabled"]?.boolValue, false)
        let claude = try XCTUnwrap(result["tools"]?.arrayValue?.first { $0["tool"]?.stringValue == "claude" })
        XCTAssertEqual(claude["company"]?.stringValue, "Anthropic")
        XCTAssertEqual(claude["today"]?["costUSD"]?.doubleValue, 1.25)
        XCTAssertEqual(claude["last7d"]?["tokens"]?.intValue, 700)
        XCTAssertEqual(claude["last30d"]?["requests"]?.intValue, 120)
        XCTAssertEqual(claude["allTime"]?["costUSD"]?.doubleValue, 120.5)
    }

    func testCostHistoryNeedsATool() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(id: 1, tool: "cost.history"))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    func testCostHistoryDefaultsToThirtyDays() async throws {
        let result = try await call("cost.history", .object(["tool": .string("claude")]))
        XCTAssertEqual(result["tool"]?.stringValue, "claude")
        XCTAssertEqual(result["timeframe"]?.stringValue, "30d")
        XCTAssertEqual(result["days"]?.arrayValue?.count, 1)
    }

    // MARK: - sessions

    func testSessionsSearchCarriesTheSnippetAndTheHarness() async throws {
        let result = try await call("sessions.search", .object(["query": .string("socket")]))
        XCTAssertEqual(source.lastSessionQuery, "socket")
        XCTAssertEqual(source.lastSessionLimit, 20)
        let hit = try XCTUnwrap(result["sessions"]?.arrayValue?.first)
        XCTAssertEqual(hit["harness"]?.stringValue, "claudeCode")
        XCTAssertEqual(hit["harnessName"]?.stringValue, "Claude Code")
        XCTAssertEqual(hit["provider"]?.stringValue, "claude")
        XCTAssertEqual(hit["snippet"]?.stringValue, "the <b>socket</b> server")
        XCTAssertEqual(hit["matchedSeq"]?.intValue, 4)
        XCTAssertEqual(hit["messageCount"]?.intValue, 12)
        XCTAssertNil(result["totalCount"], "Search does not count past its own limit.")
    }

    func testSessionsSearchRejectsABlankQuery() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(
                id: 1,
                tool: "sessions.search",
                arguments: .object(["query": .string("   ")])
            ))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    func testSessionsListReportsPaging() async throws {
        let result = try await call("sessions.list", .object(["limit": .int(10), "offset": .int(0)]))
        XCTAssertEqual(result["limit"]?.intValue, 10)
        XCTAssertEqual(result["offset"]?.intValue, 0)
        XCTAssertEqual(result["totalCount"]?.intValue, 1)
        XCTAssertEqual(result["sessions"]?.arrayValue?.count, 1)
    }

    // MARK: - status and pricing

    func testStatusGetRollsUpToCompanies() async throws {
        let result = try await call("status.get")
        let companies = try XCTUnwrap(result["companies"]?.arrayValue)
            .compactMap { $0["company"]?.stringValue }
        XCTAssertEqual(companies, ["OpenAI", "Anthropic", "Google AI", "SpaceXAI"])
    }

    /// AntiGravity has no feed of its own; asking for it must resolve to the
    /// Google AI row rather than to nothing.
    func testStatusGetResolvesAMemberToItsCompanyRow() async throws {
        let result = try await call("status.get", .object(["tools": .array([.string("antigravity")])]))
        let companies = try XCTUnwrap(result["companies"]?.arrayValue)
        XCTAssertEqual(companies.count, 1)
        XCTAssertEqual(companies.first?["company"]?.stringValue, "Google AI")
    }

    func testPricingFiltersByFamilyAndModelSubstring() async throws {
        let all = try await call("pricing.effective")
        XCTAssertEqual(all["rows"]?.arrayValue?.count, 2)
        XCTAssertEqual(all["unit"]?.stringValue, "USD per 1M tokens")

        let claudeOnly = try await call("pricing.effective", .object(["provider": .string("claude")]))
        XCTAssertEqual(claudeOnly["rows"]?.arrayValue?.count, 1)

        let byModel = try await call("pricing.effective", .object(["model": .string("CODEX")]))
        let row = try XCTUnwrap(byModel["rows"]?.arrayValue?.first)
        XCTAssertEqual(row["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(row["company"]?.stringValue, "OpenAI")
        XCTAssertEqual(row["inputPerMillion"]?.doubleValue, 1.25)
    }

    // MARK: - Result shape

    /// `content` and `structuredContent` come from one encode, so a client
    /// that parses and a model that reads see the same object.
    func testTextContentAndStructuredContentAgree() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(id: 1, tool: "quota.get"))
        )
        let text = try XCTUnwrap(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let reparsed = try JSONDecoder().decode(MCPJSON.self, from: Data(text.utf8))
        XCTAssertEqual(reparsed, try MCPTestSupport.structured(response))
    }
}
