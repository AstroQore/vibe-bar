import XCTest
@testable import VibeBarCore

final class UsageForecastTimelineStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("forecast-timeline-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    private func observation(
        bucketId: String,
        projected: Double,
        lower: Double? = nil,
        upper: Double? = nil,
        windowSeconds: Int? = 604_800,
        resetAt: Date? = Date(timeIntervalSince1970: 1_780_100_000)
    ) -> BucketForecastObservation {
        BucketForecastObservation(
            bucketId: bucketId,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds,
            projectedUsedPercent: projected,
            projectedUsedLowerPercent: lower ?? max(0, projected - 8),
            projectedUsedUpperPercent: upper ?? projected + 8
        )
    }

    func testRecordsEveryBucketWithAdaptiveSlots() async {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let now = Date(timeIntervalSince1970: 1_780_000_123)
        await store.observe(
            [
                observation(bucketId: "five_hour", projected: 71, windowSeconds: 18_000),
                observation(bucketId: "weekly", projected: 44),
                observation(bucketId: "weekly_fable", projected: 12)
            ],
            accountId: "acct-1",
            tool: .claude,
            now: now
        )

        let five = await store.points(accountId: "acct-1", bucketId: "five_hour")
        XCTAssertEqual(five.count, 1)
        XCTAssertEqual(five.first?.projectedUsedPercent, 71)
        XCTAssertEqual(
            five.first?.slotStart,
            UsageTimelineSlotPolicy.slotStart(for: now, windowSeconds: 18_000)
        )

        let weekly = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(
            weekly.first?.slotStart,
            UsageTimelineSlotPolicy.slotStart(for: now, windowSeconds: 604_800)
        )
        XCTAssertEqual(weekly.first?.rawWindowSeconds, 604_800)
        XCTAssertNotNil(weekly.first?.resetAt)

        let all = await store.allPoints()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.tool)), [.claude])
    }

    func testLastSampleInSlotWinsAndNewSlotAppends() async {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        await store.observe(
            [observation(bucketId: "weekly", projected: 40)],
            accountId: "acct-1",
            tool: .codex,
            now: base
        )
        await store.observe(
            [observation(bucketId: "weekly", projected: 52)],
            accountId: "acct-1",
            tool: .codex,
            now: base.addingTimeInterval(600)
        )
        await store.observe(
            [observation(bucketId: "weekly", projected: 63)],
            accountId: "acct-1",
            tool: .codex,
            now: base.addingTimeInterval(4_000)
        )

        let points = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].projectedUsedPercent, 52)
        XCTAssertEqual(points[0].sampledAt, base.addingTimeInterval(600))
        XCTAssertEqual(points[1].projectedUsedPercent, 63)
        XCTAssertLessThan(points[0].slotStart, points[1].slotStart)
    }

    func testMiscProvidersAreDropped() async {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        await store.observe(
            [observation(bucketId: "weekly", projected: 90)],
            accountId: "acct-1",
            tool: .zai
        )
        let points = await store.allPoints()
        XCTAssertTrue(points.isEmpty)
    }

    func testNonFiniteProjectionsAreDropped() async {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        await store.observe(
            [observation(bucketId: "weekly", projected: .nan)],
            accountId: "acct-1",
            tool: .claude
        )
        let points = await store.allPoints()
        XCTAssertTrue(points.isEmpty)
    }

    func testPruneRespectsHorizon() async {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let old = Date(timeIntervalSince1970: 1_780_000_000)
        await store.observe(
            [observation(bucketId: "weekly", projected: 20)],
            accountId: "acct-1",
            tool: .claude,
            now: old
        )
        // Weekly forecasts retain sixteen weeks; 120 days is past that.
        await store.observe(
            [observation(bucketId: "weekly", projected: 33)],
            accountId: "acct-1",
            tool: .claude,
            now: old.addingTimeInterval(120 * 86_400)
        )
        let points = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.projectedUsedPercent, 33)
    }

    func testFiniteRetentionSettingShortensHorizon() async {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let old = Date(timeIntervalSince1970: 1_780_000_000)
        await store.observe(
            [observation(bucketId: "weekly", projected: 20)],
            accountId: "acct-1",
            tool: .claude,
            now: old,
            retentionDays: 30
        )
        await store.observe(
            [observation(bucketId: "weekly", projected: 33)],
            accountId: "acct-1",
            tool: .claude,
            now: old.addingTimeInterval(45 * 86_400),
            retentionDays: 30
        )
        let points = await store.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.projectedUsedPercent, 33)
    }

    func testPersistenceRoundTrip() async {
        let writeStore = UsageForecastTimelineStore(fileURL: tempURL)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let reset = now.addingTimeInterval(86_400)
        await writeStore.observe(
            [
                observation(
                    bucketId: "weekly",
                    projected: 58,
                    lower: 47,
                    upper: 72,
                    resetAt: reset
                )
            ],
            accountId: "acct-1",
            tool: .gemini,
            now: now
        )
        await writeStore.flushPendingWrites()

        let readStore = UsageForecastTimelineStore(fileURL: tempURL)
        let points = await readStore.points(accountId: "acct-1", bucketId: "weekly")
        XCTAssertEqual(points.count, 1)
        let point = points.first
        XCTAssertEqual(point?.tool, .gemini)
        XCTAssertEqual(point?.projectedUsedPercent, 58)
        XCTAssertEqual(point?.projectedUsedLowerPercent, 47)
        XCTAssertEqual(point?.projectedUsedUpperPercent, 72)
        XCTAssertEqual(point?.resetAt, reset)
        XCTAssertEqual(point?.sampledAt, now)
    }

    func testFileIsWrittenOwnerOnly() async throws {
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        await store.observe(
            [observation(bucketId: "weekly", projected: 10)],
            accountId: "acct-1",
            tool: .claude
        )
        await store.flushPendingWrites()

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testCorruptFileLoadsEmptyAndStillAcceptsNewPoints() async throws {
        try Data("not json".utf8).write(to: tempURL, options: .atomic)
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let initial = await store.allPoints()
        XCTAssertTrue(initial.isEmpty)

        await store.observe(
            [observation(bucketId: "weekly", projected: 30)],
            accountId: "acct-1",
            tool: .claude
        )
        let points = await store.allPoints()
        XCTAssertEqual(points.count, 1)
    }

    func testOversizedFileIsIgnored() async throws {
        // A file past the defensive cap is corrupt, not history: it must not
        // be decoded, and the store has to keep working afterwards.
        try Data(count: 25 * 1024 * 1024).write(to: tempURL, options: .atomic)
        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let initial = await store.allPoints()
        XCTAssertTrue(initial.isEmpty)

        await store.observe(
            [observation(bucketId: "weekly", projected: 12)],
            accountId: "acct-1",
            tool: .claude
        )
        await store.flushPendingWrites()

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? .max
        XCTAssertLessThan(size, 4_096)
    }

    func testFutureSchemaVersionResetsStorage() async throws {
        struct FutureStorage: Encodable {
            let schemaVersion = 99
            let points: [ForecastTimelinePoint]
        }
        let sampledAt = Date(timeIntervalSince1970: 1_780_000_000)
        let point = ForecastTimelinePoint(
            accountId: "acct-future",
            tool: .codex,
            bucketId: "weekly",
            slotStart: sampledAt,
            sampledAt: sampledAt,
            projectedUsedPercent: 61,
            projectedUsedLowerPercent: 50,
            projectedUsedUpperPercent: 74
        )
        try JSONEncoder().encode(FutureStorage(points: [point])).write(to: tempURL, options: .atomic)

        let store = UsageForecastTimelineStore(fileURL: tempURL)
        let points = await store.allPoints()
        XCTAssertTrue(points.isEmpty)
    }

    func testObservationMirrorsComputedForecast() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3 * 86_400)
        let bucket = QuotaBucket(
            id: "weekly",
            title: "Weekly",
            shortLabel: "Weekly",
            usedPercent: 42,
            resetAt: reset,
            rawWindowSeconds: 7 * 86_400
        )
        let forecast = try XCTUnwrap(QuotaPaceForecast.compute(
            bucket: bucket,
            observations: [],
            cycles: [],
            now: now
        ))
        let observation = BucketForecastObservation(bucket: bucket, forecast: forecast)
        XCTAssertEqual(observation.bucketId, "weekly")
        XCTAssertEqual(observation.resetAt, reset)
        XCTAssertEqual(observation.rawWindowSeconds, 7 * 86_400)
        XCTAssertEqual(observation.projectedUsedPercent, forecast.projectedUsedPercent)
        XCTAssertEqual(observation.projectedUsedLowerPercent, forecast.projectedUsedLowerPercent)
        XCTAssertEqual(observation.projectedUsedUpperPercent, forecast.projectedUsedUpperPercent)
    }
}
