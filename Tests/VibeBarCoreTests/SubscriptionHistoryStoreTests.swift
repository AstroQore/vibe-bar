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
        XCTAssertEqual(Set(all.map(\.bucketId)), ["five_hour", "weekly", "weekly_sonnet"])
    }

    func testGeminiProductTracksAllThreeFiveHourAndWeeklySeries() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(12_000)
        let weeklyReset = now.addingTimeInterval(400_000)

        await store.observe(quota(
            accountId: "web-gemini",
            tool: .gemini,
            buckets: [
                bucket(id: "five_hour", usedPercent: 1, resetAt: fiveHourReset, rawWindowSeconds: 18_000),
                bucket(id: "weekly", usedPercent: 2, resetAt: weeklyReset, rawWindowSeconds: 604_800)
            ]
        ), now: now, retentionDays: 30)
        await store.observe(quota(
            accountId: "local-antigravity",
            tool: .antigravity,
            buckets: [
                bucket(id: "gemini_five_hour", usedPercent: 3, resetAt: fiveHourReset, rawWindowSeconds: 18_000, groupTitle: "Gemini Models"),
                bucket(id: "gemini_weekly", usedPercent: 4, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "Gemini Models"),
                bucket(id: "claude_gpt_five_hour", usedPercent: 5, resetAt: fiveHourReset, rawWindowSeconds: 18_000, groupTitle: "Claude and GPT Models"),
                bucket(id: "claude_gpt_weekly", usedPercent: 6, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "Claude and GPT Models")
            ]
        ), now: now, retentionDays: 30)

        let all = await store.allSamples()
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.filter { $0.rawWindowSeconds == 18_000 }.count, 3)
        XCTAssertEqual(all.filter { $0.rawWindowSeconds == 604_800 }.count, 3)
    }

    func testTwoObservationsSameWindowMaxMerge() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let resetAt = now.addingTimeInterval(3 * 86_400)

        let first = quota(tool: .codex, buckets: [
            bucket(id: "weekly", usedPercent: 30, resetAt: resetAt, rawWindowSeconds: 604_800)
        ])
        let second = quota(tool: .codex, buckets: [
            bucket(id: "weekly", usedPercent: 44, resetAt: resetAt.addingTimeInterval(90), rawWindowSeconds: 604_800)
        ])
        await store.observe(first, now: now, retentionDays: 30)
        await store.observe(second, now: now.addingTimeInterval(60), retentionDays: 30)
        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.peakUsedPercent, 44, accuracy: 0.001)
        XCTAssertEqual(sample.lastUsedPercent, 44, accuracy: 0.001)
        XCTAssertEqual(sample.observationCount, 2)
        XCTAssertFalse(sample.isCompleted)
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
        let old = try XCTUnwrap(samples.first { $0.isCompleted })
        XCTAssertEqual(old.peakUsedPercent, 95, accuracy: 0.001)
        XCTAssertEqual(old.observationCount, 1)
        XCTAssertEqual(old.completionReason, .refillDetected)
        XCTAssertEqual(old.remainingPercentAtReset, 5, accuracy: 0.001)
        XCTAssertEqual(samples.filter { !$0.isCompleted }.count, 1)
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
                bucket(id: "weekly", usedPercent: 0, resetAt: oldReset.addingTimeInterval(7 * 86_400), rawWindowSeconds: 604_800)
            ]),
            now: oldReset,
            retentionDays: 0
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
        XCTAssertFalse(samples.contains { $0.peakUsedPercent == 50 })
        XCTAssertEqual(samples.filter { !$0.isCompleted }.count, 1)
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

    func testFiveHourBucketsAreTrackedByRefill() async throws {
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
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 5, resetAt: reset.addingTimeInterval(5 * 3_600), rawWindowSeconds: 18_000)
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )
        let all = await store.allSamples()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter(\.isCompleted).count, 1)
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

    func testResetAtDriftDoesNotCreateFakeCycles() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(4 * 86_400)
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 20, resetAt: reset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 30
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 21, resetAt: reset.addingTimeInterval(180), rawWindowSeconds: 604_800)
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].observationCount, 2)
        XCTAssertFalse(samples[0].isCompleted)
    }

    func testLegacyTimelineImportsOnlyDetectedRefills() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let points = [
            FillTimelinePoint(accountId: "acct-test", tool: .claude, bucketId: "weekly", slotStart: now, usedPercent: 20, sampledAt: now),
            FillTimelinePoint(accountId: "acct-test", tool: .claude, bucketId: "weekly", slotStart: now.addingTimeInterval(3_600), usedPercent: 75, sampledAt: now.addingTimeInterval(3_600)),
            FillTimelinePoint(accountId: "acct-test", tool: .claude, bucketId: "weekly", slotStart: now.addingTimeInterval(7_200), usedPercent: 4, sampledAt: now.addingTimeInterval(7_200))
        ]
        await store.importLegacyTimeline(points, retentionDays: 30)
        await store.importLegacyTimeline(points, retentionDays: 30)

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].peakUsedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(samples[0].completionReason, .legacyTimelineMigration)
    }
}
