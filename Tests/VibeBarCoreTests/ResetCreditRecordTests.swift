import XCTest
@testable import VibeBarCore

final class ResetCreditRecordTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ kind: ResetCreditLedgerEntry.Kind, _ offset: TimeInterval,
                       inferred: Bool = false) -> ResetCreditLedgerEntry {
        ResetCreditLedgerEntry(kind: kind, event: ResetCreditEvent(
            id: "\(kind.rawValue)-\(Int(offset))", occurredAt: base.addingTimeInterval(offset),
            inferred: inferred))
    }

    private func record(_ account: String, _ tool: ToolType, _ offset: TimeInterval,
                        inferred: Bool = false) -> QuotaResetRedemption {
        QuotaResetRedemption(accountId: account, tool: tool, credit: ResetCreditEvent(
            id: "credit-\(account)-\(Int(offset))", occurredAt: base.addingTimeInterval(offset),
            inferred: inferred))
    }

    private func cycle(_ account: String, _ tool: ToolType = .codex, bucket: String = "five_hour",
                       completed offset: TimeInterval, creditAt: TimeInterval? = nil) -> SubscriptionWindowSample {
        SubscriptionWindowSample(
            accountId: account, tool: tool, bucketId: bucket,
            windowEnd: base.addingTimeInterval(offset), peakUsedPercent: 80, lastUsedPercent: 80,
            firstSeenAt: base.addingTimeInterval(offset - 3_600), lastSeenAt: base.addingTimeInterval(offset - 60),
            completedAt: base.addingTimeInterval(offset), resetKind: .earlyClockRestarted,
            creditResetAt: creditAt.map { base.addingTimeInterval($0) })
    }

    // MARK: - Display thresholds

    func testShowsWhenACreditIsLeftOrARecordExists() {
        XCTAssertFalse(ResetCreditLedgerDisplay.shows(credits: nil, ledger: nil))
        XCTAssertFalse(ResetCreditLedgerDisplay.shows(credits: ResetCredits(availableCount: 0), ledger: []))
        XCTAssertTrue(ResetCreditLedgerDisplay.shows(credits: ResetCredits(availableCount: 1), ledger: []))
        XCTAssertTrue(ResetCreditLedgerDisplay.shows(credits: ResetCredits(availableCount: 0), ledger: [entry(.used, 0)]))
    }

    func testProviderPreviewKeepsTheNewestFourInOrder() {
        let ledger = (0..<6).map { entry(.used, -Double($0) * 60) }
        let preview = ResetCreditLedgerDisplay.visibleEntries(ledger, limit: ResetCreditLedgerDisplay.previewLimit)
        XCTAssertEqual(Array(preview), Array(ledger.prefix(4)))
    }

    func testWorkbenchRecordFoldsOnlyPastThirtyAndUnfoldsEverything() {
        let short = (0..<30).map { entry(.granted, -Double($0) * 60) }
        XCTAssertFalse(ResetCreditLedgerDisplay.isCollapsible(short))
        XCTAssertEqual(ResetCreditLedgerDisplay.visibleEntries(
            short, limit: ResetCreditLedgerDisplay.recordLimit(expanded: false)).count, 30)

        let long = (0..<45).map { entry($0.isMultiple(of: 2) ? .used : .granted, -Double($0) * 60) }
        XCTAssertTrue(ResetCreditLedgerDisplay.isCollapsible(long))
        let folded = ResetCreditLedgerDisplay.visibleEntries(
            long, limit: ResetCreditLedgerDisplay.recordLimit(expanded: false))
        XCTAssertEqual(Array(folded), Array(long.prefix(30)))
        let unfolded = ResetCreditLedgerDisplay.visibleEntries(
            long, limit: ResetCreditLedgerDisplay.recordLimit(expanded: true))
        XCTAssertEqual(Array(unfolded), long)
    }

    func testSummaryCountsUsedReceivedAndInferred() {
        let summary = ResetCreditLedgerSummary([
            entry(.used, 0), entry(.used, -60, inferred: true), entry(.granted, -120), entry(.granted, -180),
            entry(.granted, -240)
        ])
        XCTAssertEqual(summary, ResetCreditLedgerSummary(used: 2, granted: 3, inferredUsed: 1))
        let all = ResetCreditLedgerSummary.summaries(["a": [entry(.used, 0)], "b": []])
        XCTAssertEqual(all["a"]?.used, 1)
        XCTAssertEqual(all["b"], ResetCreditLedgerSummary())
    }

    // MARK: - Reset journal timeline

    func testJournalMergesCreditLinesBetweenRefillsNewestFirst() {
        let items = ResetJournalTimeline.items(
            cycles: [cycle("a", completed: -3_600), cycle("a", completed: -86_400)],
            featureResets: [],
            redemptions: [record("a", .codex, -7_200, inferred: true)],
            grants: [record("a", .codex, -600), record("a", .codex, -90_000)]
        )
        XCTAssertEqual(items.map(\.date), items.map(\.date).sorted(by: >))
        XCTAssertEqual(items.map(kindLabel), ["granted", "cycle", "used", "cycle", "granted"])
        guard case let .credit(inferred) = items[2] else { return XCTFail("expected a credit line") }
        XCTAssertTrue(inferred.entry.event.isInferred)
        XCTAssertEqual(inferred.tool, .codex)
    }

    func testSpentCreditMatchedToARefillIsNotListedTwice() {
        let items = ResetJournalTimeline.items(
            cycles: [cycle("a", completed: -3_600, creditAt: -3_630)],
            featureResets: [],
            redemptions: [record("a", .codex, -3_630), record("a", .codex, -50_000)],
            grants: []
        )
        XCTAssertEqual(items.map(kindLabel), ["cycle", "used"])
        XCTAssertEqual(items.last?.date, base.addingTimeInterval(-50_000))
    }

    func testJournalScopeFiltersCreditsByToolAndAccountAndDropsThemForABucket() {
        let cycles = [cycle("a", completed: -3_600), cycle("g", .grok, bucket: "weekly", completed: -7_200)]
        let redemptions = [record("a", .codex, -100), record("g", .grok, -200)]
        let grants = [record("a", .codex, -300), record("g", .grok, -400)]

        let grok = ResetJournalTimeline.items(cycles: cycles, featureResets: [], redemptions: redemptions,
                                              grants: grants, tools: [.grok])
        XCTAssertEqual(grok.map(kindLabel), ["used", "granted", "cycle"])
        XCTAssertTrue(grok.allSatisfy { item in
            if case let .credit(credit) = item { return credit.accountId == "g" }
            return true
        })

        let account = ResetJournalTimeline.items(cycles: cycles, featureResets: [], redemptions: redemptions,
                                                 grants: grants, accountId: "a")
        XCTAssertEqual(account.map(kindLabel), ["used", "granted", "cycle"])

        let bucket = ResetJournalTimeline.items(cycles: cycles, featureResets: [], redemptions: redemptions,
                                                grants: grants, accountId: "a", bucketId: "five_hour")
        XCTAssertEqual(bucket.map(kindLabel), ["cycle"])
    }

    func testJournalIdentitiesStayUnique() {
        let items = ResetJournalTimeline.items(
            cycles: [cycle("a", completed: -3_600)], featureResets: [],
            redemptions: [record("a", .codex, -100)], grants: [record("a", .codex, -100)])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    private func kindLabel(_ item: ResetJournalItem) -> String {
        switch item {
        case .cycle: "cycle"
        case let .credit(credit): credit.entry.kind.rawValue
        }
    }
}
