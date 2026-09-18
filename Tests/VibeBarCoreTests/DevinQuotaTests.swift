import XCTest
@testable import VibeBarCore

/// Devin's quota is the `GetUserStatus` answer its CLI caches under
/// `~/.cache/devin/cli/user_status.<identity>.bin`.
final class DevinQuotaTests: XCTestCase {
    // MARK: - Protobuf fixtures

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(value)
    }

    private func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    /// A `UserStatus` with only the fields the parser reads, plus an identity
    /// string the parser must ignore.
    private func userStatus(
        planName: String? = "Pro",
        dailyRemaining: UInt64? = nil,
        weeklyRemaining: UInt64? = nil,
        dailyReset: UInt64? = nil,
        weeklyReset: UInt64? = nil
    ) -> Data {
        var planStatus: [UInt8] = []
        if let planName {
            planStatus += field(1, bytes: field(1, varint: 16) + field(2, bytes: Array(planName.utf8)))
        }
        if let dailyRemaining { planStatus += field(14, varint: dailyRemaining) }
        if let weeklyRemaining { planStatus += field(15, varint: weeklyRemaining) }
        if let dailyReset { planStatus += field(17, varint: dailyReset) }
        if let weeklyReset { planStatus += field(18, varint: weeklyReset) }
        let identity = field(3, bytes: Array("user@example.com".utf8))
        return Data(field(1, varint: 1) + identity + field(13, bytes: planStatus))
    }

    // MARK: - Parser

    func testRemainingPercentsBecomeUsedBucketsWithTheirResets() throws {
        let snapshot = try DevinPlanStatusParser.parse(payload: userStatus(
            dailyRemaining: 72, weeklyRemaining: 40,
            dailyReset: 1_789_718_400, weeklyReset: 1_789_891_200
        ))
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 28)
        XCTAssertEqual(snapshot.buckets[1].usedPercent, 60)
        XCTAssertEqual(snapshot.buckets[0].resetAt, Date(timeIntervalSince1970: 1_789_718_400))
        XCTAssertEqual(snapshot.buckets[1].rawWindowSeconds, 604_800)
    }

    /// proto3 drops zero: a spent window keeps its reset and loses its
    /// percent, and must read as fully used rather than vanish.
    func testASpentWindowArrivesWithoutItsPercent() throws {
        let snapshot = try DevinPlanStatusParser.parse(payload: userStatus(
            weeklyRemaining: 55, dailyReset: 1_789_718_400, weeklyReset: 1_789_891_200
        ))
        XCTAssertEqual(snapshot.buckets.first { $0.id == "daily" }?.usedPercent, 100)
    }

    func testAPlanWithoutADailyWindowShowsOnlyWeekly() throws {
        let snapshot = try DevinPlanStatusParser.parse(payload: userStatus(
            planName: "Max", weeklyRemaining: 90, weeklyReset: 1_789_891_200
        ))
        XCTAssertEqual(snapshot.buckets.map(\.id), ["weekly"])
        XCTAssertEqual(snapshot.planName, "Max")
    }

    func testNoWindowsOrGarbageIsAParseFailure() {
        XCTAssertThrowsError(try DevinPlanStatusParser.parse(payload: userStatus()))
        XCTAssertThrowsError(try DevinPlanStatusParser.parse(payload: Data([0xFF, 0xFF, 0xFF])))
    }

    // MARK: - Cache files

    func testTheNewestCacheWinsAndSetsTheQuotaTime() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarDevinTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = DevinUserStatusCache.directory(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func write(_ name: String, fetchedAt: Int, weeklyRemaining: UInt64) throws {
            let envelope: [String: Any] = [
                "version": 1,
                "identity_digest": "0000",
                "fetched_at_secs": fetchedAt,
                "payload": userStatus(weeklyRemaining: weeklyRemaining, weeklyReset: 1_789_891_200)
                    .base64EncodedString()
            ]
            try JSONSerialization.data(withJSONObject: envelope)
                .write(to: directory.appendingPathComponent(name))
        }
        try write("user_status.aaaa.bin", fetchedAt: 1_789_600_000, weeklyRemaining: 10)
        try write("user_status.bbbb.bin", fetchedAt: 1_789_700_000, weeklyRemaining: 80)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("user_status.cccc.bin"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("team_settings.aaaa.bin"))

        XCTAssertTrue(DevinUserStatusCache.exists(homeDirectory: home.path))
        let account = AccountIdentity(id: "local-devin", tool: .devin, source: .cliDetected)
        let quota = try await DevinQuotaAdapter(homeDirectory: home.path).fetch(for: account)
        XCTAssertEqual(quota.queriedAt, Date(timeIntervalSince1970: 1_789_700_000))
        XCTAssertEqual(quota.buckets.map(\.usedPercent), [20])
        XCTAssertEqual(quota.plan, "Pro")
    }

    func testNoCacheIsNoCredential() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarDevinTests-\(UUID().uuidString)", isDirectory: true)
        let account = AccountIdentity(id: "local-devin", tool: .devin, source: .cliDetected)
        do {
            _ = try await DevinQuotaAdapter(homeDirectory: home.path).fetch(for: account)
            XCTFail("expected noCredential")
        } catch {
            XCTAssertEqual(error as? QuotaError, .noCredential)
        }
    }

    // MARK: - Live route

    /// What app.devin.ai's Usage & Limits page reads. Percentages are a
    /// fraction of one.
    func testLiveUsageBecomesDailyAndWeeklyBuckets() throws {
        let json = Data(#"""
        {"daily_percentage":0.16,"daily_reset_at":"2026-09-18T16:00:00Z",
         "weekly_percentage":0.1,"weekly_reset_at":1790000000,"hide_daily_quota":false}
        """#.utf8)
        let buckets = try DevinQuotaUsageParser.parse(data: json)
        XCTAssertEqual(buckets.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(buckets[0].usedPercent, 16, accuracy: 1e-9)
        XCTAssertEqual(buckets[1].usedPercent, 10, accuracy: 1e-9)
        XCTAssertEqual(buckets[0].rawWindowSeconds, 86_400)
        XCTAssertEqual(buckets[1].resetAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNotNil(buckets[0].resetAt)
    }

    func testAPlanWithoutADailyQuotaKeepsOnlyWeekly() throws {
        let json = Data(#"{"daily_percentage":0.5,"weekly_percentage":42,"hide_daily_quota":true}"#.utf8)
        let buckets = try DevinQuotaUsageParser.parse(data: json)
        XCTAssertEqual(buckets.map(\.id), ["weekly"])
        XCTAssertEqual(buckets[0].usedPercent, 42, "a value above one is already a percent")
    }

    func testAnAnswerWithoutWindowsIsAParseFailure() {
        for body in [#"{}"#, #"{"detail":"No organizations found for auth1 user"}"#, "<html>"] {
            XCTAssertThrowsError(try DevinQuotaUsageParser.parse(data: Data(body.utf8)), body)
        }
    }

    func testTheLiveRequestIsThePagesOwnAndNamesOnlyDevin() throws {
        let header = "devin-auth1-token=synthetic-auth1-token-0123456789; devin-org-id=org-0123456789abcdef"
        let request = try XCTUnwrap(DevinLiveQuota.makeRequest(cookieHeader: header))
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://app.devin.ai/api/org-0123456789abcdef/billing/quota/usage"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-auth1-token-0123456789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cog-org-id"), "org-0123456789abcdef")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    /// The organization id is spliced into a URL path, so anything that is
    /// not shaped like one is refused, as is half a session.
    func testAMalformedSessionMakesNoRequest() {
        XCTAssertNil(DevinLiveQuota.makeRequest(cookieHeader: "devin-auth1-token=synthetic-auth1-token-0123456789"))
        XCTAssertNil(DevinLiveQuota.makeRequest(
            cookieHeader: "devin-auth1-token=synthetic-auth1-token-0123456789; devin-org-id=../admin"
        ))
        XCTAssertNil(DevinLiveQuota.makeRequest(cookieHeader: "devin-auth1-token=short; devin-org-id=org-0123456789"))
        XCTAssertTrue(DevinLiveQuota.isOrganizationID("org_abc123"))
        XCTAssertFalse(DevinLiveQuota.isOrganizationID("organization"))
    }
}
