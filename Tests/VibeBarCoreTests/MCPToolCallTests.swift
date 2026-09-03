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
        XCTAssertEqual(result["hasMore"]?.boolValue, false)
    }

    // MARK: - session filters

    /// One vocabulary across the surface: `sessions.*` narrows with the same
    /// `from` / `to` / `models` / `harnesses` that `usage.*` uses.
    func testSessionFiltersReachTheDataSourceOnBothTools() async throws {
        let arguments = MCPJSON.object([
            "query": .string("socket"),
            "harnesses": .array([.string("codex")]),
            "providers": .array([.string("codex")]),
            "projectDir": .string("vibe-bar"),
            "from": .string("2026-01-01T00:00:00Z"),
            "to": .string("2026-02-01T00:00:00Z"),
            "models": .array([.string("gpt-5-codex")])
        ])
        _ = try await call("sessions.search", arguments)
        var filter = try XCTUnwrap(source.lastSessionFilter)
        XCTAssertEqual(filter.harnesses, [.codex])
        XCTAssertEqual(filter.providers, [.codex])
        XCTAssertEqual(filter.projectDir, "vibe-bar")
        XCTAssertEqual(filter.from, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(filter.to, Date(timeIntervalSince1970: 1_769_904_000))
        XCTAssertEqual(filter.models, ["gpt-5-codex"])

        var listArguments = arguments
        if case var .object(fields) = listArguments {
            fields.removeValue(forKey: "query")
            listArguments = .object(fields)
        }
        _ = try await call("sessions.list", listArguments)
        filter = try XCTUnwrap(source.lastSessionFilter)
        XCTAssertEqual(filter.projectDir, "vibe-bar")
        XCTAssertEqual(filter.models, ["gpt-5-codex"])
    }

    /// `since` was `sessions.list`'s original spelling. It keeps working, and
    /// `from` wins when a caller sends both.
    func testSinceStillWorksAsAnAliasForFrom() async throws {
        _ = try await call("sessions.list", .object(["since": .string("2026-01-01T00:00:00Z")]))
        XCTAssertEqual(
            try XCTUnwrap(source.lastSessionFilter).from,
            Date(timeIntervalSince1970: 1_767_225_600)
        )
        _ = try await call("sessions.list", .object([
            "since": .string("2020-01-01T00:00:00Z"),
            "from": .string("2026-01-01T00:00:00Z")
        ]))
        XCTAssertEqual(
            try XCTUnwrap(source.lastSessionFilter).from,
            Date(timeIntervalSince1970: 1_767_225_600)
        )
    }

    func testAnInvertedSessionWindowIsRejected() async throws {
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(
                id: 1,
                tool: "sessions.list",
                arguments: .object([
                    "from": .string("2026-02-01T00:00:00Z"),
                    "to": .string("2026-01-01T00:00:00Z")
                ])
            ))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    /// An empty list reaches the data source as an empty list, not as `nil`.
    /// That is what lets `SessionQueryFilter` read it as "nothing" — the same
    /// rule `quota.get`'s `tools: []` follows.
    func testAnEmptySessionFilterListStaysEmptyRatherThanBecomingUnfiltered() async throws {
        _ = try await call("sessions.list", .object([
            "models": .array([]),
            "harnesses": .array([])
        ]))
        let filter = try XCTUnwrap(source.lastSessionFilter)
        XCTAssertEqual(filter.models, [])
        XCTAssertEqual(filter.harnesses, [])
        XCTAssertTrue(filter.matchesNothing)

        _ = try await call("sessions.list", .object([:]))
        let unfiltered = try XCTUnwrap(source.lastSessionFilter)
        XCTAssertNil(unfiltered.models)
        XCTAssertNil(unfiltered.harnesses)
        XCTAssertFalse(unfiltered.matchesNothing)
    }

    func testAnEmptyRolesListReachesTheTranscriptWindowAsAnEmptySet() async throws {
        _ = try await call("sessions.transcript", .object([
            "sessionId": .string("sess-42"),
            "provider": .string("claude"),
            "roles": .array([])
        ]))
        XCTAssertEqual(source.lastTranscriptWindow?.roles, [])
    }

    /// Filters run after the index's ranking cut, so a short page can mean
    /// "nothing matches" or "the matches are below the cut". An agent cannot
    /// tell those apart from an empty array, so the payload says which.
    func testSearchSurfacesTheRankingCutRatherThanReturningASilentEmptyPage() async throws {
        source.searchHits = []
        source.searchNotice = "Filters ran after the ranking cut: the top 200 hits for this "
            + "query yielded 0 match(es), and more may exist below the cut."
        let result = try await call("sessions.search", .object([
            "query": .string("socket"),
            "to": .string("2020-01-01T00:00:00Z")
        ]))
        XCTAssertEqual(result["sessions"]?.arrayValue?.count, 0)
        let notice = try XCTUnwrap(result["notice"]?.stringValue)
        XCTAssertTrue(notice.contains("below the cut"), notice)
    }

    func testACompleteSearchCarriesNoNotice() async throws {
        let result = try await call("sessions.search", .object(["query": .string("socket")]))
        XCTAssertEqual(result["sessions"]?.arrayValue?.count, 1)
        XCTAssertNil(result["notice"], "a full page must not be labelled incomplete")
    }

    func testAHostSideFilterWithholdsTheCountAndSaysWhy() async throws {
        source.listTotalCount = nil
        source.listHasMore = true
        source.listNotice = "Stopped after examining 4000 indexed sessions."
        let result = try await call("sessions.list", .object(["models": .array([.string("gpt-5")])]))
        XCTAssertNil(result["totalCount"], "the store's count describes a wider set than the rows")
        XCTAssertEqual(result["hasMore"]?.boolValue, true)
        XCTAssertNotNil(result["notice"]?.stringValue)
    }

    // MARK: - sessions.transcript

    func testTranscriptReadsAWindowAroundAMatch() async throws {
        let result = try await call("sessions.transcript", .object([
            "id": .string("claude:sess-42:/Users/example/.claude/projects/x/sess-42.jsonl"),
            "around": .int(4),
            "radius": .int(1)
        ]))
        XCTAssertEqual(source.lastTranscriptLocator?.provider, .claude)
        XCTAssertEqual(source.lastTranscriptLocator?.sessionID, "sess-42")
        XCTAssertEqual(source.lastTranscriptWindow?.around, 4)
        XCTAssertEqual(source.lastTranscriptWindow?.radius, 1)

        let messages = try XCTUnwrap(result["messages"]?.arrayValue)
        XCTAssertEqual(messages.compactMap { $0["seq"]?.intValue }, [3, 4, 5])
        XCTAssertEqual(messages.first?["role"]?.stringValue, "assistant")
        XCTAssertEqual(messages.first?["text"]?.stringValue, "message 3")
        XCTAssertEqual(messages.first?["textBytes"]?.intValue, 9)
        XCTAssertNil(messages.first?["textTruncated"], "absent unless the text was actually cut")
        XCTAssertEqual(result["firstSeq"]?.intValue, 3)
        XCTAssertEqual(result["lastSeq"]?.intValue, 5)
        XCTAssertEqual(result["totalMessageCount"]?.intValue, 8)
        XCTAssertEqual(result["truncated"]?.boolValue, false)
        // The session it belongs to travels with it, so a caller that started
        // from a bare sessionId does not need a second round trip to label it.
        XCTAssertEqual(result["session"]?["harness"]?.stringValue, "claudeCode")
    }

    func testTranscriptPagesWithACursor() async throws {
        let first = try await call("sessions.transcript", .object([
            "sessionId": .string("sess-42"),
            "provider": .string("claude"),
            "from": .int(0),
            "limit": .int(3)
        ]))
        XCTAssertEqual(first["hasMore"]?.boolValue, true)
        let next = try XCTUnwrap(first["nextFrom"]?.intValue)
        XCTAssertEqual(next, 3)

        let second = try await call("sessions.transcript", .object([
            "sessionId": .string("sess-42"),
            "provider": .string("claude"),
            "from": .int(Int64(next)),
            "limit": .int(10)
        ]))
        XCTAssertEqual(
            second["messages"]?.arrayValue?.compactMap { $0["seq"]?.intValue },
            [3, 4, 5, 6, 7]
        )
        XCTAssertEqual(second["hasMore"]?.boolValue, false)
        XCTAssertNil(second["nextFrom"], "the last page must not hand back a cursor")
    }

    func testTranscriptRolesThinTheWindow() async throws {
        let result = try await call("sessions.transcript", .object([
            "sessionId": .string("sess-42"),
            "provider": .string("claude"),
            "from": .int(0),
            "limit": .int(6),
            "roles": .array([.string("user")])
        ]))
        XCTAssertEqual(
            result["messages"]?.arrayValue?.compactMap { $0["seq"]?.intValue },
            [0, 2, 4]
        )
    }

    func testTranscriptSaysWhenTheReadStoppedShort() async throws {
        source.transcriptReachedEndOfFile = false
        let result = try await call("sessions.transcript", .object([
            "sessionId": .string("sess-42"),
            "provider": .string("claude"),
            "around": .int(500)
        ]))
        XCTAssertEqual(result["truncated"]?.boolValue, true)
        XCTAssertEqual(result["truncationReasons"]?.arrayValue?.compactMap { $0.stringValue },
                       ["readCeiling"])
        XCTAssertNil(result["totalMessageCount"])
        XCTAssertNil(result["nextFrom"], "retrying the identical call would loop")
        XCTAssertTrue(try XCTUnwrap(result["notice"]?.stringValue).contains("bounded read"))
    }

    func testTranscriptNeedsASessionAndRejectsNonsenseIds() async throws {
        for arguments in [
            MCPJSON.object([:]),
            .object(["sessionId": .string("sess-42")]),
            .object(["id": .string("not-a-provider:sess-42:/x")])
        ] {
            let response = try MCPTestSupport.decode(
                await server.handle(line: MCPTestSupport.call(
                    id: 1, tool: "sessions.transcript", arguments: arguments
                ))
            )
            XCTAssertEqual(
                response["error"]?["code"]?.intValue, -32_602,
                "\(arguments) should be an argument error"
            )
        }
    }

    /// An unknown session is a tool failure the model can act on, not a
    /// protocol error — and the message has to explain the index's freshness
    /// rather than implying the session does not exist.
    func testAnUnindexedSessionExplainsTheIndexRatherThanFailingBlankly() async throws {
        source.transcriptFailure = "No indexed Claude Code session with id 'nope'. "
            + "The index is as fresh as Vibe Bar's last sweep."
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(
                id: 1,
                tool: "sessions.transcript",
                arguments: .object(["sessionId": .string("nope"), "provider": .string("claude")])
            ))
        )
        XCTAssertNil(response["error"], "a missing session is a tool result, not a JSON-RPC error")
        XCTAssertTrue(MCPTestSupport.isError(response))
        XCTAssertTrue(
            try XCTUnwrap(MCPTestSupport.errorText(response)).contains("last sweep")
        )
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
