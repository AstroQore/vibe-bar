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

    func testRecordsHeadlineBucketsIncludingFiveHour() async {
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
        XCTAssertEqual(five.first?.slotStart, UsageFillTimelineStore.hourSlotStart(for: now))

        let weekly = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(weekly.count, 1)

        // Per-model branch buckets are not part of the timeline chart.
        let fable = await store.points(accountId: "acct-1", bucketId: "weekly_fable")
        XCTAssertTrue(fable.isEmpty)
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
        // 10 days later: the old point is past the 8-day horizon and pruned
        // by the next observe.
        let later = old.addingTimeInterval(10 * 86_400)
        await store.observe(quota(buckets: [bucket(id: "weekly", used: 9)]), now: later)
        let points = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.usedPercent, 9)
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
}
