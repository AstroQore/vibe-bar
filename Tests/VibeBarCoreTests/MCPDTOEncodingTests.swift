import XCTest
@testable import VibeBarCore

/// Pins the wire shape.
///
/// Agents and their prompts get written against these key names, so a rename
/// is a breaking change even though nothing in Swift would notice. The
/// convention is **camelCase everywhere**, dates are ISO-8601 with a `Z`, and
/// money appears twice — exact micros plus a rounded USD figure.
final class MCPDTOEncodingTests: XCTestCase {
    private func keys(_ value: some Encodable) throws -> Set<String> {
        let json = try MCPJSON.encoding(value)
        return Set(try XCTUnwrap(json.objectValue).keys)
    }

    private func encoded(_ value: some Encodable) throws -> MCPJSON {
        try MCPJSON.encoding(value)
    }

    func testDatesEncodeAsISO8601WithZ() throws {
        let json = try encoded(MCPRangeDTO(
            from: FakeMCPDataSource.epoch,
            to: FakeMCPDataSource.epoch.addingTimeInterval(3_661)
        ))
        XCTAssertEqual(json["from"]?.stringValue, "2026-01-01T00:00:00Z")
        XCTAssertEqual(json["to"]?.stringValue, "2026-01-01T01:01:01Z")
    }

    func testEveryKeyIsCamelCase() throws {
        let samples: [Set<String>] = [
            try keys(MCPQuotaAccountDTO(
                quota: FakeMCPDataSource.claudeQuota,
                lastUpdated: nil,
                lastAttempted: nil,
                inFlight: false,
                error: nil
            )),
            try keys(MCPQuotaBucketDTO(
                bucket: FakeMCPDataSource.claudeQuota.buckets[0],
                forecast: nil
            )),
            try keys(MCPUsageRequestRowDTO(row: UsageRequestRow(
                id: 1,
                date: FakeMCPDataSource.epoch,
                tool: .claude,
                harness: .claudeCode,
                model: "m",
                freshInput: 1,
                output: 2,
                cacheRead: 3,
                cacheCreation: 4,
                costMicros: 5,
                serviceTier: nil,
                sessionId: nil,
                sourceKey: nil
            ))),
            try keys(MCPCostToolSnapshotDTO(snapshot: FakeMCPDataSource.costSnapshot(for: .claude))),
            try keys(MCPSessionSummaryDTO(summary: FakeMCPDataSource.sessionSummary))
        ]
        for keys in samples {
            for key in keys {
                XCTAssertFalse(key.contains("_"), "'\(key)' is snake_case; the wire shape is camelCase.")
                XCTAssertEqual(
                    key.first.map { String($0) },
                    key.first.map { String($0).lowercased() },
                    "'\(key)' should start lower-case."
                )
            }
        }
    }

    func testQuotaAccountKeysArePinned() throws {
        XCTAssertEqual(
            try keys(MCPQuotaAccountDTO(
                quota: FakeMCPDataSource.claudeQuota,
                lastUpdated: FakeMCPDataSource.epoch,
                lastAttempted: FakeMCPDataSource.epoch,
                inFlight: true,
                error: nil
            )),
            [
                "accountId", "tool", "company", "subProvider", "plan", "email",
                "buckets", "queriedAt", "lastUpdated", "lastAttempted", "inFlight"
            ]
        )
    }

    func testQuotaBucketKeysArePinned() throws {
        XCTAssertEqual(
            try keys(MCPQuotaBucketDTO(bucket: FakeMCPDataSource.claudeQuota.buckets[0], forecast: nil)),
            ["id", "title", "shortLabel", "groupTitle", "usedPercent", "remainingPercent", "resetAt", "windowSeconds"]
        )
    }

    /// `nil` fields are omitted rather than encoded as `null`, so an agent can
    /// test for presence instead of for two kinds of absence.
    func testAbsentOptionalsAreOmitted() throws {
        let json = try encoded(MCPQuotaAccountDTO(
            quota: FakeMCPDataSource.codexQuota,
            lastUpdated: nil,
            lastAttempted: nil,
            inFlight: false,
            error: nil
        ))
        let fields = try XCTUnwrap(json.objectValue)
        XCTAssertNil(fields["email"], "codex has no email in the fixture.")
        XCTAssertNil(fields["lastUpdated"])
        XCTAssertNil(fields["error"])
        XCTAssertNotNil(fields["plan"])
    }

    func testMoneyIsReportedInBothUnits() throws {
        let json = try encoded(MCPUsageGroupRowDTO(
            key: "claudeCode",
            label: "Claude Code",
            company: "Anthropic",
            requests: 1,
            totalTokens: 2,
            costMicros: 1_234_567
        ))
        XCTAssertEqual(json["costMicros"]?.intValue, 1_234_567)
        XCTAssertEqual(json["costUSD"]?.doubleValue, 1.23)
    }

    func testMicrosRoundHalfUpAndSurviveNegatives() {
        XCTAssertEqual(MCPMoney.usd(0), 0)
        XCTAssertEqual(MCPMoney.usd(5_000), 0.01)
        XCTAssertEqual(MCPMoney.usd(4_999), 0.0)
        XCTAssertEqual(MCPMoney.usd(-1_500_000), -1.5)
    }

    /// A session summary that never learned its message count reports the
    /// field as absent, not as the internal `-1` sentinel.
    func testUnknownMessageCountIsOmittedRatherThanNegative() throws {
        let summary = SessionSummary(
            provider: .cursor,
            sessionID: "x",
            sourcePath: "/Users/example/.cursor/chats/x/store.db"
        )
        let json = try encoded(MCPSessionSummaryDTO(summary: summary))
        XCTAssertNil(json.objectValue?["messageCount"])
        XCTAssertEqual(json["harness"]?.stringValue, "cursor")
    }

    func testCursorEncodingIsOpaqueAndRoundTrips() {
        let cursor = UsageRequestCursor(ts: 1_767_225_600, id: 42)
        let encoded = MCPCursorCoding.encode(cursor)
        XCTAssertFalse(encoded.contains("1767225600"), "The cursor should not read as editable numbers.")
        XCTAssertEqual(MCPCursorCoding.decode(encoded), cursor)
        XCTAssertNil(MCPCursorCoding.decode("not-a-cursor"))
        XCTAssertNil(MCPCursorCoding.decode(Data("12".utf8).base64EncodedString()))
    }

    func testJSONValueKeepsIntegersIntegral() throws {
        let json = try JSONDecoder().decode(MCPJSON.self, from: Data(#"{"n":1,"d":1.5}"#.utf8))
        XCTAssertEqual(json["n"], .int(1))
        XCTAssertEqual(json["d"], .double(1.5))
        let text = String(decoding: try json.serialized(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"n\":1"), text)
    }
}
