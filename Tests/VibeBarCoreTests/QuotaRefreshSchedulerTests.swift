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

    func testPopoverOpenRefreshHonorsToggleAndCooldown() {
        var refreshCount = 0
        let service = QuotaService(adapters: [:], mockProvider: { false })
        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [] },
            intervalProvider: { 600 },
            onRefreshTriggered: { refreshCount += 1 }
        )
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertFalse(scheduler.triggerRefreshForPopoverOpenIfNeeded(
            enabled: false,
            cooldownSeconds: 60,
            now: start
        ))
        XCTAssertTrue(scheduler.triggerRefreshForPopoverOpenIfNeeded(
            enabled: true,
            cooldownSeconds: 60,
            now: start
        ))
        XCTAssertFalse(scheduler.triggerRefreshForPopoverOpenIfNeeded(
            enabled: true,
            cooldownSeconds: 60,
            now: start.addingTimeInterval(59)
        ))
        XCTAssertTrue(scheduler.triggerRefreshForPopoverOpenIfNeeded(
            enabled: true,
            cooldownSeconds: 60,
            now: start.addingTimeInterval(60)
        ))
        XCTAssertEqual(refreshCount, 2)
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

    func testCredentialFailureSurfacesWhenCachedQuotaIsStale() async {
        let account = AccountIdentity(id: "stale-gemini", tool: .gemini, source: .webCookie)
        let staleDate = Date().addingTimeInterval(-2 * 3_600)
        let service = QuotaService(
            adapters: [.gemini: SequenceAdapter(tool: .gemini, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .gemini,
                    buckets: [
                        QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Wk", usedPercent: 1)
                    ],
                    queriedAt: staleDate
                )),
                .failure(.needsLogin)
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)
        XCTAssertTrue(service.needsRefresh(accountId: account.id, maxAge: 600))
        let fallback = await service.refresh(account)

        XCTAssertEqual(fallback.error, .needsLogin)
        XCTAssertEqual(service.lastErrorByAccount[account.id], .needsLogin)
        XCTAssertEqual(fallback.buckets.count, 1)
    }

    func testExpiredResetMakesFreshCacheRefreshable() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountIdentity(id: "expired-reset", tool: .antigravity, source: .localProbe)
        let service = QuotaService(
            adapters: [.antigravity: SequenceAdapter(tool: .antigravity, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .antigravity,
                    buckets: [QuotaBucket(
                        id: "gemini_five_hour",
                        title: "5 Hours",
                        shortLabel: "5 Hours",
                        usedPercent: 2,
                        resetAt: now.addingTimeInterval(-1),
                        rawWindowSeconds: 18_000
                    )],
                    queriedAt: now
                ))
            ])],
            mockProvider: { false }
        )

        _ = await service.refresh(account)
        XCTAssertTrue(service.needsRefresh(accountId: account.id, now: now, maxAge: 600))
    }

    func testPopoverStaleCachePathActuallyRefreshesExpiredReset() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountIdentity(id: "expired-page", tool: .antigravity, source: .localProbe)
        let expired = QuotaBucket(
            id: "gemini_five_hour",
            title: "5 Hours",
            shortLabel: "5 Hours",
            usedPercent: 2,
            resetAt: now.addingTimeInterval(-1),
            rawWindowSeconds: 18_000
        )
        let refreshed = QuotaBucket(
            id: "gemini_five_hour",
            title: "5 Hours",
            shortLabel: "5 Hours",
            usedPercent: 0,
            resetAt: now.addingTimeInterval(18_000),
            rawWindowSeconds: 18_000
        )
        let service = QuotaService(
            adapters: [.antigravity: SequenceAdapter(tool: .antigravity, results: [
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .antigravity,
                    buckets: [expired],
                    queriedAt: now
                )),
                .success(AccountQuota(
                    accountId: account.id,
                    tool: .antigravity,
                    buckets: [refreshed],
                    queriedAt: now
                ))
            ])],
            mockProvider: { false }
        )
        _ = await service.refresh(account)
        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [account] },
            intervalProvider: { 600 }
        )

        XCTAssertTrue(scheduler.triggerRefreshForStaleCacheIfNeeded(now: now))
        XCTAssertFalse(scheduler.triggerRefreshForStaleCacheIfNeeded(now: now))
        for _ in 0..<20 {
            if service.cachedQuota(for: account.id)?.buckets.first?.resetAt == refreshed.resetAt {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(
            service.cachedQuota(for: account.id)?.buckets.first?.resetAt,
            refreshed.resetAt
        )
        XCTAssertFalse(scheduler.triggerRefreshForStaleCacheIfNeeded(now: now))
    }

    func testFullRefreshQueuesAccountsMissingFromActiveStaleWalk() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = AccountIdentity(id: "stale-a", tool: .antigravity, source: .localProbe)
        let other = AccountIdentity(id: "full-b", tool: .claude, source: .oauthCLI)
        func quota(_ account: AccountIdentity, reset: Date?) -> AccountQuota {
            AccountQuota(
                accountId: account.id,
                tool: account.tool,
                buckets: [QuotaBucket(
                    id: "weekly",
                    title: "Weekly",
                    shortLabel: "Weekly",
                    usedPercent: 1,
                    resetAt: reset
                )],
                queriedAt: now
            )
        }
        let service = QuotaService(
            adapters: [
                .antigravity: SequenceAdapter(tool: .antigravity, results: [
                    .success(quota(stale, reset: now.addingTimeInterval(-1))),
                    .success(quota(stale, reset: now.addingTimeInterval(600)))
                ]),
                .claude: SequenceAdapter(tool: .claude, results: [
                    .success(quota(other, reset: now.addingTimeInterval(600)))
                ])
            ],
            mockProvider: { false }
        )
        _ = await service.refresh(stale)
        var accounts = [stale]
        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { accounts },
            intervalProvider: { 600 }
        )

        XCTAssertTrue(scheduler.triggerRefreshForStaleCacheIfNeeded(now: now))
        accounts = [stale, other]
        scheduler.triggerRefresh()
        for _ in 0..<40 {
            if service.cachedQuota(for: other.id) != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(service.cachedQuota(for: other.id))
    }

    /// `quota.refresh {tools:[...]}` without `force` reaches this method, so a
    /// scoped ask must not sweep the providers the caller did not name — and
    /// an explicitly empty list must select nothing rather than everything.
    func testStaleCacheRefreshHonorsTheToolsFilter() async {
        let claude = AccountIdentity(id: "scoped-claude", tool: .claude, source: .oauthCLI)
        let gemini = AccountIdentity(id: "scoped-gemini", tool: .gemini, source: .webCookie)
        let claudeAdapter = CountingQuotaAdapter(tool: .claude)
        let geminiAdapter = CountingQuotaAdapter(tool: .gemini)
        let service = QuotaService(
            adapters: [.claude: claudeAdapter, .gemini: geminiAdapter],
            mockProvider: { false }
        )
        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [claude, gemini] },
            intervalProvider: { 600 }
        )

        // Nothing has ever been fetched, so both accounts are stale.
        XCTAssertFalse(scheduler.triggerRefreshForStaleCacheIfNeeded(tools: []))
        XCTAssertTrue(scheduler.triggerRefreshForStaleCacheIfNeeded(tools: [.claude]))
        for _ in 0..<40 {
            if claudeAdapter.fetchCount == 1 { break }
            await Task.yield()
        }

        XCTAssertEqual(claudeAdapter.fetchCount, 1)
        XCTAssertEqual(geminiAdapter.fetchCount, 0, "A scoped refresh must leave the others alone.")
    }

    func testBoundaryRefreshRequeuesAccountCompletedEarlierInActiveWalk() async {
        let first = AccountIdentity(id: "finished-a", tool: .claude, source: .oauthCLI)
        let blocking = AccountIdentity(id: "blocking-b", tool: .gemini, source: .webCookie)
        let counter = CountingQuotaAdapter(tool: .claude)
        let gate = QuotaRefreshGate()
        let service = QuotaService(
            adapters: [
                .claude: counter,
                .gemini: GatedQuotaAdapter(tool: .gemini, gate: gate)
            ],
            mockProvider: { false }
        )
        let scheduler = QuotaRefreshScheduler(
            service: service,
            accountsProvider: { [first, blocking] },
            intervalProvider: { 600 }
        )

        scheduler.triggerRefresh()
        await gate.waitUntilStarted()
        XCTAssertEqual(counter.fetchCount, 1)

        scheduler.triggerBoundaryRefresh(accountIds: [first.id])
        await gate.release()
        for _ in 0..<40 {
            if counter.fetchCount == 2 { break }
            await Task.yield()
        }

        XCTAssertEqual(counter.fetchCount, 2)
    }
}

private final class SequenceAdapter: QuotaAdapter, @unchecked Sendable {
    let tool: ToolType
    private var results: [Result<AccountQuota, QuotaError>]

    init(tool: ToolType = .claude, results: [Result<AccountQuota, QuotaError>]) {
        self.tool = tool
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

private final class CountingQuotaAdapter: QuotaAdapter, @unchecked Sendable {
    let tool: ToolType
    private let lock = NSLock()
    private var count = 0

    init(tool: ToolType) {
        self.tool = tool
    }

    var fetchCount: Int {
        lock.withLock { count }
    }

    func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        lock.withLock { count += 1 }
        return AccountQuota(accountId: account.id, tool: tool, buckets: [], queriedAt: Date())
    }
}

private actor QuotaRefreshGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func block() async {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class GatedQuotaAdapter: QuotaAdapter, @unchecked Sendable {
    let tool: ToolType
    private let gate: QuotaRefreshGate

    init(tool: ToolType, gate: QuotaRefreshGate) {
        self.tool = tool
        self.gate = gate
    }

    func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        await gate.block()
        return AccountQuota(accountId: account.id, tool: tool, buckets: [], queriedAt: Date())
    }
}
