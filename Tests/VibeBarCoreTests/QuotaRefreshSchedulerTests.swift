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
}
