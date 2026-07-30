import Foundation

/// Serializes and coalesces quota-cache writes off the main actor.
///
/// `QuotaCacheStore.save` pretty-prints a whole account's quota, writes it
/// atomically and then sets file permissions — tens of milliseconds of
/// synchronous filesystem work. `QuotaService` used to pay that on the main
/// actor once per successful account refresh, so the refresh a popover-open
/// triggers stalled rendering once per provider.
///
/// Coalescing follows `UsageFillTimelineStore`: the newest quota for an account
/// always wins, and at most one write per account lands per throttle window.
/// Dropping the last few seconds of writes on a hard kill is acceptable here —
/// the file is a warm-start cache whose only job is to show the last known
/// numbers before the first live refresh of the next launch completes.
public actor QuotaCacheWriter {
    public static let shared = QuotaCacheWriter()

    private let throttleInterval: TimeInterval
    private let write: @Sendable (AccountQuota) throws -> Void
    private let remove: @Sendable (String) throws -> Void

    private var lastWrittenAt: [String: Date] = [:]
    private var pending: [String: AccountQuota] = [:]
    private var flushTask: Task<Void, Never>?

    public init(
        throttleInterval: TimeInterval = 15,
        write: @escaping @Sendable (AccountQuota) throws -> Void = { try QuotaCacheStore.save($0) },
        remove: @escaping @Sendable (String) throws -> Void = { try QuotaCacheStore.delete(accountId: $0) }
    ) {
        self.throttleInterval = throttleInterval
        self.write = write
        self.remove = remove
    }

    public func save(_ quota: AccountQuota, now: Date = Date()) {
        if let last = lastWrittenAt[quota.accountId],
           now.timeIntervalSince(last) < throttleInterval {
            pending[quota.accountId] = quota
            scheduleFlush(after: throttleInterval - now.timeIntervalSince(last))
            return
        }
        persist(quota, now: now)
    }

    /// Forget an account and delete its file. Routed through the writer rather
    /// than called directly so a throttled write still in flight cannot
    /// resurrect the cache of an account the user just signed out of.
    public func delete(accountId: String) {
        pending.removeValue(forKey: accountId)
        lastWrittenAt.removeValue(forKey: accountId)
        do {
            try remove(accountId)
        } catch {
            SafeLog.warn("Deleting quota cache failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }

    public func flushPendingWrites() {
        let queued = pending
        pending = [:]
        flushTask?.cancel()
        flushTask = nil
        let now = Date()
        for quota in queued.values {
            persist(quota, now: now)
        }
    }

    // MARK: - Private

    private func persist(_ quota: AccountQuota, now: Date) {
        do {
            try write(quota)
        } catch {
            SafeLog.warn("Saving quota cache failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
        lastWrittenAt[quota.accountId] = now
        pending.removeValue(forKey: quota.accountId)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        if flushTask != nil { return }
        let nanoseconds = UInt64(max(0.05, delay) * 1_000_000_000)
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.flushPendingWrites()
        }
    }
}
