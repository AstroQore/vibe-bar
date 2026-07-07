import XCTest
@testable import VibeBarCore

final class SubscriptionHistoryStoreTests: XCTestCase {
    // MARK: - Fixture helpers

    private func makeTempStore() throws -> (store: SubscriptionHistoryStore, fileURL: URL, cleanup: () -> Void) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarSubscriptionHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("subscription_history.json")
        let store = SubscriptionHistoryStore(fileURL: url)
        return (store, url, { try? fileManager.removeItem(at: directory) })
    }

    private func bucket(
        id: String,
        usedPercent: Double,
        resetAt: Date?,
        rawWindowSeconds: Int?,
        groupTitle: String? = nil
    ) -> QuotaBucket {
        QuotaBucket(
            id: id,
            title: id,
            shortLabel: id,
            usedPercent: usedPercent,
            resetAt: resetAt,
            rawWindowSeconds: rawWindowSeconds,
            groupTitle: groupTitle
        )
    }

    private func quota(
        accountId: String = "acct-test",
        tool: ToolType,
        buckets: [QuotaBucket],
        queriedAt: Date = Date()
    ) -> AccountQuota {
        AccountQuota(
            accountId: accountId,
            tool: tool,
            buckets: buckets,
            queriedAt: queriedAt
        )
    }

    // MARK: - Tests

    func testObserveCreatesOneSamplePerEligibleBucket() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let weeklyReset = now.addingTimeInterval(3 * 86_400)
        let fiveHourReset = now.addingTimeInterval(2 * 3_600)

        let q = quota(tool: .claude, buckets: [
            bucket(id: "five_hour", usedPercent: 80, resetAt: fiveHourReset, rawWindowSeconds: 18_000),
            bucket(id: "weekly", usedPercent: 40, resetAt: weeklyReset, rawWindowSeconds: 604_800),
            bucket(id: "weekly_sonnet", usedPercent: 25, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "Sonnet")
        ])
        await store.observe(q, now: now, retentionDays: 30)
        let all = await store.allSamples()
        XCTAssertEqual(Set(all.map(\.bucketId)), ["weekly", "weekly_sonnet"])
        XCTAssertFalse(all.contains { $0.bucketId == "five_hour" })
    }

    func testTwoObservationsSameWindowMaxMerge() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let resetAt = now.addingTimeInterval(3 * 86_400)

        let first = quota(tool: .codex, buckets: [
            bucket(id: "weekly", usedPercent: 88, resetAt: resetAt, rawWindowSeconds: 604_800)
        ])
        let second = quota(tool: .codex, buckets: [
            bucket(id: "weekly", usedPercent: 30, resetAt: resetAt, rawWindowSeconds: 604_800)
        ])
        await store.observe(first, now: now, retentionDays: 30)
        await store.observe(second, now: now.addingTimeInterval(60), retentionDays: 30)
        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.peakUsedPercent, 88, accuracy: 0.001)
        XCTAssertEqual(sample.lastUsedPercent, 30, accuracy: 0.001)
        XCTAssertEqual(sample.observationCount, 2)
    }

    func testNewResetAtCreatesNewSample() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let firstReset = now.addingTimeInterval(1 * 86_400)
        let secondReset = firstReset.addingTimeInterval(7 * 86_400)

        let first = quota(tool: .claude, buckets: [
            bucket(id: "weekly", usedPercent: 95, resetAt: firstReset, rawWindowSeconds: 604_800)
        ])
        let second = quota(tool: .claude, buckets: [
            bucket(id: "weekly", usedPercent: 10, resetAt: secondReset, rawWindowSeconds: 604_800)
        ])
        await store.observe(first, now: now, retentionDays: 30)
        await store.observe(second, now: firstReset.addingTimeInterval(60), retentionDays: 30)
        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.map(\.windowEnd), [secondReset, firstReset])
        // Old window's peak must not be touched by the new window.
        let old = try XCTUnwrap(samples.first { $0.windowEnd == firstReset })
        XCTAssertEqual(old.peakUsedPercent, 95, accuracy: 0.001)
        XCTAssertEqual(old.observationCount, 1)
    }

    func testRetentionPruneDropsOldSamples() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let oldReset = now.addingTimeInterval(-60 * 86_400)
        let recentReset = now.addingTimeInterval(3 * 86_400)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 50, resetAt: oldReset, rawWindowSeconds: 604_800)
            ]),
            now: oldReset.addingTimeInterval(-60),
            retentionDays: 0  // unlimited — write succeeds
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 70, resetAt: recentReset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 0
        )
        await store.prune(retentionDays: 30, now: now)
        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.windowEnd, recentReset)
    }

    func testRoundTripPersistence() async throws {
        let (store, fileURL, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86_400)
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 60, resetAt: reset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 30
        )
        await store.flushPendingWrites()

        let reopened = SubscriptionHistoryStore(fileURL: fileURL)
        let samples = await reopened.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.peakUsedPercent, 60, accuracy: 0.001)
    }

    func testProviderGatingDropsMiscTools() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86_400)
        await store.observe(
            quota(tool: .kimi, buckets: [
                bucket(id: "weekly", usedPercent: 60, resetAt: reset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 30
        )
        let all = await store.allSamples()
        XCTAssertTrue(all.isEmpty, "Misc tool quotas should not be recorded")
    }

    func testWindowGatingDropsFiveHourBuckets() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(2 * 3_600)
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 90, resetAt: reset, rawWindowSeconds: 18_000)
            ]),
            now: now,
            retentionDays: 30
        )
        let all = await store.allSamples()
        XCTAssertTrue(all.isEmpty, "5h buckets should be ignored")
    }

    func testGrokWeeklyBucketIsTracked() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(4 * 86_400)
        await store.observe(
            quota(tool: .grok, buckets: [
                bucket(id: "weekly", usedPercent: 55, resetAt: reset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 30
        )
        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.peakUsedPercent, 55, accuracy: 0.001)
        XCTAssertEqual(sample.lastUsedPercent, 55, accuracy: 0.001)
        XCTAssertNotNil(sample.windowStart)
    }
}
