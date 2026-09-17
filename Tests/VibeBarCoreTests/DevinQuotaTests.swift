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
}
