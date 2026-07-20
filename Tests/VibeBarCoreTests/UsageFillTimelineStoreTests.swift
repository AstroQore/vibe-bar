import XCTest
@testable import VibeBarCore

final class UsageFillTimelineStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fill-timeline-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    private func quota(
        tool: ToolType = .claude,
        accountId: String = "acct-1",
        buckets: [QuotaBucket]
    ) -> AccountQuota {
        AccountQuota(
            accountId: accountId,
            tool: tool,
            buckets: buckets,
            plan: nil,
            email: nil,
            queriedAt: Date()
        )
    }

    private func bucket(
        id: String,
        used: Double,
        groupTitle: String? = nil,
        windowSeconds: Int? = 604_800
    ) -> QuotaBucket {
        QuotaBucket(
            id: id,
            title: "Weekly",
            shortLabel: id,
            usedPercent: used,
            resetAt: Date().addingTimeInterval(3_600),
            rawWindowSeconds: windowSeconds,
            groupTitle: groupTitle
        )
    }

    func testRecordsEveryBucketWithAdaptiveSlots() async {
        let store = UsageFillTimelineStore(fileURL: tempURL)
        let now = Date(timeIntervalSince1970: 1_780_000_123)
        await store.observe(quota(buckets: [
            bucket(id: "five_hour", used: 41, windowSeconds: 18_000),
            bucket(id: "weekly", used: 12),
            bucket(id: "weekly_fable", used: 3, groupTitle: "Fable")
        ]), now: now)

        let five = await store.points(accountId: "acct-1", bucketId: "five_hour")
        XCTAssertEqual(five.count, 1)
        XCTAssertEqual(five.first?.usedPercent, 41)
        XCTAssertEqual(
            five.first?.slotStart,
            UsageFillTimelineStore.slotStart(for: now, windowSeconds: 18_000)
        )

        let weekly = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(weekly.count, 1)

        let fable = await store.points(accountId: "acct-1", bucketId: "weekly_fable")
        XCTAssertEqual(fable.count, 1)
        XCTAssertNotNil(fable.first?.resetAt)
        XCTAssertEqual(fable.first?.rawWindowSeconds, 604_800)
    }

    func testLastSampleInHourWinsAndNewHourAppends() async {
        let store = UsageFillTimelineStore(fileURL: tempURL)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        await store.observe(quota(buckets: [bucket(id: "weekly", used: 10)]), now: base)
        await store.observe(quota(buckets: [bucket(id: "weekly", used: 15)]), now: base.addingTimeInterval(600))
        await store.observe(quota(buckets: [bucket(id: "weekly", used: 22)]), now: base.addingTimeInterval(4_000))

        let points = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].usedPercent, 15)
        XCTAssertEqual(points[1].usedPercent, 22)
        XCTAssertLessThan(points[0].slotStart, points[1].slotStart)
    }

    func testMiscProvidersAreDropped() async {
        let store = UsageFillTimelineStore(fileURL: tempURL)
        await store.observe(quota(tool: .zai, buckets: [bucket(id: "weekly", used: 50)]))
        let points = await store.allPoints()
        XCTAssertTrue(points.isEmpty)
    }

    func testPruneRespectsHorizon() async {
        let store = UsageFillTimelineStore(fileURL: tempURL)
        let old = Date(timeIntervalSince1970: 1_780_000_000)
        await store.observe(quota(buckets: [bucket(id: "weekly", used: 5)]), now: old)
        // Weekly observations retain sixteen weeks.
        let later = old.addingTimeInterval(120 * 86_400)
        await store.observe(quota(buckets: [bucket(id: "weekly", used: 9)]), now: later)
        let points = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.usedPercent, 9)
    }

    func testAntigravityStoresEveryFiveHourAndWeeklyLane() async {
        let store = UsageFillTimelineStore(fileURL: tempURL)
        await store.observe(quota(
            tool: .antigravity,
            accountId: "ag-account",
            buckets: [
                bucket(id: "gemini_five_hour", used: 8, groupTitle: "Gemini Models", windowSeconds: 18_000),
                bucket(id: "gemini_weekly", used: 12, groupTitle: "Gemini Models"),
                bucket(id: "claude_gpt_five_hour", used: 5, groupTitle: "Claude and GPT Models", windowSeconds: 18_000),
                bucket(id: "claude_gpt_weekly", used: 22, groupTitle: "Claude and GPT Models")
            ]
        ))
        let points = await store.allPoints()
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(Set(points.map(\.bucketId)), [
            "gemini_five_hour", "gemini_weekly",
            "claude_gpt_five_hour", "claude_gpt_weekly"
        ])
    }

    func testPersistenceRoundTrip() async {
        let writeStore = UsageFillTimelineStore(fileURL: tempURL)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        await writeStore.observe(quota(buckets: [bucket(id: "weekly", used: 33)]), now: now)
        await writeStore.flushPendingWrites()

        let readStore = UsageFillTimelineStore(fileURL: tempURL)
        let points = await readStore.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.usedPercent, 33)
        XCTAssertEqual(points.first?.tool, .claude)
    }

    func testSchemaOnePointsMigrateWithoutResetMetadata() async throws {
        let sampledAt = Date(timeIntervalSince1970: 1_780_000_000)
        let point = FillTimelinePoint(
            accountId: "acct-legacy",
            tool: .codex,
            bucketId: "weekly",
            slotStart: sampledAt,
            usedPercent: 42,
            sampledAt: sampledAt
        )
        struct LegacyStorage: Encodable {
            let schemaVersion = 1
            let points: [FillTimelinePoint]
        }
        try JSONEncoder().encode(LegacyStorage(points: [point])).write(to: tempURL, options: .atomic)

        let store = UsageFillTimelineStore(fileURL: tempURL)
        let migrated = await store.points(accountId: "acct-legacy", bucketId: "weekly")
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.usedPercent, 42)
        XCTAssertNil(migrated.first?.resetAt)
        XCTAssertNil(migrated.first?.rawWindowSeconds)
    }
}
