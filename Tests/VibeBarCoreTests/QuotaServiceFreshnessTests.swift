import Foundation
import XCTest
@testable import VibeBarCore

/// `lastUpdatedByAccount` must mean "when the visible data was fetched".
/// A failed refresh writing to it made every card claim it had just updated
/// while it kept drawing hours-old buckets.
@MainActor
final class QuotaServiceFreshnessTests: XCTestCase {
    func testFailedRefreshRecordsAnAttemptWithoutTouchingTheSuccessTimestamp() async throws {
        let account = AccountIdentity(id: "freshness-fail", tool: .gemini, source: .webCookie)
        // Older than `credentialFallbackMaxAge`, so the failure is genuinely
        // surfaced rather than absorbed by the cached-credential grace.
        let queriedAt = Date().addingTimeInterval(-8 * 3_600)
        let service = QuotaService(
            adapters: [.gemini: FreshnessSequenceAdapter(tool: .gemini, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .gemini,
                    buckets: [QuotaBucket(
                        id: "five_hour",
                        title: "5 Hours",
                        shortLabel: "5 Hours",
                        usedPercent: 0
                    )],
                    queriedAt: queriedAt
                )),
                .failure(.needsLogin)
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)
        XCTAssertEqual(service.lastUpdatedByAccount[account.id], queriedAt)

        let beforeFailure = Date()
        _ = await service.refresh(account)

        XCTAssertEqual(service.lastUpdatedByAccount[account.id], queriedAt)
        XCTAssertEqual(service.lastErrorByAccount[account.id], .needsLogin)
        let attempted = try XCTUnwrap(service.lastAttemptedByAccount[account.id])
        XCTAssertGreaterThanOrEqual(attempted, beforeFailure)
    }

    /// The credential-state path returns early without recording the error,
    /// but it is still an attempt.
    func testAbsorbedCredentialFailureStillRecordsAnAttempt() async throws {
        let account = AccountIdentity(id: "freshness-absorbed", tool: .claude, source: .oauthCLI)
        let queriedAt = Date()
        let service = QuotaService(
            adapters: [.claude: FreshnessSequenceAdapter(results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .claude,
                    buckets: [QuotaBucket(
                        id: "five_hour",
                        title: "5 Hours",
                        shortLabel: "5h",
                        usedPercent: 10
                    )],
                    queriedAt: queriedAt
                )),
                .failure(.needsLogin)
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)
        let beforeFailure = Date()
        _ = await service.refresh(account)

        XCTAssertNil(service.lastErrorByAccount[account.id])
        XCTAssertEqual(service.lastUpdatedByAccount[account.id], queriedAt)
        let attempted = try XCTUnwrap(service.lastAttemptedByAccount[account.id])
        XCTAssertGreaterThanOrEqual(attempted, beforeFailure)
    }

    func testSuccessAdvancesBothTimestamps() async throws {
        let account = AccountIdentity(id: "freshness-success", tool: .gemini, source: .webCookie)
        let queriedAt = Date()
        let service = QuotaService(
            adapters: [.gemini: FreshnessSequenceAdapter(tool: .gemini, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .gemini,
                    buckets: [],
                    queriedAt: queriedAt
                ))
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)

        XCTAssertEqual(service.lastUpdatedByAccount[account.id], queriedAt)
        let attempted = try XCTUnwrap(service.lastAttemptedByAccount[account.id])
        XCTAssertGreaterThanOrEqual(attempted, queriedAt)
    }

    func testErrorBearingQuotaPreservesTheLastSuccessfulCache() async throws {
        let account = AccountIdentity(id: "embedded-error-cache", tool: .kimi, source: .browserCookie)
        let queriedAt = Date().addingTimeInterval(-8 * 3_600)
        let cachedBucket = QuotaBucket(
            id: "kimi.weekly",
            title: "Weekly",
            shortLabel: "Wk",
            usedPercent: 25
        )
        let service = QuotaService(
            adapters: [.kimi: FreshnessSequenceAdapter(tool: .kimi, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .kimi,
                    buckets: [cachedBucket],
                    queriedAt: queriedAt
                )),
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .kimi,
                    buckets: [],
                    queriedAt: Date(),
                    error: .network("upstream")
                ))
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)
        let returned = await service.refresh(account)

        XCTAssertEqual(returned.buckets, [cachedBucket])
        XCTAssertEqual(returned.error, .network("upstream"))
        XCTAssertEqual(service.cachedQuota(for: account.id)?.buckets, [cachedBucket])
        XCTAssertEqual(service.lastUpdatedByAccount[account.id], queriedAt)
        XCTAssertEqual(service.lastErrorByAccount[account.id], .network("upstream"))
    }

    func testErrorBearingQuotaWithoutCacheDoesNotBecomeASuccess() async {
        let account = AccountIdentity(id: "embedded-error-empty", tool: .kimi, source: .browserCookie)
        let service = QuotaService(
            adapters: [.kimi: FreshnessSequenceAdapter(tool: .kimi, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .kimi,
                    buckets: [],
                    queriedAt: Date(),
                    error: .needsLogin
                ))
            ])],
            mockProvider: { false }
        )

        let returned = await service.refresh(account)

        XCTAssertTrue(returned.buckets.isEmpty)
        XCTAssertEqual(returned.error, .needsLogin)
        XCTAssertNil(service.cachedQuota(for: account.id))
        XCTAssertNil(service.lastUpdatedByAccount[account.id])
        XCTAssertEqual(service.lastErrorByAccount[account.id], .needsLogin)
    }

    func testClearingAnAccountDropsBothTimestamps() async {
        let account = AccountIdentity(id: "freshness-clear", tool: .gemini, source: .webCookie)
        let service = QuotaService(
            adapters: [.gemini: FreshnessSequenceAdapter(tool: .gemini, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .gemini,
                    buckets: [],
                    queriedAt: Date()
                ))
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)
        service.clear(accountId: account.id)

        XCTAssertNil(service.lastUpdatedByAccount[account.id])
        XCTAssertNil(service.lastAttemptedByAccount[account.id])
    }
}

private final class FreshnessSequenceAdapter: QuotaAdapter, @unchecked Sendable {
    let tool: ToolType
    private var results: [Result<AccountQuota, QuotaError>]

    init(tool: ToolType = .claude, results: [Result<AccountQuota, QuotaError>]) {
        self.tool = tool
        self.results = results
    }

    func fetch(for _: AccountIdentity) async throws -> AccountQuota {
        guard !results.isEmpty else { throw QuotaError.unknown("empty sequence") }
        switch results.removeFirst() {
        case .success(let quota): return quota
        case .failure(let error): throw error
        }
    }
}
