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

    /// A window that ran its full length.
    func testAWindowThatRunsItsLengthIsRecordedAsOnSchedule() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(18_000)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 40, resetAt: reset, rawWindowSeconds: 18_000)
            ], queriedAt: start),
            now: start
        )
        // The reset arrives; the next window is a full one from here.
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 2,
                       resetAt: reset.addingTimeInterval(18_000), rawWindowSeconds: 18_000)
            ], queriedAt: reset),
            now: reset
        )

        let completed = await store.samples(accountId: "acct-test", bucketId: "five_hour")
            .filter(\.isCompleted)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.resetKind, .onSchedule)
        XCTAssertEqual(completed.first?.refilledEarly, false)
    }

    /// Refilled early, and the next reset moved out to a full window from the
    /// refill — a whole window lies ahead, so the extra capacity is usable.
    func testAnEarlyRefillThatRestartsTheClockIsRecorded() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(18_000)
        let early = start.addingTimeInterval(5_000)

        await store.observe(
            quota(tool: .codex, buckets: [
                bucket(id: "weekly", usedPercent: 40, resetAt: reset, rawWindowSeconds: 18_000)
            ], queriedAt: start),
            now: start
        )
        await store.observe(
            quota(tool: .codex, buckets: [
                bucket(id: "weekly", usedPercent: 2,
                       resetAt: early.addingTimeInterval(18_000), rawWindowSeconds: 18_000)
            ], queriedAt: early),
            now: early
        )

        let completed = await store.samples(accountId: "acct-test", bucketId: "weekly")
            .filter(\.isCompleted)
        XCTAssertEqual(completed.first?.resetKind, .earlyClockRestarted)
        XCTAssertEqual(completed.first?.refilledEarly, true)
    }

    /// The opposite consequence: refilled early and the boundary did not move,
    /// so less than a window remains to spend the refill in.
    func testAnEarlyRefillThatLeavesTheClockAloneIsRecorded() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(18_000)
        let early = start.addingTimeInterval(5_000)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 40, resetAt: reset, rawWindowSeconds: 18_000)
            ], queriedAt: start),
            now: start
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 2, resetAt: reset, rawWindowSeconds: 18_000)
            ], queriedAt: early),
            now: early
        )

        let completed = await store.samples(accountId: "acct-test", bucketId: "five_hour")
            .filter(\.isCompleted)
        XCTAssertEqual(completed.first?.resetKind, .earlyClockUnchanged)
    }

    /// Near the start of a window the two early bands overlap: a boundary
    /// that has not moved is almost exactly a window away from here. Testing
    /// the bands in order always answered "restarted", which is the opposite
    /// of the truth and the more reassuring of the two.
    func testAnEarlyRefillJustAfterAWindowOpensIsNotMisreadAsRestarted() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let week = 604_800
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(TimeInterval(week))
        // One hour in, and the boundary does not move.
        let early = start.addingTimeInterval(3_600)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 40, resetAt: reset, rawWindowSeconds: week)
            ], queriedAt: start),
            now: start
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 2, resetAt: reset, rawWindowSeconds: week)
            ], queriedAt: early),
            now: early
        )

        let completed = await store.samples(accountId: "acct-test", bucketId: "weekly")
            .filter(\.isCompleted)
        XCTAssertEqual(
            completed.first?.resetKind, .earlyClockUnchanged,
            "an unmoved boundary an hour into a week was read as a restarted clock"
        )
    }

    /// The migration passes can place a completed cycle on a timeline point
    /// that reported no reset time. Dropping such points before matching
    /// removed the refill observation itself, and the nearest survivor — a
    /// poll ten minutes later — produced a confident answer for a cycle whose
    /// evidence does not support one.
    func testACycleOnAPointWithNoResetTimeIsNotGivenAnInventedAnswer() async throws {
        let (store, url, cleanup) = try makeTempStore()
        defer { cleanup() }
        let window = 18_000
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = base.addingTimeInterval(TimeInterval(window))
        // The refill was seen on a point that carried no reset time.
        let refill = reset.addingTimeInterval(-0.4)
        let json = """
        {"schemaVersion":2,"legacyTimelineImported":true,"resetSignalRepairVersion":1,\
        "samples":[{"accountId":"acct-test","tool":"codex","bucketId":"weekly",\
        "windowEnd":\(refill.timeIntervalSinceReferenceDate),"rawWindowSeconds":\(window),\
        "peakUsedPercent":40,"lastUsedPercent":40,"observationCount":4,\
        "firstSeenAt":\(base.timeIntervalSinceReferenceDate),\
        "lastSeenAt":\(refill.timeIntervalSinceReferenceDate),\
        "completedAt":\(refill.timeIntervalSinceReferenceDate),\
        "completionReason":"refillDetected"}]}
        """
        try Data(json.utf8).write(to: url)

        func point(_ used: Double, at date: Date, resetAt: Date?) -> FillTimelinePoint {
            FillTimelinePoint(
                accountId: "acct-test", tool: .codex, bucketId: "weekly",
                slotStart: UsageFillTimelineStore.hourSlotStart(for: date),
                usedPercent: used, sampledAt: date, resetAt: resetAt,
                rawWindowSeconds: window
            )
        }
        await store.importLegacyTimeline([
            point(30, at: base, resetAt: reset),
            point(2, at: refill, resetAt: nil),
            point(6, at: reset.addingTimeInterval(600),
                  resetAt: reset.addingTimeInterval(TimeInterval(window))),
        ])

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(
            samples.first?.resetKind, .unobserved,
            "a cycle whose refill reported no reset time was given a confident answer"
        )
    }

    /// A cycle whose evidence is gone is marked as asked-and-unanswerable,
    /// not left blank. Blank means nobody has looked, so the backfill would
    /// come back to it on every launch for observations that no longer exist.
    func testACycleWithNoSurvivingObservationsIsMarkedUnobserved() async throws {
        let (store, url, cleanup) = try makeTempStore()
        defer { cleanup() }
        let window = 18_000
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {"schemaVersion":2,"legacyTimelineImported":true,"resetSignalRepairVersion":1,\
        "samples":[{"accountId":"acct-test","tool":"codex","bucketId":"weekly",\
        "windowEnd":\(base.timeIntervalSinceReferenceDate),"rawWindowSeconds":\(window),\
        "peakUsedPercent":40,"lastUsedPercent":40,"observationCount":3,\
        "firstSeenAt":\(base.timeIntervalSinceReferenceDate),\
        "lastSeenAt":\(base.timeIntervalSinceReferenceDate),\
        "completedAt":\(base.timeIntervalSinceReferenceDate),\
        "completionReason":"scheduledReset"}]}
        """
        try Data(json.utf8).write(to: url)

        // The timeline has been pruned; nothing survives to judge this by.
        await store.importLegacyTimeline([])

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.first?.resetKind, .unobserved)
        XCTAssertEqual(samples.first?.refilledEarly, false, "unanswerable is not early")
    }

    /// The gap between refills, which is what shows a bucket keeping a
    /// schedule other than the one it advertises.
    func testTheGapBetweenRefillsIsRecorded() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window: TimeInterval = 18_000

        var moment = start
        for step in 0...3 {
            let used: Double = step % 2 == 0 ? 40 : 2
            await store.observe(
                quota(tool: .claude, buckets: [
                    bucket(id: "five_hour", usedPercent: used,
                           resetAt: moment.addingTimeInterval(window),
                           rawWindowSeconds: Int(window))
                ], queriedAt: moment),
                now: moment
            )
            moment = moment.addingTimeInterval(window)
        }

        let completed = await store.samples(accountId: "acct-test", bucketId: "five_hour")
            .filter(\.isCompleted)
            .sorted { $0.windowEnd < $1.windowEnd }
        XCTAssertGreaterThanOrEqual(completed.count, 2)
        // Nothing to measure the first against.
        XCTAssertNil(completed.first?.intervalSeconds)
        let gap = try XCTUnwrap(completed.dropFirst().first?.intervalSeconds)
        XCTAssertEqual(gap, window, accuracy: 1)
    }

    /// A file written before this existed still decodes, and its cycles simply
    /// have no classification rather than a wrong one.
    func testSamplesWrittenBeforeClassificationStillDecode() async throws {
        let (store, url, cleanup) = try makeTempStore()
        defer { cleanup() }
        let json = """
        {"schemaVersion":2,"legacyTimelineImported":false,"samples":[{\
        "accountId":"acct-test","tool":"claude","bucketId":"five_hour",\
        "windowEnd":800000000,"rawWindowSeconds":18000,"peakUsedPercent":40,\
        "lastUsedPercent":40,"observationCount":3,"firstSeenAt":799982000,\
        "lastSeenAt":799999400,"completedAt":800000000,\
        "completionReason":"scheduledReset"}]}
        """
        try Data(json.utf8).write(to: url)

        let samples = await store.samples(accountId: "acct-test", bucketId: "five_hour")
        XCTAssertEqual(samples.count, 1, "an older file must still load")
        XCTAssertNil(samples.first?.resetKind)
        XCTAssertEqual(samples.first?.refilledEarly, false, "unclassified is not early")
    }

    /// Cycles that finished before the app classified refills get their answer
    /// from the observations recorded at the time, rather than waiting three
    /// months for a weekly bucket to fill twelve fresh bars.
    ///
    /// Shaped around the case that shows a mismatched lookup: a window that
    /// ran its *full* length. The timeline point that saw the refill is
    /// written a moment before this store is told, by a different `Date()`, so
    /// it lands just before `completedAt`. Reaching forward from there picks
    /// the following poll and reads the refill's own reset as the one the old
    /// cycle had been reporting — which makes an on-schedule cycle look like
    /// an early refill, and puts a mark on a bar that deserves none.
    func testStoredCyclesAreClassifiedFromTheTimeline() async throws {
        let (store, url, cleanup) = try makeTempStore()
        defer { cleanup() }
        let window = 18_000
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = base.addingTimeInterval(TimeInterval(window))

        // One completed cycle, written the way an older build would have: it
        // ran its full length and ended at its stated reset.
        let json = """
        {"schemaVersion":2,"legacyTimelineImported":true,"resetSignalRepairVersion":1,\
        "samples":[{"accountId":"acct-test","tool":"codex","bucketId":"weekly",\
        "windowEnd":\(reset.timeIntervalSinceReferenceDate),"rawWindowSeconds":\(window),\
        "peakUsedPercent":40,"lastUsedPercent":40,"observationCount":3,\
        "firstSeenAt":\(base.timeIntervalSinceReferenceDate),\
        "lastSeenAt":\(reset.timeIntervalSinceReferenceDate),\
        "completedAt":\(reset.timeIntervalSinceReferenceDate),\
        "completionReason":"scheduledReset"}]}
        """
        try Data(json.utf8).write(to: url)

        func point(_ used: Double, at date: Date, resetAt: Date) -> FillTimelinePoint {
            FillTimelinePoint(
                accountId: "acct-test",
                tool: .codex,
                bucketId: "weekly",
                slotStart: UsageFillTimelineStore.hourSlotStart(for: date),
                usedPercent: used,
                sampledAt: date,
                resetAt: resetAt,
                rawWindowSeconds: window
            )
        }
        let seen = reset.addingTimeInterval(-0.4)
        let nextReset = seen.addingTimeInterval(TimeInterval(window))
        await store.importLegacyTimeline([
            point(40, at: base, resetAt: reset),
            point(2, at: seen, resetAt: nextReset),
            // The poll after the refill, which a forward lookup would match.
            point(6, at: reset.addingTimeInterval(600), resetAt: nextReset),
        ])

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(
            samples.first?.resetKind, .onSchedule,
            "a window that ran its full length was read as an early refill"
        )
        XCTAssertEqual(samples.first?.refilledEarly, false)
    }

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

    func testOnePercentToZeroCompletesLowUsageCycle() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86_400)

        await store.observe(
            quota(tool: .codex, buckets: [
                bucket(
                    id: "gpt_5_3_codex_spark_weekly",
                    usedPercent: 1,
                    resetAt: reset,
                    rawWindowSeconds: 604_800,
                    groupTitle: "GPT-5.3 Codex Spark"
                )
            ]),
            now: now,
            retentionDays: 30
        )
        await store.observe(
            quota(tool: .codex, buckets: [
                bucket(
                    id: "gpt_5_3_codex_spark_weekly",
                    usedPercent: 0,
                    resetAt: reset,
                    rawWindowSeconds: 604_800,
                    groupTitle: "GPT-5.3 Codex Spark"
                )
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )

        let samples = await store.samples(
            accountId: "acct-test",
            bucketId: "gpt_5_3_codex_spark_weekly"
        )
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.filter(\.isCompleted).count, 1)
        XCTAssertEqual(samples.first(where: \.isCompleted)?.peakUsedPercent, 1)
        XCTAssertEqual(samples.first(where: \.isCompleted)?.completionReason, .refillDetected)
    }

    func testFiveHourTwoHourResetAdvanceCompletesEvenWhenUsageIncreases() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3_600)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 20, resetAt: reset, rawWindowSeconds: 18_000)
            ]),
            now: now,
            retentionDays: 30
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(
                    id: "five_hour",
                    usedPercent: 35,
                    resetAt: reset.addingTimeInterval(2 * 3_600),
                    rawWindowSeconds: 18_000
                )
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )

        let samples = await store.samples(accountId: "acct-test", bucketId: "five_hour")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.filter(\.isCompleted).count, 1)
        XCTAssertEqual(samples.first(where: \.isCompleted)?.completionReason, .scheduledReset)
        XCTAssertEqual(samples.first(where: { !$0.isCompleted })?.lastUsedPercent, 35)
    }

    func testWeeklyThreeDayResetAdvanceCompletesEvenWhenUsageIncreases() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86_400)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 20, resetAt: reset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 30
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(
                    id: "weekly",
                    usedPercent: 35,
                    resetAt: reset.addingTimeInterval(3 * 86_400),
                    rawWindowSeconds: 604_800
                )
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.filter(\.isCompleted).count, 1)
        XCTAssertEqual(samples.first(where: \.isCompleted)?.completionReason, .scheduledReset)
    }

    func testResetAdvanceBelowTenPercentDoesNotCompleteByItself() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3_600)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "five_hour", usedPercent: 20, resetAt: reset, rawWindowSeconds: 18_000)
            ]),
            now: now,
            retentionDays: 30
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(
                    id: "five_hour",
                    usedPercent: 21,
                    resetAt: reset.addingTimeInterval(20 * 60),
                    rawWindowSeconds: 18_000
                )
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )

        let samples = await store.samples(accountId: "acct-test", bucketId: "five_hour")
        XCTAssertEqual(samples.count, 1)
        XCTAssertFalse(samples[0].isCompleted)
    }

    func testWeakUsageDropAndWeakResetAdvanceCombineIntoReset() async throws {
        let (store, _, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86_400)

        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(id: "weekly", usedPercent: 10, resetAt: reset, rawWindowSeconds: 604_800)
            ]),
            now: now,
            retentionDays: 30
        )
        await store.observe(
            quota(tool: .claude, buckets: [
                bucket(
                    id: "weekly",
                    usedPercent: 9,
                    resetAt: reset.addingTimeInterval(604_800 * 0.05),
                    rawWindowSeconds: 604_800
                )
            ]),
            now: now.addingTimeInterval(60),
            retentionDays: 30
        )

        let samples = await store.samples(accountId: "acct-test", bucketId: "weekly")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.filter(\.isCompleted).count, 1)
        XCTAssertEqual(samples.first(where: \.isCompleted)?.completionReason, .scheduledReset)
    }

    func testOneTimeRepairSplitsMissedLowUsageResetFromRetainedTimeline() async throws {
        struct ExistingStorage: Codable {
            let schemaVersion: Int
            let legacyTimelineImported: Bool
            let samples: [SubscriptionWindowSample]
        }

        let (store, fileURL, cleanup) = try makeTempStore()
        defer { cleanup() }
        let now = Date()
        let oldReset = now.addingTimeInterval(3 * 86_400)
        let transition = now.addingTimeInterval(3_600)
        let newReset = oldReset.addingTimeInterval(3 * 86_400)
        let active = SubscriptionWindowSample(
            accountId: "acct-test",
            tool: .codex,
            bucketId: "gpt_5_3_codex_spark_weekly",
            windowEnd: newReset,
            windowStart: now,
            rawWindowSeconds: 604_800,
            peakUsedPercent: 1,
            lastUsedPercent: 0,
            observationCount: 20,
            firstSeenAt: now,
            lastSeenAt: transition.addingTimeInterval(3_600)
        )
        let encoded = try JSONEncoder().encode(ExistingStorage(
            schemaVersion: 2,
            legacyTimelineImported: true,
            samples: [active]
        ))
        try encoded.write(to: fileURL, options: .atomic)

        let points = [
            FillTimelinePoint(
                accountId: "acct-test",
                tool: .codex,
                bucketId: "gpt_5_3_codex_spark_weekly",
                slotStart: now,
                usedPercent: 1,
                sampledAt: now,
                resetAt: oldReset,
                rawWindowSeconds: 604_800
            ),
            FillTimelinePoint(
                accountId: "acct-test",
                tool: .codex,
                bucketId: "gpt_5_3_codex_spark_weekly",
                slotStart: transition,
                usedPercent: 0,
                sampledAt: transition,
                resetAt: newReset,
                rawWindowSeconds: 604_800
            ),
            FillTimelinePoint(
                accountId: "acct-test",
                tool: .codex,
                bucketId: "gpt_5_3_codex_spark_weekly",
                slotStart: transition.addingTimeInterval(3_600),
                usedPercent: 0,
                sampledAt: transition.addingTimeInterval(3_600),
                resetAt: newReset,
                rawWindowSeconds: 604_800
            )
        ]

        await store.importLegacyTimeline(points, retentionDays: 30)
        await store.importLegacyTimeline(points, retentionDays: 30)

        let samples = await store.samples(
            accountId: "acct-test",
            bucketId: "gpt_5_3_codex_spark_weekly"
        )
        XCTAssertEqual(samples.count, 2)
        let completed = try XCTUnwrap(samples.first(where: \.isCompleted))
        XCTAssertEqual(completed.peakUsedPercent, 1)
        XCTAssertEqual(completed.lastUsedPercent, 1)
        let current = try XCTUnwrap(samples.first(where: { !$0.isCompleted }))
        XCTAssertEqual(current.peakUsedPercent, 0)
        XCTAssertEqual(current.lastUsedPercent, 0)
        XCTAssertEqual(current.firstSeenAt, transition)
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
