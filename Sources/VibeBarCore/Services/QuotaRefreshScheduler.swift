import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif
import Network

/// Drives periodic refresh for all visible provider identities.
/// Triggers:
///   - timer firing every settings.refreshIntervalSeconds (default 600)
///   - system wake from sleep
///   - network coming back from unsatisfied → satisfied
///   - manual `triggerRefresh()` call
@MainActor
public final class QuotaRefreshScheduler {
    private let service: QuotaService
    private let accountsProvider: () -> [AccountIdentity]
    private let intervalProvider: () -> Int
    private let onRefreshTriggered: @MainActor () -> Void
    private var timer: Timer?
    private var boundaryTimer: Timer?
    private var boundaryAccountIds: Set<String> = []
    private var lastBoundaryRefreshByAccount: [String: Date] = [:]
    private var lastPopoverOpenRefreshAt: Date?
    /// Accounts waiting their turn, in arrival order. One drain loop walks
    /// this list, so every trigger — timer, wake, network, popover, boundary
    /// — just extends the same queue instead of racing a second walk.
    /// `refreshTask` is that loop: non-nil means draining.
    private var queue: [QueuedRefresh] = []
    private var refreshTask: Task<Void, Never>?
    /// A boundary observation is queued, so the boundary timer has to be
    /// recomputed once the queue empties.
    private var needsBoundaryReschedule = false
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkStatus: NWPath.Status = .satisfied
    private var observers: [NSObjectProtocol] = []
    private var quotaObservation: AnyCancellable?

    private struct QueuedRefresh {
        let account: AccountIdentity
        /// A boundary observation stamps `lastBoundaryRefreshByAccount` when
        /// it is *dequeued*, so a long queue cannot claim the reset was
        /// observed before the request actually ran.
        var isBoundaryObservation: Bool
    }

