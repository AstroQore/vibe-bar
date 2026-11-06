import Combine
import Foundation

/// Owns refreshes for one index. A page observes the state while visible;
/// leaving the page cannot cancel the job, reset its freshness, or start a
/// second walk. The maintenance gate also excludes the compactor.
@MainActor
public final class SessionIndexRefreshCoordinator {
    public struct Progress: Equatable, Sendable {
        public let done: Int
        public let total: Int

        public var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(done) / Double(total))
        }
    }

    public struct State: Equatable, Sendable {
        public fileprivate(set) var generation: UInt64 = 0
        public fileprivate(set) var progress: Progress?
        public fileprivate(set) var isDiscovering = false
    }

    public enum Consumer: Hashable {
        case sessions, usage
    }

    public enum Pass: Equatable, Sendable {
        case recent, discovery, full, rebuild
    }

    public struct Report: Sendable {
        public let changed: Bool
        public let completedDiscovery: Bool
        public let hasMore: Bool
        public let succeeded: Bool

        public init(
            changed: Bool,
            completedDiscovery: Bool = false,
            hasMore: Bool = false,
            succeeded: Bool = true
        ) {
            self.changed = changed
            self.completedDiscovery = completedDiscovery
            self.hasMore = hasMore
            self.succeeded = succeeded
        }
    }

    private enum Schedule {
        static let initialDelay = Duration.seconds(2)
        static let interval = Duration.seconds(120)
        static let discoveryInterval = Duration.seconds(600)
        static let continuationDelay = Duration.seconds(1)
    }

    public typealias ProgressUpdate = @Sendable (Int, Int) -> Void
    public typealias Run = @Sendable (Pass, ProgressUpdate?) async -> Report?
    private typealias Operation = @MainActor (ProgressUpdate?) async -> Report?

    private enum Kind: Equatable {
        case background(Pass), coldDiscovery, backfill, full, rebuild, mutation

        var usesBoundedBatch: Bool {
            switch self {
            case .background, .coldDiscovery: true
            default: false
            }
        }

        var showsProgress: Bool { self == .full || self == .rebuild || self == .backfill }
    }

    private struct Job {
        let id: UUID
        let kind: Kind
        let task: Task<Bool, Never>
    }

    @Published public private(set) var state = State()
    private(set) var lastDiscoveryFinishedAt: SuspendingClock.Instant?

    private let gate: SessionIndexMaintenanceGate
    private let backgroundAllowed: @Sendable () -> Bool
    private let hasCachedRows: @Sendable () async -> Bool
    private let prepare: @Sendable () async -> Void
    private let run: Run
    private var jobs: [UUID: Task<Bool, Never>] = [:]
    private var latest: Job?
    private var progressOwner: UUID?
    private var didCompleteFullRefresh = false
    private var attemptedBackfill = false
    private var preloader: Task<Void, Never>?
    private var visibleConsumers: Set<Consumer> = []
    private var observedCachedRows = false
    private var pendingPass: Pass?
    private var stopped = false

    public init(
        gate: SessionIndexMaintenanceGate = .shared,
        backgroundAllowed: @escaping @Sendable () -> Bool = {
            let process = ProcessInfo.processInfo
            return !process.isLowPowerModeEnabled
                && process.thermalState != .serious
                && process.thermalState != .critical
        },
        hasCachedRows: @escaping @Sendable () async -> Bool = { false },
        prepare: @escaping @Sendable () async -> Void = {},
        run: @escaping Run
    ) {
        self.gate = gate
        self.backgroundAllowed = backgroundAllowed
        self.hasCachedRows = hasCachedRows
        self.prepare = prepare
        self.run = run
    }

    /// Opt in on first use of an index-backed page in this process.
    /// A visible page can ask for its first rows even when periodic work is
    /// suspended to conserve power.
    public func setVisible(_ consumer: Consumer, _ visible: Bool) {
        guard visible else {
            visibleConsumers.remove(consumer)
            return
        }
        guard visibleConsumers.insert(consumer).inserted else { return }
        let needsColdCheck = !backgroundAllowed() && !observedCachedRows
            && lastDiscoveryFinishedAt == nil && latest == nil
        if needsColdCheck {
            preloader?.cancel()
            preloader = nil
        }
        startPreloading(initialDelay: needsColdCheck ? .zero : Schedule.initialDelay)
    }

    private func startPreloading(initialDelay: Duration) {
        guard preloader == nil, !stopped else { return }
        preloader = Task(priority: .utility) { [weak self] in
            var delay = initialDelay
            let clock = SuspendingClock()
            while !Task.isCancelled {
                do { try await clock.sleep(for: delay, tolerance: delay / 10) }
                catch { break }
                let hasMore = await self?.preloadOnce() ?? false
                delay = hasMore ? Schedule.continuationDelay : Schedule.interval
            }
        }
    }

    /// Explicit Refresh ignores freshness. A repeated click joins the
    /// outstanding job, and a click during preloading waits for one slice.
    @discardableResult
    public func requestRefresh(rebuild: Bool = false) -> Task<Bool, Never>? {
        if let latest, latest.kind == .rebuild || (latest.kind == .full && !rebuild) {
            return latest.task
        }
        let pass: Pass = rebuild ? .rebuild : .full
        let run = self.run
        let joiningBackfill = !rebuild && latest?.kind == .backfill
        let previousDiscovery = lastDiscoveryFinishedAt
        return enqueue(rebuild ? .rebuild : .full) { [weak self] progress in
            if joiningBackfill, self?.lastDiscoveryFinishedAt != previousDiscovery {
                return Report(changed: false)
            }
            return await run(pass, progress)
        }
    }

    /// Called once the launch-time parser repair has dropped stale cursors.
    /// An overlapping refresh may already have re-read them.
    public func refreshAfterPreparation() async {
        guard !didCompleteFullRefresh else { return }
        _ = await requestRefresh()?.value
    }

    /// Only the cold MCP path asks for this. Recheck under the gate after
    /// an in-flight slice: it may already have produced rows for the caller.
    public func backfillIfNeeded(hasRows: @escaping @Sendable () async -> Bool) async -> Bool {
        if let latest, latest.kind.showsProgress {
            return await latest.task.value
        }
        guard !attemptedBackfill, lastDiscoveryFinishedAt == nil else { return false }
        let run = self.run
        let task = enqueue(.backfill) { [weak self] progress in
            if await hasRows() { return Report(changed: false) }
            self?.attemptedBackfill = true
            return await run(.full, progress)
        }
        return await task?.value ?? false
    }

    /// Serialize small index writes with both scheduled and manual refresh.
    @discardableResult
    public func mutate(_ write: @escaping @Sendable () async -> Bool) async -> Bool {
        let task = enqueue(.mutation) { _ in
            let changed = await write()
            return Report(changed: changed, succeeded: changed)
        }
        return await task?.value ?? false
    }

    public func stop() {
        stopped = true
        preloader?.cancel()
        preloader = nil
        for task in jobs.values { task.cancel() }
    }

    /// One wake, at most one bounded batch. A continuation only keeps the
    /// short delay when it actually ran, so a busy or hot machine backs off.
    @discardableResult
    func preloadOnce() async -> Bool {
        guard latest == nil else { return false }
        guard backgroundAllowed() else { return await preloadVisibleColdIndex() }
        let clock = SuspendingClock()
        let discoveryDue = lastDiscoveryFinishedAt.map {
            $0.duration(to: clock.now) >= Schedule.discoveryInterval
        } ?? true
        let pass = pendingPass ?? (discoveryDue ? .discovery : .recent)
        let run = self.run
        guard let task = enqueue(.background(pass), operation: { _ in await run(pass, nil) }) else { return false }
        let ran = await task.value
        return ran && pendingPass != nil
    }

    private func preloadVisibleColdIndex() async -> Bool {
        guard !visibleConsumers.isEmpty, !observedCachedRows, lastDiscoveryFinishedAt == nil else {
            updateState { $0.isDiscovering = false }
            return false
        }
        let run = self.run
        let task = enqueue(.coldDiscovery) { [weak self] _ in
            guard let self, !self.visibleConsumers.isEmpty else { return nil }
            if await self.hasCachedRows() {
                self.observedCachedRows = true
                return nil
            }
            guard !self.visibleConsumers.isEmpty else { return nil }
            self.updateState { $0.isDiscovering = true }
            return await run(.discovery, nil)
        }
        return await task?.value == true && pendingPass != nil
    }

    private func enqueue(_ kind: Kind, operation: @escaping Operation) -> Task<Bool, Never>? {
        guard !stopped else { return nil }
        let predecessor = latest?.task
        let id = UUID()
        let task = Task(priority: kind.usesBoundedBatch ? .utility : .userInitiated) { [weak self] in
            _ = await predecessor?.value
            guard let self else { return false }
            defer {
                self.jobs[id] = nil
                if self.latest?.id == id {
                    self.latest = nil
                    self.updateState { $0.progress = nil }
                }
            }
            guard !Task.isCancelled else { return false }
            await self.prepare()
            return await self.perform(kind, id: id, operation: operation)
        }
        jobs[id] = task
        latest = Job(id: id, kind: kind, task: task)
        if kind.showsProgress, state.progress == nil {
            updateState { $0.progress = Progress(done: 0, total: 0) }
        }
        return task
    }

    private func perform(_ kind: Kind, id: UUID, operation: Operation) async -> Bool {
        if kind.usesBoundedBatch {
            guard kind == .coldDiscovery || backgroundAllowed(), await gate.tryAcquire() else {
                updateState { $0.isDiscovering = false }
                return false
            }
        } else {
            do { try await gate.acquire() } catch { return false }
        }
        guard !Task.isCancelled else {
            await gate.release()
            return false
        }

        if kind == .background(.discovery) { updateState { $0.isDiscovering = true } }
        var progress: ProgressUpdate?
        if kind.showsProgress {
            progressOwner = id
            updateState { $0.progress = Progress(done: 0, total: 0) }
            progress = { [weak self] done, total in
                guard done == total || done % 250 == 0 else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.progressOwner == id,
                          (self.state.progress?.done ?? 0) <= done else { return }
                    self.updateState { $0.progress = Progress(done: done, total: total) }
                }
            }
        }
        let report = await operation(progress)
        await gate.release()

        progressOwner = nil
        if let report {
            if report.completedDiscovery {
                lastDiscoveryFinishedAt = SuspendingClock().now
                if kind.showsProgress { didCompleteFullRefresh = true }
            }
            switch kind {
            case .background(let pass): pendingPass = report.hasMore ? pass : nil
            case .coldDiscovery: pendingPass = report.hasMore ? .discovery : nil
            case .full, .rebuild: pendingPass = nil
            case .backfill: if report.completedDiscovery { pendingPass = nil }
            case .mutation: break
            }
        }
        updateState { next in
            let queuedRefresh = latest?.id != id && latest?.kind.showsProgress == true
            next.progress = queuedRefresh ? Progress(done: 0, total: 0) : nil
            next.isDiscovering = pendingPass == .discovery && report != nil
            if report?.changed == true { next.generation &+= 1 }
        }
        return report?.succeeded == true
    }

    private func updateState(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        if next != state { state = next }
    }
}
