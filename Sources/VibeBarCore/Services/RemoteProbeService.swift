import Foundation
import Combine

@MainActor
public final class RemoteProbeService: ObservableObject {
    @Published public private(set) var machines: [RemoteMachineSummary] = []
    @Published public private(set) var isConfigured = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var lastErrorCode: String?

    private var config: RemoteCoreConfig?
    private var identity: RemoteCoreIdentity?
    private var client: RemoteRelayClient?
    private var ledger: RemoteUsageLedger?
    private var refreshLoop: Task<Void, Never>?
    /// The one sync currently executing, whether the loop, the settings
    /// pane's Sync now, or AppEnvironment started it. refresh() serializes
    /// on this so syncs never overlap, and reconfigure() drains it so no
    /// refresh from the old configuration is still running when the new one
    /// loads.
    private var activeRefresh: Task<Void, Never>?
    /// Bumped by every (re)load. An in-flight refresh() captured the previous
    /// configuration; it must stop publishing (and acknowledging) the moment
    /// this no longer matches the generation it started under.
    private var configurationGeneration = 0

    /// Workspace this Core is bound to, for status display. Never a secret.
    public var workspaceID: UUID? { config?.workspaceID }
    public var coreDeviceID: UUID? { config?.coreDeviceID }
    public var relayURL: URL? { config?.relayURL }
    public var registeredProbeCount: Int { config?.probeSigningPublicKeys.count ?? 0 }

    public init() {
        loadConfiguration()
    }

    private func loadConfiguration() {
        configurationGeneration += 1
        do {
            let config = try RemoteCoreConfigStore.load()
            let identity = try RemoteCoreIdentityStore.loadOrCreate()
            let bearer = try RemoteCoreIdentityStore.relayBearerToken(
                workspaceID: config.workspaceID
            )
            let ledger = try RemoteUsageLedger()
            self.config = config
            self.identity = identity
            self.client = RemoteRelayClient(config: config, bearerToken: bearer)
            self.ledger = ledger
            self.isConfigured = true
            self.lastErrorCode = nil
        } catch {
            self.config = nil
            self.identity = nil
            self.client = nil
            self.ledger = nil
            self.isConfigured = false
            self.machines = []
            self.lastUpdated = nil
            self.lastErrorCode = (error as? RemoteSyncError)?.code
        }
    }

    /// Re-read provisioning from disk after the settings pane installs or
    /// removes it, so a restart is never required. Cancels and awaits the old
    /// refresh loop before reloading, so a sync captured under the previous
    /// configuration can never interleave with the new one; stray refreshes
    /// started outside the loop are fenced by `configurationGeneration`.
    public func reconfigure() {
        let oldLoop = refreshLoop
        refreshLoop?.cancel()
        refreshLoop = nil
        Task { [weak self] in
            await oldLoop?.value
            // Also drain refreshes launched outside the loop (Sync now,
            // AppEnvironment.refreshAll) so the restarted loop's first pass
            // runs immediately instead of skipping and sleeping 60s.
            while let active = self?.activeRefresh {
                await active.value
            }
            guard let self else { return }
            self.loadConfiguration()
            if self.isConfigured {
                self.start()
            }
        }
    }

    public func start() {
        guard refreshLoop == nil, isConfigured else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    public func refresh() async {
        // Serialize: wait out any in-flight sync, then run a full pass of our
        // own. Piled-up callers each get a pass; the cursor-based protocol
        // makes back-to-back passes cheap no-ops.
        while let existing = activeRefresh {
            await existing.value
        }
        let task = Task { await performRefresh() }
        activeRefresh = task
        await task.value
        activeRefresh = nil
    }

    private func performRefresh() async {
        guard !isRefreshing,
              let config, let identity, let client, let ledger
        else { return }
        let generation = configurationGeneration
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var cursor = try await ledger.relayCursor(workspaceID: config.workspaceID)
            var pageCount = 0
            while pageCount < 100 {
                pageCount += 1
                let page = try await client.fetch(after: cursor)
                guard generation == configurationGeneration else { return }
                guard !page.batches.isEmpty else { break }
                for batch in page.batches {
                    let opened = try RemoteProtocolCrypto.openIngestEnvelope(
                        batch.envelope,
                        config: config,
                        identity: identity,
                        acceptedAt: batch.receivedAt
                    )
                    let payload = try RemotePayloadDecoder.decode(opened.plaintext)
                    guard payload.workspaceID == config.workspaceID,
                          payload.producerID == opened.producerID
                    else { throw RemoteSyncError.invalidPayload }
                    _ = try await ledger.importBatch(
                        payload,
                        sequence: opened.sequence,
                        receivedAt: batch.receivedAt
                    )
                    try await client.acknowledge(cursor: batch.cursor)
                    cursor = batch.cursor
                    try await ledger.recordSync(
                        workspaceID: config.workspaceID,
                        cursor: cursor,
                        errorCode: nil
                    )
                }
                if page.batches.count < 10 { break }
            }
            let summaries = try await ledger.machineSummaries(workspaceID: config.workspaceID)
            guard generation == configurationGeneration else { return }
            machines = summaries
            lastUpdated = Date()
            lastErrorCode = nil
        } catch {
            guard generation == configurationGeneration else { return }
            let code = (error as? RemoteSyncError)?.code ?? "sync_failed"
            lastErrorCode = code
            try? await ledger.recordSync(
                workspaceID: config.workspaceID,
                cursor: nil,
                errorCode: code
            )
            let summaries = try? await ledger.machineSummaries(workspaceID: config.workspaceID)
            guard generation == configurationGeneration else { return }
            machines = summaries ?? machines
        }
    }
}
