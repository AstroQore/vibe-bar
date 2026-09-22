import XCTest
@testable import VibeBarCore

/// Reset credits across Codex, Claude and Grok: parsing each provider's
/// inventory, the Codex used / received record, inferring a spent credit from
/// a falling count, and marking the cycle the credit reset.
final class ResetCreditParityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let iso = ISO8601DateFormatter()

    // MARK: Codex history

    func testCodexHistoryPageSplitsUsedAndGrantedAndHashesIDs() throws {
        let json = """
        {"events":[
          {"id":"synthetic-credit-a:used","kind":"used","occurred_at":"2026-06-17T06:42:51.488633Z"},
          {"id":"synthetic-credit-b:used","kind":"used","occurred_at":"2026-06-09T09:11:08Z"},
          {"id":"synthetic-credit-c:granted","kind":"granted","occurred_at":"2026-06-05T04:19:44.581137Z"},
          {"id":"synthetic-credit-d:other","kind":"expired","occurred_at":"2026-06-04T00:00:00Z"},
          {"id":"","kind":"used","occurred_at":"2026-06-03T00:00:00Z"}
         ],
         "window_start":"2026-05-23T19:54:11Z","as_of":"2026-06-22T19:54:11Z","next_cursor":"synthetic-cursor"}
        """
        let page = try XCTUnwrap(CodexResetCreditHistoryFetcher.parsePage(
            data: Data(json.utf8), now: iso.date(from: "2026-06-22T20:00:00Z")!))
        XCTAssertEqual(page.used.count, 2)
        XCTAssertEqual(page.granted.count, 1)
        XCTAssertEqual(page.nextCursor, "synthetic-cursor")
        XCTAssertEqual(page.used.map(\.occurredAt), page.used.map(\.occurredAt).sorted())
        XCTAssertEqual(page.used.last?.occurredAt.timeIntervalSince1970 ?? 0,
                       iso.date(from: "2026-06-17T06:42:51Z")!.timeIntervalSince1970 + 0.488633, accuracy: 0.001)
        let encoded = String(decoding: try JSONEncoder().encode(page.used + page.granted), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-credit"))
        XCTAssertTrue(page.used.allSatisfy { $0.id.hasPrefix("reset-credit-") && !$0.isInferred })
    }

    func testCodexHistoryRejectsBodiesWithoutEvents() {
        XCTAssertNil(CodexResetCreditHistoryFetcher.parsePage(data: Data(#"{"detail":"Unauthorized"}"#.utf8)))
        XCTAssertNil(CodexResetCreditHistoryFetcher.parsePage(data: Data("<html>".utf8)))
        let empty = CodexResetCreditHistoryFetcher.parsePage(data: Data(#"{"events":[],"next_cursor":null}"#.utf8))
        XCTAssertEqual(empty?.used.count, 0)
        XCTAssertNil(empty?.nextCursor)
    }

    func testCodexHistoryFollowsCursorAcrossPages() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetHistoryStubProtocol.self]
        let session = URLSession(configuration: config)
        ResetHistoryStubProtocol.handler = { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits/history")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "synthetic-account")
            switch cursor {
            case nil:
                return (200, #"{"events":[{"id":"p1","kind":"used","occurred_at":"2026-06-10T00:00:00Z"}],"next_cursor":"c2"}"#)
            case "c2":
                return (200, #"{"events":[{"id":"p2","kind":"granted","occurred_at":"2026-06-01T00:00:00Z"}],"next_cursor":"c2"}"#)
            default:
                return (500, "{}")
            }
        }
        defer { ResetHistoryStubProtocol.handler = nil }
        let page = await CodexResetCreditHistoryFetcher.fetch(
            auth: .bearer(accessToken: "synthetic-token", accountId: "synthetic-account"),
            session: session, now: iso.date(from: "2026-06-22T00:00:00Z")!)
        // The repeated cursor stops the walk instead of looping.
        XCTAssertEqual(page?.used.count, 1)
        XCTAssertEqual(page?.granted.count, 1)
    }

    func testCodexHistoryFailureIsSilent() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetHistoryStubProtocol.self]
        ResetHistoryStubProtocol.handler = { _ in (403, "<html>blocked</html>") }
        defer { ResetHistoryStubProtocol.handler = nil }
        let page = await CodexResetCreditHistoryFetcher.fetch(
            auth: .cookie(header: "synthetic=1", accountId: nil), session: URLSession(configuration: config))
        XCTAssertNil(page)
    }

    func testCodexHistoryMergeKeepsInventoryAndDoesNotDoubleAReceipt() {
        let at = base
        let credits = ResetCredits(availableCount: 1, availableExpirations: [base.addingTimeInterval(86_400)],
                                   redemptions: [ResetCreditEvent(id: "from-credits", occurredAt: at)])
        let page = CodexResetCreditHistoryFetcher.Page(
            used: [ResetCreditEvent(id: "from-history", occurredAt: at.addingTimeInterval(0.5)),
                   ResetCreditEvent(id: "older", occurredAt: at.addingTimeInterval(-3_600))],
            granted: [ResetCreditEvent(id: "grant", occurredAt: at.addingTimeInterval(-86_400))],
            nextCursor: nil)
        let merged = CodexResetCreditHistoryFetcher.merge(page, into: credits)
        XCTAssertEqual(merged.availableCount, 1)
        XCTAssertEqual(merged.availableExpirations?.count, 1)
        XCTAssertEqual(merged.redemptions?.map(\.id), ["older", "from-credits"])
        XCTAssertEqual(merged.grants?.map(\.id), ["grant"])
    }

    func testCodexHistoryGateReadsOnlyWhenSomethingCouldHaveChanged() {
        typealias Gate = CodexResetCreditHistoryGate
        XCTAssertTrue(Gate.needsFetch(previous: nil, availableCount: 0, usedPercents: [:], now: base))
        let state = Gate.State(lastAttemptAt: base, availableCount: 1, usedPercents: ["weekly": 80])
        XCTAssertFalse(Gate.needsFetch(previous: state, availableCount: 1, usedPercents: ["weekly": 85],
                                       now: base.addingTimeInterval(600)))
        XCTAssertTrue(Gate.needsFetch(previous: state, availableCount: 0, usedPercents: ["weekly": 85],
                                      now: base.addingTimeInterval(600)))
        XCTAssertTrue(Gate.needsFetch(previous: state, availableCount: 1, usedPercents: ["weekly": 2],
                                      now: base.addingTimeInterval(600)))
        XCTAssertTrue(Gate.needsFetch(previous: state, availableCount: 1, usedPercents: ["weekly": 85],
                                      now: base.addingTimeInterval(Gate.maxAge)))
    }

    // MARK: Claude cedar_ember

    private let claudeBuckets = [
        QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h", usedPercent: 9),
        QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "All models", usedPercent: 88),
        QuotaBucket(id: "weekly_fable", title: "Weekly", shortLabel: "Fable wk", usedPercent: 90, groupTitle: "Fable"),
        QuotaBucket(id: "daily_routines", title: "Today", shortLabel: "0/15", usedPercent: 0)
    ]

    private func cedarEmber(left: Int, starts: String = "2026-06-01T16:00:00+00:00",
                            ends: String = "2026-07-22T16:00:00+00:00") -> Data {
        Data("""
        {"five_hour":{"utilization":9},"extra_usage":null,
         "cedar_ember":{"eligible":true,"ineligible_reason":null,"at_limit":false,"exhausted":[],
          "grants":[{"id":"synthetic-launch-grant","label":"Synthetic launch reset","resets_total":2,
                     "resets_left":\(left),"starts_at":"\(starts)","ends_at":"\(ends)",
                     "clears":["five_hour","seven_day","seven_day_overage_included"],
                     "paused":false,"usable_now":true,"use_requires_limit":false,
                     "percent_used":{"five_hour":9,"seven_day":88,"seven_day_overage_included":90},"blocking":[]}],
          "next_grant_id":"synthetic-launch-grant","weekly_resets_at":"2026-06-24T20:00:00+00:00",
          "cooldown_until":null,"event_props":{"surface":"claude_ai"}}}
        """.utf8)
    }

    func testClaudeCedarEmberParsesCountExpiryAndClearedWindows() throws {
        let now = iso.date(from: "2026-06-22T00:00:00Z")!
        let credits = try XCTUnwrap(ClaudeResetCreditsParser.parse(data: cedarEmber(left: 2), buckets: claudeBuckets, now: now))
        XCTAssertEqual(credits.availableCount, 2)
        XCTAssertEqual(credits.availableExpirations, Array(repeating: iso.date(from: "2026-07-22T16:00:00Z")!, count: 2))
        XCTAssertEqual(credits.clearedBucketIDs, ["five_hour", "weekly", "weekly_fable"])
        XCTAssertEqual(credits.tokens?.count, 1)
        XCTAssertEqual(credits.tokens?.first?.remaining, 2)
        XCTAssertNotEqual(credits.inferenceRequiresObservedReset, true)
        let encoded = String(decoding: try JSONEncoder().encode(credits), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-launch-grant"))
    }

    func testClaudeCedarEmberNullOrAbsentGivesNoCredits() {
        XCTAssertNil(ClaudeResetCreditsParser.parse(data: Data(#"{"five_hour":{"utilization":1},"cedar_ember":null}"#.utf8), buckets: claudeBuckets))
        XCTAssertNil(ClaudeResetCreditsParser.parse(data: Data(#"{"five_hour":{"utilization":1}}"#.utf8), buckets: claudeBuckets))
        let none = ClaudeResetCreditsParser.parse(data: Data(#"{"cedar_ember":{"eligible":false,"grants":[]}}"#.utf8), buckets: claudeBuckets)
        XCTAssertEqual(none?.availableCount, 0)
        XCTAssertEqual(none?.hasAvailable, false)
    }

    func testClaudeGrantNotYetOpenOrLapsedIsNotSpendable() {
        let now = iso.date(from: "2026-06-22T00:00:00Z")!
        let future = ClaudeResetCreditsParser.parse(
            data: cedarEmber(left: 1, starts: "2026-06-30T00:00:00Z"), buckets: claudeBuckets, now: now)
        XCTAssertEqual(future?.availableCount, 0)
        let lapsed = ClaudeResetCreditsParser.parse(
            data: cedarEmber(left: 1, ends: "2026-06-21T00:00:00Z"), buckets: claudeBuckets, now: now)
        XCTAssertEqual(lapsed?.availableCount, 0)
        XCTAssertEqual(lapsed?.tokens?.count, 1)
    }

    func testClaudeClearsMappingUsesParserBucketIDs() {
        let ids = ["five_hour", "weekly", "weekly_fable", "weekly_sonnet"]
        XCTAssertEqual(ClaudeResetCreditsParser.bucketIDsCleared(by: "seven_day", in: ids), ["weekly"])
        XCTAssertEqual(ClaudeResetCreditsParser.bucketIDsCleared(by: "seven_day_overage_included", in: ids),
                       ["weekly_fable", "weekly_sonnet"])
        XCTAssertEqual(ClaudeResetCreditsParser.bucketIDsCleared(by: "seven_day_sonnet", in: ids), ["weekly_sonnet"])
        XCTAssertEqual(ClaudeResetCreditsParser.bucketIDsCleared(by: "something_else", in: ids), [])
    }

    // MARK: Grok gRPC-Web

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func delimited(_ field: UInt64, _ body: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(UInt64(body.count)) + body
    }

    private func grokToken(_ id: String, start: Date, end: Date) -> [UInt8] {
        let startTS = varint(1 << 3) + varint(UInt64(start.timeIntervalSince1970))
        let endTS = varint(1 << 3) + varint(UInt64(end.timeIntervalSince1970)) + varint(2 << 3) + varint(5)
        return delimited(10, Array(id.utf8)) + delimited(20, startTS) + delimited(30, endTS)
    }

    private func frame(_ flags: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count)
        return [flags, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + payload
    }

    private func trailer(_ status: Int, message: String = "") -> [UInt8] {
        frame(0x80, Array("grpc-status:\(status)\r\ngrpc-message:\(message)\r\n".utf8))
    }

    func testGrokRemainingResetsParsesTokens() throws {
        let later = base.addingTimeInterval(20 * 86_400)
        let sooner = base.addingTimeInterval(5 * 86_400)
        let message = delimited(10, grokToken("synthetic-token-a", start: base, end: later))
            + delimited(10, grokToken("synthetic-token-b", start: base, end: sooner))
            + delimited(10, grokToken("synthetic-token-c", start: base.addingTimeInterval(-40 * 86_400),
                                      end: base.addingTimeInterval(-86_400)))
        let body = Data(frame(0, message) + trailer(0))
        let credits = try XCTUnwrap(GrokRemainingResetsFetcher.parse(body, now: base))
        XCTAssertEqual(credits.availableCount, 2)
        XCTAssertEqual(credits.availableExpirations, [sooner, later])
        XCTAssertEqual(credits.tokens?.count, 3)
        XCTAssertEqual(credits.inferenceRequiresObservedReset, true)
        XCTAssertEqual(credits.tokens?.first?.clears, ["weekly"])
        let encoded = String(decoding: try JSONEncoder().encode(credits), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-token"))
    }

    func testGrokRemainingResetsEmptyResponseIsZeroTokens() {
        XCTAssertEqual(GrokRemainingResetsFetcher.parse(Data(trailer(0)), now: base)?.availableCount, 0)
        XCTAssertEqual(GrokRemainingResetsFetcher.parse(Data(frame(0, []) + trailer(0)), now: base)?.availableCount, 0)
        XCTAssertEqual(GrokRemainingResetsFetcher.parse(Data(), now: base)?.availableCount, 0)
    }

    func testGrokRemainingResetsErrorTrailerIsNotAZeroCount() {
        XCTAssertNil(GrokRemainingResetsFetcher.parse(Data(trailer(16, message: "unauthenticated")), now: base))
        XCTAssertNil(GrokRemainingResetsFetcher.parse(Data(frame(0, []) + trailer(7)), now: base))
        XCTAssertEqual(GrokRemainingResetsFetcher.grpcStatus(headers: [:], body: Data(trailer(16))), 16)
        XCTAssertEqual(GrokRemainingResetsFetcher.grpcStatus(headers: ["Grpc-Status": "5"], body: Data()), 5)
        // A torn frame is not a response.
        XCTAssertNil(GrokRemainingResetsFetcher.parse(Data([0, 0, 0, 0, 9, 1, 2]), now: base))
    }

    // MARK: Inference

    func testFallingCountWithFutureExpiryIsARedemption() {
        let token = ResetCreditToken(id: "grant", remaining: 2, expiresAt: base.addingTimeInterval(86_400), clears: ["five_hour"])
        var spent = token
        spent.remaining = 1
        let events = ResetCredits.inferredRedemptions(
            previous: [token], previousObservedAt: base, current: [spent], now: base.addingTimeInterval(300))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.isInferred, true)
        XCTAssertEqual(events.first?.occurredAt, base.addingTimeInterval(300))
        XCTAssertEqual(events.first?.observedAfter, base)
        XCTAssertEqual(events.first?.clears, ["five_hour"])
        // A vanished token counts as spent too.
        XCTAssertEqual(ResetCredits.inferredRedemptions(
            previous: [token], previousObservedAt: base, current: [], now: base.addingTimeInterval(300)).count, 2)
    }

    func testFallingCountBecauseOfExpiryIsNotARedemption() {
        let expiring = ResetCreditToken(id: "grant", remaining: 1, expiresAt: base.addingTimeInterval(100))
        XCTAssertTrue(ResetCredits.inferredRedemptions(
            previous: [expiring], previousObservedAt: base, current: [], now: base.addingTimeInterval(300)).isEmpty)
        let unknownExpiry = ResetCreditToken(id: "grant", remaining: 1, expiresAt: nil)
        XCTAssertTrue(ResetCredits.inferredRedemptions(
            previous: [unknownExpiry], previousObservedAt: base, current: [], now: base.addingTimeInterval(300)).isEmpty)
        let steady = ResetCreditToken(id: "grant", remaining: 1, expiresAt: base.addingTimeInterval(86_400))
        XCTAssertTrue(ResetCredits.inferredRedemptions(
            previous: [steady], previousObservedAt: base, current: [steady], now: base.addingTimeInterval(300)).isEmpty)
    }

    // MARK: Store

    private func makeStore() throws -> (SubscriptionHistoryStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        return (SubscriptionHistoryStore(fileURL: url), url)
    }

    private func claudeQuota(five: Double, weekly: Double, left: Int) -> AccountQuota {
        let expiry = base.addingTimeInterval(30 * 86_400)
        return AccountQuota(
            accountId: "synthetic-claude", tool: .claude,
            buckets: [
                QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h", usedPercent: five,
                            resetAt: base.addingTimeInterval(18_000), rawWindowSeconds: 18_000),
                QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "All models", usedPercent: weekly,
                            resetAt: base.addingTimeInterval(5 * 86_400), rawWindowSeconds: 604_800)
            ],
            resetCredits: ResetCredits(availableCount: left, tokens: [
                ResetCreditToken(id: "synthetic-grant", remaining: left, expiresAt: expiry, clears: ["five_hour", "weekly"])
            ]))
    }

    func testClaudeSpentResetIsInferredAndMarksTheClearedCycles() async throws {
        let (store, url) = try makeStore()
        await store.observe(claudeQuota(five: 60, weekly: 90, left: 1), now: base)
        await store.observe(claudeQuota(five: 62, weekly: 91, left: 1), now: base.addingTimeInterval(300))
        // Spent: both windows refill and the grant count falls in one read.
        var spent = claudeQuota(five: 0, weekly: 0, left: 0)
        spent.buckets[0].resetAt = base.addingTimeInterval(600 + 18_000)
        spent.buckets[1].resetAt = base.addingTimeInterval(600 + 604_800)
        await store.observe(spent, now: base.addingTimeInterval(600))
        await store.flushPendingWrites()

        let reloaded = SubscriptionHistoryStore(fileURL: url)
        let receipts = await reloaded.allRedemptions()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.credit.isInferred, true)
        XCTAssertEqual(receipts.first?.resolvedTool, .claude)
        let completed = await reloaded.allSamples().filter(\.isCompleted)
        XCTAssertEqual(Set(completed.map(\.bucketId)), ["five_hour", "weekly"])
        for cycle in completed {
            XCTAssertEqual(cycle.creditRedemptionDate, base.addingTimeInterval(600))
            XCTAssertTrue(cycle.creditRedemptionInferred)
            // An inference is not written where older builds read receipts.
            XCTAssertNil(cycle.resetDetails?.creditRedeemedAt)
        }
    }

    func testClaudeGrantExpiringIsNotRecordedAsSpent() async throws {
        let (store, _) = try makeStore()
        var quota = claudeQuota(five: 60, weekly: 90, left: 1)
        quota.resetCredits?.tokens?[0].expiresAt = base.addingTimeInterval(100)
        await store.observe(quota, now: base)
        await store.observe(claudeQuota(five: 61, weekly: 90, left: 0), now: base.addingTimeInterval(300))
        let receipts = await store.allRedemptions()
        XCTAssertTrue(receipts.isEmpty)
    }

    private func grokQuota(used: Double, resetAt: Date, tokens: [ResetCreditToken]) -> AccountQuota {
        AccountQuota(
            accountId: "synthetic-grok", tool: .grok,
            buckets: [QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Weekly", usedPercent: used,
                                  resetAt: resetAt, rawWindowSeconds: 604_800)],
            resetCredits: ResetCredits(availableCount: tokens.count, tokens: tokens,
                                       inferenceRequiresObservedReset: true))
    }

    func testGrokTokenDisappearingNeedsAnEarlyWeeklyReset() async throws {
        let token = ResetCreditToken(id: "synthetic-token", remaining: 1,
                                     expiresAt: base.addingTimeInterval(20 * 86_400), clears: ["weekly"])
        let reset = base.addingTimeInterval(3 * 86_400)

        // Vanishes with no refill: not a redemption.
        let (quiet, _) = try makeStore()
        await quiet.observe(grokQuota(used: 70, resetAt: reset, tokens: [token]), now: base)
        await quiet.observe(grokQuota(used: 71, resetAt: reset, tokens: []), now: base.addingTimeInterval(300))
        let none = await quiet.allRedemptions()
        XCTAssertTrue(none.isEmpty)

        // Vanishes while the weekly window refills early: a redemption, and
        // the weekly cycle is its reset.
        let (store, _) = try makeStore()
        await store.observe(grokQuota(used: 70, resetAt: reset, tokens: [token]), now: base)
        let restarted = base.addingTimeInterval(300 + 604_800)
        await store.observe(grokQuota(used: 0, resetAt: restarted, tokens: []), now: base.addingTimeInterval(300))
        let receipts = await store.allRedemptions()
        XCTAssertEqual(receipts.count, 1)
        let cycle = await store.allSamples().first(where: \.isCompleted)
        XCTAssertEqual(cycle?.creditRedemptionDate, base.addingTimeInterval(300))
    }

    // MARK: Late receipts and older files

    private func writeLegacyHistory(_ samples: [SubscriptionWindowSample], to url: URL) throws {
        let encoded = try JSONEncoder().encode(samples)
        let json = #"{"schemaVersion":2,"legacyTimelineImported":true,"resetSignalRepairVersion":1,"promotedProviderBackfillVersion":1,"samples":"#
            + String(decoding: encoded, as: UTF8.self) + "}"
        try Data(json.utf8).write(to: url)
    }

    func testLateReceiptMarksACycleWrittenWithoutDetails() async throws {
        let (_, url) = try makeStore()
        // Rebuilt from the hourly timeline: no `resetDetails`, an hour between
        // the last pre-refill read and the refill.
        let legacy = SubscriptionWindowSample(
            accountId: "synthetic-codex", tool: .codex, bucketId: "weekly",
            windowEnd: base.addingTimeInterval(3_600), peakUsedPercent: 100, lastUsedPercent: 100,
            firstSeenAt: base.addingTimeInterval(-86_400), lastSeenAt: base,
            completedAt: base.addingTimeInterval(3_600), completionReason: .legacyTimelineMigration,
            resetKind: .earlyClockRestarted)
        let unrelated = SubscriptionWindowSample(
            accountId: "synthetic-codex", tool: .codex, bucketId: "weekly",
            windowEnd: base.addingTimeInterval(-86_400), peakUsedPercent: 40, lastUsedPercent: 40,
            firstSeenAt: base.addingTimeInterval(-7 * 86_400), lastSeenAt: base.addingTimeInterval(-90_000),
            completedAt: base.addingTimeInterval(-86_400), completionReason: .legacyTimelineMigration,
            resetKind: .earlyClockRestarted)
        let otherAccount = SubscriptionWindowSample(
            accountId: "synthetic-other", tool: .codex, bucketId: "weekly",
            windowEnd: base.addingTimeInterval(3_600), peakUsedPercent: 100, lastUsedPercent: 100,
            firstSeenAt: base.addingTimeInterval(-86_400), lastSeenAt: base,
            completedAt: base.addingTimeInterval(3_600), completionReason: .legacyTimelineMigration,
            resetKind: .earlyClockRestarted)
        try writeLegacyHistory([unrelated, legacy, otherAccount], to: url)

        let store = SubscriptionHistoryStore(fileURL: url)
        let receipt = ResetCreditEvent(id: "synthetic-receipt", occurredAt: base.addingTimeInterval(900))
        let quota = AccountQuota(
            accountId: "synthetic-codex", tool: .codex,
            buckets: [QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Weekly", usedPercent: 3,
                                  resetAt: base.addingTimeInterval(604_800), rawWindowSeconds: 604_800)],
            resetCredits: ResetCredits(availableCount: 0, redemptions: [receipt],
                                       grants: [ResetCreditEvent(id: "synthetic-grant", occurredAt: base.addingTimeInterval(-86_400))]))
        await store.observe(quota, now: base.addingTimeInterval(7_200))
        await store.flushPendingWrites()

        let reloaded = SubscriptionHistoryStore(fileURL: url)
        let marked = await reloaded.allSamples().filter { $0.creditRedemptionDate != nil }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.accountId, "synthetic-codex")
        XCTAssertEqual(marked.first?.completedAt, base.addingTimeInterval(3_600))
        XCTAssertEqual(marked.first?.creditRedemptionDate, receipt.occurredAt)
        XCTAssertFalse(marked.first?.creditRedemptionInferred ?? true)
        XCTAssertNil(marked.first?.resetDetails)
        let grants = await reloaded.allResetCreditGrants()
        XCTAssertEqual(grants.count, 1)
        let redemptions = await reloaded.allRedemptions()
        XCTAssertEqual(redemptions.map(\.credit.id), ["synthetic-receipt"])
    }

    func testOldCodexNamedCacheAndHistoryFilesStillDecode() throws {
        // A quota cache file written by the Codex-only build.
        let cache = """
        {"tool":"codex","buckets":[],"queriedAt":0,
         "resetCredits":{"availableCount":1,"nextExpiresAt":86400,"availableExpirations":[86400],
                         "redemptions":[{"id":"reset-credit-synthetic","redeemedAt":3600}]}}
        """
        let stored = try JSONDecoder().decode(QuotaCacheStore.StoredQuota.self, from: Data(cache.utf8))
        let quota = stored.quota(accountId: "synthetic-codex")
        XCTAssertEqual(quota.resetCredits?.availableCount, 1)
        XCTAssertEqual(quota.resetCredits?.redemptions?.first?.occurredAt, Date(timeIntervalSinceReferenceDate: 3_600))
        XCTAssertFalse(quota.resetCredits?.redemptions?.first?.isInferred ?? true)

        // And the receipt keeps its old key on the way back out.
        let encoded = String(decoding: try JSONEncoder().encode(quota.resetCredits), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"redeemedAt\""))

        // A history receipt with no `tool` was a Codex one.
        let receipt = try JSONDecoder().decode(QuotaResetRedemption.self, from: Data(
            #"{"accountId":"synthetic-codex","credit":{"id":"reset-credit-synthetic","redeemedAt":3600}}"#.utf8))
        XCTAssertEqual(receipt.resolvedTool, .codex)
    }

    func testLedgerIsNewestFirstPerAccount() {
        let used = QuotaResetRedemption(accountId: "a", tool: .codex, credit: ResetCreditEvent(id: "u", occurredAt: base))
        let granted = QuotaResetRedemption(accountId: "a", tool: .codex,
                                           credit: ResetCreditEvent(id: "g", occurredAt: base.addingTimeInterval(-60)))
        let other = QuotaResetRedemption(accountId: "b", tool: .grok, credit: ResetCreditEvent(id: "o", occurredAt: base))
        let ledger = ResetCreditLedgerEntry.ledger(redemptions: [used, other], grants: [granted])
        XCTAssertEqual(ledger["a"]?.map(\.kind), [.used, .granted])
        XCTAssertEqual(ledger["b"]?.count, 1)
    }
}

private final class ResetHistoryStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
