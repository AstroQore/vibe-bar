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

    init() {
        let cached = ServiceStatusCacheStore.loadAll()
        self.snapshotByTool = cached
    }

    func start() {
        refreshAll()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for tool in ToolType.allCases {
                    group.addTask { @MainActor [weak self] in
                        await self?.refresh(tool)
                    }
                }
            }
            self.lastFetched = Date()
            self.persist()
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
