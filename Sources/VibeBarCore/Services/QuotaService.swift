import Foundation

/// QuotaService routes a request to the right adapter, tracks last-success
/// quota per account so callers can fall back to cached data on transient
/// failures, and supports a global mock-mode override.
@MainActor
public final class QuotaService: ObservableObject {
    @Published public private(set) var lastSuccessByAccount: [String: AccountQuota] = [:]
    @Published public private(set) var lastErrorByAccount: [String: QuotaError] = [:]
    @Published public private(set) var lastUpdatedByAccount: [String: Date] = [:]
    @Published public private(set) var inFlightAccountIds: Set<String> = []

    private let adapters: [ToolType: any QuotaAdapter]
    private let mockProvider: () -> Bool

    public init(
        adapters: [ToolType: any QuotaAdapter],
        mockProvider: @escaping () -> Bool,
        initialAccountIds: [String] = []
    ) {
        self.adapters = adapters
        self.mockProvider = mockProvider
        let cached = QuotaCacheStore.loadAll(accountIds: initialAccountIds)
        self.lastSuccessByAccount = cached
        self.lastUpdatedByAccount = cached.mapValues(\.queriedAt)
    }

    public static func makeDefault(
        mockProvider: @escaping () -> Bool,
        initialAccountIds: [String] = []
    ) -> QuotaService {
        QuotaService(
            adapters: [
                .codex: CodexQuotaAdapter(),
                .claude: ClaudeQuotaAdapter(),
                .zai: ZaiQuotaAdapter()
            ],
            mockProvider: mockProvider,
            initialAccountIds: initialAccountIds
        )
    }

    /// Fetch quota for the given account. Stores the result (or error) and
    /// returns the new AccountQuota — which may be a cached previous success
    /// if the live call failed and we have prior data.
    @discardableResult
    public func refresh(_ account: AccountIdentity) async -> AccountQuota {
        if inFlightAccountIds.contains(account.id) {
            return lastSuccessByAccount[account.id]
                ?? AccountQuota(accountId: account.id, tool: account.tool, buckets: [], queriedAt: Date(), error: nil)
        }
        inFlightAccountIds.insert(account.id)
        defer { inFlightAccountIds.remove(account.id) }

        if mockProvider() {
            let quota = MockDataProvider.sampleQuota(for: account)
            store(success: quota)
            return quota
        }

        guard let adapter = adapters[account.tool] else {
            let err = QuotaError.notImplemented
            store(error: err, for: account)
            return cachedOrEmpty(for: account, error: err)
        }

        do {
            let quota = try await adapter.fetch(for: account)
            store(success: quota)
            return quota
        } catch let qe as QuotaError {
            SafeLog.net("\(account.tool.rawValue) refresh failed: \(qe.userFacingMessage)")
            store(error: qe, for: account)
            return cachedOrEmpty(for: account, error: qe)
        } catch {
            let qe = mapURLError(error)
            SafeLog.net("\(account.tool.rawValue) refresh exception: \(qe.userFacingMessage)")
            store(error: qe, for: account)
            return cachedOrEmpty(for: account, error: qe)
        }
    }

    public func cachedQuota(for accountId: String) -> AccountQuota? {
        lastSuccessByAccount[accountId]
    }

    public func clear(accountId: String) {
        lastSuccessByAccount.removeValue(forKey: accountId)
        lastErrorByAccount.removeValue(forKey: accountId)
        lastUpdatedByAccount.removeValue(forKey: accountId)
        try? QuotaCacheStore.delete(accountId: accountId)
    }

    public func replaceBucket(_ bucket: QuotaBucket, for accountId: String) {
        guard var quota = lastSuccessByAccount[accountId] else { return }
        quota.buckets.removeAll { $0.id == bucket.id }
        quota.buckets.append(bucket)
        quota.queriedAt = Date()
        store(success: quota)
    }

    // MARK: - Private

    private func store(success: AccountQuota) {
        lastSuccessByAccount[success.accountId] = success
        lastErrorByAccount.removeValue(forKey: success.accountId)
        lastUpdatedByAccount[success.accountId] = success.queriedAt
        do {
            try QuotaCacheStore.save(success)
        } catch {
            SafeLog.warn("Saving quota cache failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }

    private func store(error: QuotaError, for account: AccountIdentity) {
        lastErrorByAccount[account.id] = error
        lastUpdatedByAccount[account.id] = Date()
    }

    private func cachedOrEmpty(for account: AccountIdentity, error: QuotaError) -> AccountQuota {
        if var cached = lastSuccessByAccount[account.id] {
            cached.error = error
            return cached
        }
        return AccountQuota(
            accountId: account.id,
            tool: account.tool,
            buckets: [],
            plan: account.plan,
            email: account.email,
            queriedAt: Date(),
            error: error
        )
    }
}