    public init(
        service: QuotaService,
        accountsProvider: @escaping () -> [AccountIdentity],
        intervalProvider: @escaping () -> Int,
        onRefreshTriggered: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.accountsProvider = accountsProvider
        self.intervalProvider = intervalProvider
        self.onRefreshTriggered = onRefreshTriggered
        self.quotaObservation = service.$lastSuccessByAccount
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleBoundaryTimer()
                }
            }
    }

    public func start() {
        scheduleTimer()
        scheduleBoundaryTimer()
        installSystemObservers()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        boundaryAccountIds = []
        refreshTask?.cancel()
        refreshTask = nil
        queue = []
        needsBoundaryReschedule = false
        pathMonitor?.cancel()
        pathMonitor = nil
        #if canImport(AppKit)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif
        observers.removeAll()
    }

    /// Re-create the timer with the latest interval. Call when settings change.
    public func reschedule() {
        scheduleTimer()
    }

    public func triggerRefresh() {
        onRefreshTriggered()
        let accounts = accountsProvider()
        guard !accounts.isEmpty else { return }
        _ = startAccountRefresh(accounts)
    }

    /// Refresh when the user explicitly opens the menu popover, subject to a
    /// user-configured cooldown. Popover construction/warm-up does not call
    /// this method; only an actual open gesture does, so launch-time eager
    /// SwiftUI creation cannot accidentally consume the cooldown.
    @discardableResult
    public func triggerRefreshForPopoverOpenIfNeeded(
        enabled: Bool,
        cooldownSeconds: Int,
        now: Date = Date()
    ) -> Bool {
        guard enabled else { return false }
        let cooldown = TimeInterval(max(60, cooldownSeconds))
        if let lastPopoverOpenRefreshAt,
           now.timeIntervalSince(lastPopoverOpenRefreshAt) < cooldown {
            return false
        }
        lastPopoverOpenRefreshAt = now
        triggerRefresh()
        return true
    }

    /// Even when the user disables unconditional popover-open refresh, an
    /// actually missing/stale/expired cache must not remain silently visible.
    /// This path refreshes only the affected accounts and does not trigger a
    /// full cost scan.
    @discardableResult
    public func triggerRefreshForStaleCacheIfNeeded(now: Date = Date()) -> Bool {
        let maxAge = TimeInterval(max(60, intervalProvider()))
        let accounts = accountsProvider().filter { account in
            !isQueued(account.id)
                && !service.inFlightAccountIds.contains(account.id)
                && service.needsRefresh(accountId: account.id, now: now, maxAge: maxAge)
        }
        guard !accounts.isEmpty else { return false }
        return startAccountRefresh(accounts)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(60, intervalProvider()))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.triggerRefresh()
            }
        }
        // Quota refreshes don't need to fire on the exact second — letting
        // macOS coalesce them with other timers (10% slack, capped at 30s)
        // saves measurable battery on laptops.
        timer.tolerance = min(30, interval * 0.1)
        self.timer = timer
    }

    /// When Vibe Bar is running, take one observation shortly before and one
    /// shortly after the nearest provider-reported reset. Refill-drop
    /// detection remains authoritative for early/late resets; these two
    /// bounded reads simply tighten the "last seen before reset" gap without
    /// turning the normal scheduler into aggressive polling.
    private func scheduleBoundaryTimer(now: Date = Date()) {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        boundaryAccountIds = []

        let accounts = accountsProvider()
        var candidates: [(date: Date, accountId: String)] = []
        for account in accounts {
            guard let quota = service.cachedQuota(for: account.id) else { continue }
            for resetAt in quota.buckets.compactMap(\.resetAt) {
                for offset in [-120.0, 120.0] {
                    let candidate = resetAt.addingTimeInterval(offset)
                    guard candidate.timeIntervalSince(now) >= 5,
                          candidate.timeIntervalSince(now) <= 45 * 86_400
                    else { continue }
                    if let last = lastBoundaryRefreshByAccount[account.id],
                       candidate.timeIntervalSince(last) < 90 {
                        continue
                    }
                    candidates.append((candidate, account.id))
                }
            }
        }
        guard let nextDate = candidates.map(\.date).min() else { return }
        boundaryAccountIds = Set(
            candidates
                .filter { abs($0.date.timeIntervalSince(nextDate)) <= 5 }
                .map(\.accountId)
        )
        let delay = max(5, nextDate.timeIntervalSince(now))
        let boundaryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.triggerBoundaryRefresh()
            }
        }
        boundaryTimer.tolerance = min(5, delay * 0.02)
        self.boundaryTimer = boundaryTimer
    }

    private func triggerBoundaryRefresh() {
        let ids = boundaryAccountIds
        boundaryAccountIds = []
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        triggerBoundaryRefresh(accountIds: ids)
    }

    /// Kept internal so the scheduler's coalescing behavior can be exercised
    /// deterministically without installing a wall-clock Timer in tests.
    func triggerBoundaryRefresh(accountIds ids: Set<String>) {
        let accounts = accountsProvider().filter { ids.contains($0.id) }
        guard !accounts.isEmpty else {
            scheduleBoundaryTimer()
            return
        }
        needsBoundaryReschedule = true
        startAccountRefresh(accounts, isBoundaryObservation: true)
    }

    private func isQueued(_ accountId: String) -> Bool {
        queue.contains { $0.account.id == accountId }
    }

    /// Append the accounts that aren't already waiting and make sure the
    /// drain loop is running. An account currently being refreshed is not in
    /// the queue, so a trigger that arrives mid-walk can re-queue it —
    /// `QuotaService` no-ops a genuinely re-entrant refresh on its own.
    @discardableResult
    private func startAccountRefresh(
        _ accounts: [AccountIdentity],
        isBoundaryObservation: Bool = false
    ) -> Bool {
        guard !accounts.isEmpty else { return false }
        for account in accounts {
            if let index = queue.firstIndex(where: { $0.account.id == account.id }) {
                if isBoundaryObservation { queue[index].isBoundaryObservation = true }
            } else {
                queue.append(
                    QueuedRefresh(account: account, isBoundaryObservation: isBoundaryObservation)
                )
            }
        }
        drain()
        return true
    }

    private func drain() {
        guard refreshTask == nil, !queue.isEmpty else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.queue.isEmpty else { break }
                let queued = self.queue.removeFirst()
                if queued.isBoundaryObservation {
                    self.lastBoundaryRefreshByAccount[queued.account.id] = Date()
                }
                _ = await self.service.refresh(queued.account)
            }
            guard let self else { return }
            self.refreshTask = nil
            if self.needsBoundaryReschedule {
                self.needsBoundaryReschedule = false
                self.scheduleBoundaryTimer()
            }
        }
    }

    private func installSystemObservers() {
        #if canImport(AppKit)
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.triggerRefresh() }
        }
        observers.append(wake)
        #endif

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let was = self.lastNetworkStatus
                self.lastNetworkStatus = path.status
                if was != .satisfied && path.status == .satisfied {
                    self.triggerRefresh()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "VibeBar.network"))
        self.pathMonitor = monitor
    }

    deinit {
        timer?.invalidate()
        boundaryTimer?.invalidate()
        refreshTask?.cancel()
        pathMonitor?.cancel()
        #if canImport(AppKit)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif
    }
}
