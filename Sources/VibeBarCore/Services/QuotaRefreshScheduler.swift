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
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkStatus: NWPath.Status = .satisfied
    private var observers: [NSObjectProtocol] = []
    private var quotaObservation: AnyCancellable?

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
        Task { @MainActor in
            for account in accounts {
                _ = await service.refresh(account)
            }
        }
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
        let accounts = accountsProvider().filter { ids.contains($0.id) }
        guard !accounts.isEmpty else {
            scheduleBoundaryTimer()
            return
        }
        Task { @MainActor in
            for account in accounts {
                lastBoundaryRefreshByAccount[account.id] = Date()
                _ = await service.refresh(account)
            }
            scheduleBoundaryTimer()
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
        pathMonitor?.cancel()
        #if canImport(AppKit)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif
    }
}
