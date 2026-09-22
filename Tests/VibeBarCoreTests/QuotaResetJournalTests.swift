import XCTest
@testable import VibeBarCore

final class QuotaResetJournalTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func quota(_ used: Double, reset: TimeInterval, receipts: [ResetCreditEvent]? = nil) -> AccountQuota {
        AccountQuota(accountId: "synthetic-account", tool: .codex,
                     buckets: [QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5 Hours", usedPercent: used,
                                           resetAt: base.addingTimeInterval(reset), rawWindowSeconds: 18_000)],
                     plan: "pro", resetCredits: ResetCredits(availableCount: 0, redemptions: receipts))
    }

    func testAllResetShapesKeepTheirBeforeAndAfterEvidence() async throws {
        for (time, nextReset, expected) in [
            (3600.0, 21_600.0, SubscriptionWindowSample.ResetKind.earlyClockRestarted),
            (3600.0, 18_000.0, .earlyClockUnchanged),
            (18_010.0, 36_000.0, .onSchedule)
        ] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("history.json")
            let store = SubscriptionHistoryStore(fileURL: url)
            await store.observe(quota(80, reset: 18_000), now: base.addingTimeInterval(time - 60))
            await store.observe(quota(0, reset: nextReset), now: base.addingTimeInterval(time))
            await store.flushPendingWrites()
            let reloaded = SubscriptionHistoryStore(fileURL: url)
            let records = await reloaded.allSamples().filter(\.isCompleted)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.resetKind, expected)
            let detail = try XCTUnwrap(records.first?.resetDetails)
            XCTAssertEqual(detail.previousResetAt, base.addingTimeInterval(18_000))
            XCTAssertEqual(detail.nextResetAt, base.addingTimeInterval(nextReset))
            XCTAssertEqual(detail.previousUsedPercent, 80)
            XCTAssertEqual(detail.nextUsedPercent, 0)
            XCTAssertNil(detail.creditRedeemedAt)
        }
    }

    func testRedemptionReceiptIsPersistedEvenWithNoAvailableCredits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("history.json")
        let store = SubscriptionHistoryStore(fileURL: url)
        let receipt = ResetCreditEvent(id: "synthetic-hash", occurredAt: base.addingTimeInterval(3595))
        await store.observe(quota(80, reset: 18_000), now: base.addingTimeInterval(3590))
        await store.observe(quota(0, reset: 21_600, receipts: [receipt]), now: base.addingTimeInterval(3600))
        await store.observe(quota(1, reset: 21_600, receipts: [receipt]), now: base.addingTimeInterval(3660))
        await store.flushPendingWrites()
        let reloaded = SubscriptionHistoryStore(fileURL: url)
        let receipts = await reloaded.allRedemptions()
        XCTAssertEqual(receipts.count, 1)
        let samples = await reloaded.allSamples().filter(\.isCompleted)
        XCTAssertEqual(samples.first?.resetDetails?.creditRedeemedAt, receipt.occurredAt)
    }

    func testFeatureRefillsAreRetainedWithoutAConfidentPercentage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let store = SubscriptionHistoryStore(fileURL: url)
        func feature(_ remaining: Int) -> AccountQuota {
            AccountQuota(accountId: "synthetic-chat", tool: .chatgptChat,
                buckets: [QuotaBucket(id: "image_gen", title: "Image Generation", shortLabel: "Image Generation", usedPercent: 0,
                    resetAt: base.addingTimeInterval(86_400), quantity: .init(remaining: remaining))], plan: "pro")
        }
        await store.observe(feature(20), now: base)
        await store.observe(feature(1000), now: base.addingTimeInterval(60))
        await store.flushPendingWrites()
        let reloaded = SubscriptionHistoryStore(fileURL: url)
        let records = await reloaded.allFeatureResets()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.resetDetails?.previousRemaining, 20)
        XCTAssertEqual(records.first?.resetDetails?.nextRemaining, 1000)
        XCTAssertEqual(records.first?.resetKind, .earlyClockUnchanged)
        let forecastCycles = await reloaded.allSamples()
        XCTAssertTrue(forecastCycles.isEmpty)
    }

    func testLateRedemptionReceiptUpdatesTheAlreadyRecordedTransition() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let store = SubscriptionHistoryStore(fileURL: url)
        await store.observe(quota(80, reset: 18_000), now: base.addingTimeInterval(3590))
        await store.observe(quota(0, reset: 21_600), now: base.addingTimeInterval(3600))
        let before = await store.allSamples().first(where: \.isCompleted)
        XCTAssertNil(before?.resetDetails?.creditRedeemedAt)
        let receipt = ResetCreditEvent(id: "synthetic-late", occurredAt: base.addingTimeInterval(3595))
        await store.observe(quota(1, reset: 21_600, receipts: [receipt]), now: base.addingTimeInterval(3660))
        await store.flushPendingWrites()
        let reloaded = SubscriptionHistoryStore(fileURL: url)
        let recorded = await reloaded.allSamples().filter(\.isCompleted)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.resetDetails?.creditRedeemedAt, receipt.occurredAt)
    }

    func testWideObservationGapDoesNotGuessWhichResetUsedTheCredit() {
        func cycle(gap: TimeInterval, kind: SubscriptionWindowSample.ResetKind) -> SubscriptionWindowSample {
            SubscriptionWindowSample(accountId: "synthetic-account", tool: .codex, bucketId: "weekly",
                windowEnd: base.addingTimeInterval(gap), peakUsedPercent: 90, lastUsedPercent: 90,
                firstSeenAt: base.addingTimeInterval(-86_400), lastSeenAt: base,
                completedAt: base.addingTimeInterval(gap), completionReason: .refillDetected, resetKind: kind)
        }
        let receipt = ResetCreditEvent(id: "synthetic", occurredAt: base.addingTimeInterval(300))
        let second = ResetCreditEvent(id: "synthetic-2", occurredAt: base.addingTimeInterval(900))
        // Close interval: any refill.
        XCTAssertEqual(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 600, kind: .onSchedule), events: [receipt]), receipt)
        // Receipt outside the interval.
        XCTAssertNil(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 200, kind: .earlyClockRestarted), events: [receipt]))
        // An hour-wide interval (the retired hourly timeline): only an early
        // refill, only with a single receipt inside it.
        XCTAssertEqual(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 3_600, kind: .earlyClockRestarted), events: [receipt]), receipt)
        XCTAssertNil(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 3_600, kind: .onSchedule), events: [receipt]))
        XCTAssertNil(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 3_600, kind: .earlyClockRestarted), events: [receipt, second]))
        // Past the wide window nothing is tied.
        XCTAssertNil(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 4 * 3_600, kind: .earlyClockRestarted), events: [receipt]))
        // A credit that names the windows it clears ties only those.
        let scoped = ResetCreditEvent(id: "scoped", occurredAt: base.addingTimeInterval(300), clears: ["five_hour"])
        XCTAssertNil(SubscriptionHistoryStore.creditMatch(for: cycle(gap: 600, kind: .earlyClockRestarted), events: [scoped]))
    }

    func testRedeemingAndExpiredCreditsDoNotCountAsConfirmedRedemptions() throws {
        let data = Data(#"{"available_count":0,"credits":[{"id":"private-grant","status":"redeemed","redeemed_at":"2026-06-01T00:00:00Z"},{"id":"in-progress","status":"redeeming","redeem_started_at":"2026-06-01T00:00:00Z"},{"id":"expired","status":"expired","expires_at":"2026-06-01T00:00:00Z"}]}"#.utf8)
        let credits = try XCTUnwrap(CodexResetCreditsFetcher.parse(data: data, now: base))
        XCTAssertEqual(credits.availableCount, 0)
        XCTAssertEqual(credits.redemptions?.count, 1)
        let encoded = String(decoding: try JSONEncoder().encode(credits), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-grant"))
    }
}
