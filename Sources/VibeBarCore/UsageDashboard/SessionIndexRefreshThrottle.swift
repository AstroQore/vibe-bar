import Foundation

/// When the Usage page re-scans the session index: on activation and while
/// it stays open, at most once per `minimumInterval`, one sweep at a time,
/// behind `SessionIndexMaintenanceGate` — the Sessions page's rule
/// (`SessionManagerModel.rescanMinimumInterval`, ten minutes), so a session
/// a CLI started after the last scan reaches the dashboard without the user
/// visiting Sessions first, and moving between pages never costs a sweep.
public actor SessionIndexRefreshThrottle {
    /// The app's instance, shared by every Usage page activation.
    public static let shared = SessionIndexRefreshThrottle()

    /// The Sessions page's floor between two activation sweeps.
    public static let defaultMinimumInterval: TimeInterval = 10 * 60

    public let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastFinishedAt: Date?
    private var isRefreshing = false

    public init(
        minimumInterval: TimeInterval = SessionIndexRefreshThrottle.defaultMinimumInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// Whether a sweep would run now.
    public var isDue: Bool {
        guard !isRefreshing else { return false }
        guard let lastFinishedAt else { return true }
        return now().timeIntervalSince(lastFinishedAt) >= minimumInterval
    }

    /// Run `refresh` under `gate` when one is due. Returns whether it ran.
    ///
    /// The wait for the gate is cancellable and claims nothing when it
    /// throws (the gate's own contract), so a page that closes while a
    /// compaction holds the index walks away without stranding it.
    public func refreshIfDue(
        gate: SessionIndexMaintenanceGate = .shared,
        _ refresh: @Sendable () async -> Void
    ) async -> Bool {
        guard isDue else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await gate.acquire()
        } catch {
            return false
        }
        guard !Task.isCancelled else {
            await gate.release()
            return false
        }
        await refresh()
        await gate.release()
        lastFinishedAt = now()
        return true
    }
}
