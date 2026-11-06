import Combine
import Foundation
import VibeBarCore

/// The app's one connection to `~/.vibebar/session_index.sqlite3`.
///
/// Three components used to open their own: the Workbench's Sessions page,
/// `MCPController` (on the first `sessions.*` call), and
/// `SessionIndexCompactor`. Nothing coordinated them, so an MCP backfill and
/// a Workbench refresh could run two full 11 000-file passes over the same
/// 1 GB database at once, each waiting out the other's busy timeout. Two
/// connections to one WAL database are legal; two *indexers* are just twice
/// the work.
///
/// The compactor still keeps its own handle — it runs once a day, needs raw
/// SQLite, and is fenced by `SessionIndexMaintenanceGate` instead.
@MainActor
final class SharedSessionIndex {
    /// `nil` when the database would not open. Same shape as the usage
    /// ledger in `AppEnvironment`: that costs the Sessions page its index,
    /// not the app its launch.
    let store: SessionIndexStore?
    let service: SessionIndexService?
    let refreshes: SessionIndexRefreshCoordinator?
    /// Auto Review rows by parent, on a read-only connection of its own —
    /// shared by the Sessions page and the MCP session tools so the two read
    /// the same answer. See `SessionReviewIndex`.
    let reviews = SessionReviewIndex(databaseURL: VibeBarLocalStore.sessionIndexURL)
    /// The privacy switch, mirrored where the index actor can read it
    /// without a main-actor hop — and, unlike a captured `Bool`, re-read on
    /// every pass. Following the setting for the life of the app is what
    /// makes "Index message text" reach the MCP surface too.
    let bodyIndexing: BodyIndexingFlag

    private var cancellables: Set<AnyCancellable> = []

    init(
        settingsStore: SettingsStore,
        homeDirectory: String = RealHomeDirectory.path,
        startupPreparation: Task<SessionIndexReparse.Outcome?, Never>? = nil
    ) {
        let flag = BodyIndexingFlag(settingsStore.settings.sessionBodyIndexingEnabled)
        self.bodyIndexing = flag

        let opened: SessionIndexStore?
        do {
            opened = try SessionIndexStore(url: VibeBarLocalStore.sessionIndexURL)
        } catch {
            SafeLog.warn("Opening the session index failed: \(SafeLog.sanitize(error.localizedDescription))")
            opened = nil
        }
        self.store = opened
        let service = opened.map {
            SessionIndexService(
                homeDirectory: homeDirectory,
                store: $0,
                // The indexer gets the bounded adapters: oversized rollouts
                // are parsed from a head copy (memory) and excerpts are
                // pre-trimmed to the host policy (index size). The raw
                // registry stays with the transcript viewer and the deleter,
                // which must see whole sessions.
                registry: SessionIndexingBounds.boundedRegistry(
                    SessionProviderRegistry.standard(homeDirectory: homeDirectory),
                    scratchDirectory: VibeBarLocalStore
                        .sessionIndexScratchDirectoryURL(homeDirectory: homeDirectory)
                ),
                bodyIndexing: { flag.current }
            )
        }

        self.service = service
        if let opened, let service {
            let runner = PassRunner(store: opened, service: service)
            refreshes = SessionIndexRefreshCoordinator(
                hasCachedRows: {
                    let page = try? await SessionVisibleRows.page(service, limit: 1)
                    return page.map { $0.totalCount > 0 } ?? true
                },
                prepare: { _ = await startupPreparation?.value }
            ) { pass, progress in
                await runner.run(pass, progress: progress)
            }
        } else {
            refreshes = nil
        }

        settingsStore.$settings
            .map(\.sessionBodyIndexingEnabled)
            .removeDuplicates()
            .sink { enabled in flag.set(enabled) }
            .store(in: &cancellables)
    }

    private actor PassRunner {
        private static let preloadBudget = SessionIndexRefreshBudget(
            maxFiles: 32, maxBytes: 16 * 1024 * 1024, maxFileBytes: 9 * 1024 * 1024,
            maxChecked: 512, maxDuration: .milliseconds(250)
        )

        private let store: SessionIndexStore
        private let service: SessionIndexService
        private var recentQueue: (candidates: [SessionIndexCandidate], offset: Int)?

        init(store: SessionIndexStore, service: SessionIndexService) {
            self.store = store
            self.service = service
        }

        func run(
            _ pass: SessionIndexRefreshCoordinator.Pass,
            progress: SessionIndexRefreshCoordinator.ProgressUpdate?
        ) async -> SessionIndexRefreshCoordinator.Report? {
            let result: SessionIndexRefreshResult
            switch pass {
            case .recent:
                guard let recent = await recentCandidates() else { return nil }
                result = await service.refreshIndexCandidates(
                    recent.candidates, budget: Self.preloadBudget, offset: recent.offset
                )
                recentQueue = result.hasMore ? (recent.candidates, result.nextCandidateOffset) : nil
            case .discovery:
                recentQueue = nil
                result = await service.refreshIndexBatch(budget: Self.preloadBudget)
            case .full, .rebuild:
                recentQueue = nil
                if pass == .rebuild {
                    do { try await store.eraseAll() }
                    catch { return nil }
                }
                result = await service.refreshIndexFully(progress: progress)
            }
            let succeeded = !result.failed && !result.cancelled && !result.busy
            return SessionIndexRefreshCoordinator.Report(
                changed: pass == .rebuild || result.written > 0 || result.pruned > 0 || result.modeChanged,
                completedDiscovery: result.completedDiscovery,
                hasMore: result.hasMore && succeeded,
                succeeded: succeeded
            )
        }

        private func recentCandidates() async -> (candidates: [SessionIndexCandidate], offset: Int)? {
            if let recentQueue { return recentQueue }
            // Include review rows, which can still grow after discovery.
            guard let page = try? await store.summaryPage(limit: 128) else { return nil }
            return (page.summaries.map {
                SessionIndexCandidate(provider: $0.provider, url: URL(fileURLWithPath: $0.sourcePath))
            }, 0)
        }
    }
}
