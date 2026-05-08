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

    private func persist() {
        do {
            try ServiceStatusCacheStore.save(snapshotByTool)
        } catch {
            // best-effort cache; ignore failures
        }
    }
}
