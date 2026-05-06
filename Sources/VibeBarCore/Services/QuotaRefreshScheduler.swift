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
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkStatus: NWPath.Status = .satisfied
    private var observers: [NSObjectProtocol] = []

    public init(
        service: QuotaService,
        accountsProvider: @escaping () -> [AccountIdentity],
        intervalProvider: @escaping () -> Int
    ) {
        self.service = service
        self.accountsProvider = accountsProvider
        self.intervalProvider = intervalProvider
    }

    public func start() {
        scheduleTimer()
        installSystemObservers()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
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
        pathMonitor?.cancel()
        #if canImport(AppKit)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif
    }
}
