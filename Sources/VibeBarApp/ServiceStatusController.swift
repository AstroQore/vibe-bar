import Foundation
import Combine
import VibeBarCore

@MainActor
final class ServiceStatusController: ObservableObject {
    @Published private(set) var snapshotByTool: [ToolType: ServiceStatusSnapshot] = [:]
    @Published private(set) var inFlight: Set<ToolType> = []
    @Published private(set) var errorByTool: [ToolType: String] = [:]
    @Published private(set) var lastFetched: Date?

    private let client = ServiceStatusClient()
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    /// Coalesce window: skip refreshAll bursts that arrive within this
    /// interval of a previous start. Login flows / cookie reloads can fire
    /// reloadProviderCredentialsAndRefresh() back-to-back, and each call
    /// hits two HTML pages + four JSON endpoints + several regex passes.
    private static let coalesceInterval: TimeInterval = 2
    private var lastRefreshStartedAt: Date?

    init() {
        let cached = ServiceStatusCacheStore.loadAll()
        self.snapshotByTool = cached
    }

    func start() {
        refreshAll()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshAll() {
        // Demo mode shows the cached status pages and never polls.
        guard !DemoMode.isEnabled else { return }
        if let last = lastRefreshStartedAt,
           Date().timeIntervalSince(last) < Self.coalesceInterval,
           refreshTask != nil {
            return
        }
        refreshTask?.cancel()
        lastRefreshStartedAt = Date()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                // Misc providers don't expose Atlassian-style status
                // feeds — `tool.supportsStatusPage` is false for all
                // of them, and the underlying `ServiceStatusClient.fetch`
                // returns an empty placeholder rather than hitting a
                // URL. Skip them up-front to avoid wasted task creation.
                for tool in ToolType.allCases where tool.supportsStatusPage {
                    group.addTask { @MainActor [weak self] in
                        await self?.refresh(tool)
                    }
                }
            }
            self.lastFetched = Date()
            self.persist()
            self.refreshTask = nil
        }
    }

    func refresh(_ tool: ToolType) async {
        if inFlight.contains(tool) { return }
        inFlight.insert(tool)
        defer { inFlight.remove(tool) }
        do {
            let snapshot = try await client.fetch(tool: tool)
            snapshotByTool[tool] = snapshot
            errorByTool.removeValue(forKey: tool)
        } catch {
            errorByTool[tool] = error.localizedDescription
        }
    }

    /// Encode + write off the main actor.
    ///
    /// The cache is a few hundred KB of JSON; encoding and writing it inline
    /// held the main thread on every refresh (and on every login / cookie
    /// reload that funnels through `refreshAll`) for no benefit — nothing
    /// waits on the result. The snapshot is captured here so the detached
    /// task writes the value as of this moment, not whatever the actor's
    /// state has become by the time it runs.
    private func persist() {
        let snapshot = snapshotByTool
        Task.detached(priority: .utility) {
            do {
                try ServiceStatusCacheStore.save(snapshot)
            } catch {
                // best-effort cache; ignore failures
            }
        }
    }
}

// MARK: - Row projection

extension ServiceStatusController {
    /// Everything one service-status row needs, derived once.
    struct Projection {
        let snapshot: ServiceStatusSnapshot?
        let isRefreshing: Bool
        /// Non-nil only when *no* member produced a snapshot. A row backed
        /// by the healthy half of a pair reports that snapshot, not the
        /// failure of its sibling feed.
        let error: String?
    }

    /// The feeds that roll up into one row. Status rows render at the L1
    /// company level, so Google AI covers Gemini + AntiGravity and SpaceXAI
    /// covers Grok + Cursor; every other provider is its own row.
    static func statusMembers(of tool: ToolType) -> [ToolType] {
        switch tool {
        case .gemini: ToolType.googleAIPair
        case .grok: ToolType.grokFamily
        default: [tool]
        }
    }

    func projection(for tool: ToolType) -> Projection {
        let snapshot: ServiceStatusSnapshot? = switch tool {
        case .gemini:
            ServiceStatusSnapshot.preferredGoogleAI(
                gemini: snapshotByTool[.gemini],
                antigravity: snapshotByTool[.antigravity]
            )
        case .grok:
            ServiceStatusSnapshot.mergedSpaceXAI(
                grok: snapshotByTool[.grok],
                cursor: snapshotByTool[.cursor]
            )
        default:
            snapshotByTool[tool]
        }
        let members = Self.statusMembers(of: tool)
        return Projection(
            snapshot: snapshot,
            isRefreshing: members.contains(where: inFlight.contains),
            error: snapshot == nil ? members.compactMap { errorByTool[$0] }.first : nil
        )
    }
}
