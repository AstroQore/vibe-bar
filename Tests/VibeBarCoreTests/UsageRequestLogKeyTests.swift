import XCTest
@testable import VibeBarCore

/// When the Usage page's request log re-reads its first page: a new
/// filter, a new day, a new ledger revision or a user refresh — and not a
/// background re-read that only moved the window's rolling end.
final class UsageRequestLogKeyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        end: TimeInterval = 3_600,
        harnesses: [Harness]? = nil,
        project: String? = nil,
        revision: UInt64? = 1
    ) -> UsageDashboardSnapshot {
        var snapshot = UsageDashboardSnapshot.empty(query: UsageDashboardQuery(
            range: .week,
            interval: DateInterval(start: start, end: start.addingTimeInterval(end)),
            harnesses: harnesses,
            project: project
        ))
        snapshot.ledgerRevision = revision
        return snapshot
    }

    func testABackgroundReReadOfTheSameDataKeepsThePages() {
        let loaded = UsageRequestLogKey(snapshot())
        let next = UsageRequestLogKey(snapshot(end: 3_660))
        XCTAssertFalse(UsageRequestLogKey.needsReload(loaded: loaded, next: next, userRefresh: false))
    }

    func testNewLedgerRowsReloadThePages() {
        let loaded = UsageRequestLogKey(snapshot(revision: 1))
        let next = UsageRequestLogKey(snapshot(end: 3_660, revision: 2))
        XCTAssertTrue(UsageRequestLogKey.needsReload(loaded: loaded, next: next, userRefresh: false))
    }

    func testARefreshReloadsEvenWithNothingNew() {
        let key = UsageRequestLogKey(snapshot())
        XCTAssertTrue(UsageRequestLogKey.needsReload(loaded: key, next: key, userRefresh: true))
    }

    func testFiltersAndFirstLoadReload() {
        let loaded = UsageRequestLogKey(snapshot())
        XCTAssertTrue(UsageRequestLogKey.needsReload(loaded: nil, next: loaded, userRefresh: false))
        XCTAssertTrue(UsageRequestLogKey.needsReload(
            loaded: loaded, next: UsageRequestLogKey(snapshot(harnesses: [.codex])), userRefresh: false
        ))
        XCTAssertTrue(UsageRequestLogKey.needsReload(
            loaded: loaded, next: UsageRequestLogKey(snapshot(project: "/Users/example/Code/alpha")), userRefresh: false
        ))
    }

    func testTheSnapshotCarriesTheLedgersRevision() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("RequestLogKey")
        defer { try? FileManager.default.removeItem(at: directory) }
        let aggregator = UsageDashboardAggregator(ledger: ledger, sessions: nil, structures: nil, activity: nil)
        let now = Date()
        let query = UsageDashboardQuery(range: .week, interval: await aggregator.interval(for: .week, harnesses: nil, now: now))
        let before = await aggregator.snapshot(query, now: now)
        try await ledger.ingest(UsageLedgerFixtures.batch(events: [
            UsageLedgerFixtures.priced(UsageLedgerFixtures.event(date: now.addingTimeInterval(-60), messageId: "m1")),
        ]))
        let after = await aggregator.snapshot(query, now: now)
        XCTAssertNotNil(before.ledgerRevision)
        XCTAssertNotEqual(before.ledgerRevision, after.ledgerRevision)
        XCTAssertTrue(UsageRequestLogKey.needsReload(
            loaded: UsageRequestLogKey(before), next: UsageRequestLogKey(after), userRefresh: false
        ))
        XCTAssertEqual(after.hero.requests, 1)
    }
}
