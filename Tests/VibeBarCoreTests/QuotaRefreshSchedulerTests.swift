import XCTest
@testable import VibeBarCore

@MainActor
final class QuotaRefreshSchedulerTests: XCTestCase {
    func testTriggerRefreshRunsSupplementalRefreshEvenWithoutAccounts() {
        var supplementalRefreshCount = 0
        let service = QuotaService(adapters: [:], mockProvider: { false })
        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [] },
            intervalProvider: { 600 },
            onRefreshTriggered: {
                supplementalRefreshCount += 1
            }
        )

        scheduler.triggerRefresh()

        XCTAssertEqual(supplementalRefreshCount, 1)
    }

    func testCredentialFailureDoesNotPoisonVisibleCachedQuota() async {
        let account = AccountIdentity(id: "cached-claude", tool: .claude, source: .oauthCLI)
        let service = QuotaService(
            adapters: [.claude: SequenceAdapter(results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .claude,
                    buckets: [
                        QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h", usedPercent: 10)
                    ],
                    queriedAt: Date()
                )),
                .failure(.needsLogin)
            ])],
            mockProvider: { false }
        )

        let first = await service.refresh(account)
        XCTAssertNil(first.error)
        XCTAssertNil(service.lastErrorByAccount[account.id])

        let second = await service.refresh(account)
        XCTAssertEqual(second.buckets.count, 1)
        XCTAssertNil(second.error)
        XCTAssertNil(service.lastErrorByAccount[account.id])
    }
}

private final class SequenceAdapter: QuotaAdapter, @unchecked Sendable {
    let tool: ToolType = .claude
    private var results: [Result<AccountQuota, QuotaError>]

    init(results: [Result<AccountQuota, QuotaError>]) {
        self.results = results
    }

    func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard !results.isEmpty else { throw QuotaError.unknown("empty sequence") }
        switch results.removeFirst() {
        case .success(let quota):
            return quota
        case .failure(let error):
            throw error
        }
    }
}
