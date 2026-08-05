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
    /// Waits between retries of a Relay request the Relay asked us to repeat
    /// (429/503): 1s, then 2s, so three attempts in all. A stored property
    /// rather than a constant only so the test seam can collapse it to
    /// near-zero; it is deliberately not part of the public API.
    private var relayRetryDelays: [Duration] = [.seconds(1), .seconds(2)]

    /// Workspace this Core is bound to, for status display. Never a secret.
    public var workspaceID: UUID? { config?.workspaceID }
    public var coreDeviceID: UUID? { config?.coreDeviceID }
    public var relayURL: URL? { config?.relayURL }
    public var registeredProbeCount: Int { config?.probeSigningPublicKeys.count ?? 0 }

    /// Decrypted, local-only cost snapshots for the machines the user chose to
    /// merge into this Core. Returning an empty map on a transient ledger
    /// failure keeps the ordinary local snapshots usable.
    public func costSnapshots(
        includingMachineIDs machineIDs: Set<String>,
        now: Date = Date()
    ) async -> [ToolType: CostSnapshot] {
        guard let config, let ledger, !machineIDs.isEmpty else { return [:] }
        do {
            return try await ledger.costSnapshots(
                workspaceID: config.workspaceID,
                selectedMachineIDs: machineIDs,
                now: now
            )
        } catch {
            SafeLog.warn("remote cost aggregation skipped: invalid local ledger state")
            return [:]
        }
    }

    public init() {
        loadConfiguration()
    }

    /// Test seam: build a service already bound to an in-memory configuration
    /// and stubbed relay/ledger, bypassing the Keychain and `~/.vibebar` reads
    /// the production initializer performs. Not used by product code.
    init(
        config: RemoteCoreConfig,
        identity: RemoteCoreIdentity,
        client: RemoteRelayClient,
        ledger: RemoteUsageLedger,
        relayRetryDelays: [Duration] = [.seconds(1), .seconds(2)]
    ) {
        self.config = config
        self.identity = identity
        self.client = client
        self.ledger = ledger
        self.relayRetryDelays = relayRetryDelays
        self.isConfigured = true
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

    /// Learn the workspace's current probe roster from the Relay before any
    /// envelope is opened.
    ///
    /// A Core that joined with a one-time code authorizes nobody at all until
    /// this runs, and a Core provisioned from a file goes stale the moment its
    /// workspace enrolls or revokes a probe — so both paths repair themselves
    /// here, once per cycle. A roster fetch that fails keeps the installed
    /// map: an unreachable or older Relay must degrade to "no new probes",
    /// never to "reject everything".
    private func synchronizedProbeRoster(
        _ config: RemoteCoreConfig,
        client: RemoteRelayClient,
        generation: Int
    ) async -> RemoteCoreConfig {
        do {
            let devices = try await client.fetchDevices()
            guard generation == configurationGeneration else { return config }
            let resolution = RemoteProbeRoster.resolve(from: devices)
            if resolution.skipped > 0 {
                SafeLog.warn(
                    "remote roster: skipped \(resolution.skipped) active probe(s) with an unusable signing key"
                )
            }
            guard let updated = try RemoteProbeRoster.updatedConfiguration(
                for: config,
                resolution: resolution
            ) else { return config }
            try RemoteCoreConfigStore.updateProbeRoster(updated)
            self.config = updated
            SafeLog.net("remote roster updated: \(updated.probeSigningPublicKeys.count) authorized probe(s)")
            return updated
        } catch {
            SafeLog.net(
                "remote roster refresh skipped: \((error as? RemoteSyncError)?.code ?? "unavailable")"
            )
            return config
        }
    }

    /// Thrown when `reconfigure()` replaced the configuration while a cycle was
    /// asleep between Relay retries. It travels to `performRefresh`'s outer
    /// catch, which already returns without publishing once the generation no
    /// longer matches — so the stale cycle unwinds quietly instead of resuming
    /// against a configuration it never validated.
    private struct RefreshSuperseded: Error {}

    /// Perform one Relay request, retrying a bounded number of times when the
    /// Relay asks us to come back shortly.
    ///
    /// The Relay sits behind an nginx rate limiter. A burst of requests is
    /// answered 429, and nginx (like most CDNs) also sheds load with 503.
    /// Neither says the request was malformed, yet both used to abort the whole
    /// cycle: the cursor stopped advancing and the UI reported
    /// `relay_http_error` / "Last sync: never" even though every batch before
    /// the burst had imported fine. Three attempts spread over 1s + 2s ride out
    /// a limiter window; if they are exhausted the error propagates exactly as
    /// before and the cycle records it.
    ///
    /// Only 429 and 503 are retried. 400 (a cursor replayed against the wrong
    /// principal), 401, and 403 are real failures that will not fix themselves,
    /// and retrying them would just delay the error the user needs to see.
    ///
    /// `Retry-After` is **not** honored. `RemoteRelayClient.validate` collapses
    /// every non-200 into `RemoteSyncError.http(statusCode)`; widening that
    /// public, `Equatable` error case to carry a response header would ripple
    /// through the model, the client, and their tests for very little gain over
    /// a fixed schedule.
    private func withRelayRetry<T>(
        generation: Int,
        _ request: () async throws -> T
    ) async throws -> T {
        for delay in relayRetryDelays {
            do {
                return try await request()
            } catch let error as RemoteSyncError {
                guard case .http(let status) = error, status == 429 || status == 503 else {
                    throw error
                }
                try await Task.sleep(for: delay)
                guard generation == configurationGeneration else { throw RefreshSuperseded() }
            }
        }
        // Retries exhausted: this attempt's failure is the cycle's failure.
        return try await request()
    }

    /// Commit one page's progress: a single ack for the last batch the page
    /// processed, then a single local cursor write at the same position.
    ///
    /// Both are watermarks, which is what makes the batching safe — the Relay
    /// stores `MAX(existing, through)` and the ledger's `relay_cursor` is simply
    /// where the next fetch resumes.
    private func commitPage(
        through cursor: String,
        config: RemoteCoreConfig,
        client: RemoteRelayClient,
        ledger: RemoteUsageLedger,
        generation: Int
    ) async throws {
        try await withRelayRetry(generation: generation) {
            try await client.acknowledge(cursor: cursor)
        }
        try await ledger.recordSync(
            workspaceID: config.workspaceID,
            coreDeviceID: config.coreDeviceID,
            cursor: cursor,
            errorCode: nil
        )
    }

    private func performRefresh() async {
        guard !isRefreshing,
              var config = self.config,
              let identity, let client, let ledger
        else { return }
        let generation = configurationGeneration
        isRefreshing = true
        defer { isRefreshing = false }
        config = await synchronizedProbeRoster(config, client: client, generation: generation)
        guard generation == configurationGeneration else { return }
        do {
            var cursor = try await ledger.relayCursor(
                workspaceID: config.workspaceID,
                coreDeviceID: config.coreDeviceID
            )
            var pageCount = 0
            var skippedSuperseded = 0
            while pageCount < 100 {
                pageCount += 1
                let page = try await withRelayRetry(generation: generation) {
                    try await client.fetch(after: cursor)
                }
                guard generation == configurationGeneration else { return }
                guard !page.batches.isEmpty else { break }
                // One ack per page, not one per batch. The Relay's ack is a
                // monotonic watermark (`last_batch_id = MAX(existing, through)`),
                // so acknowledging only the last batch a page actually processed
                // is exactly equivalent to acknowledging each of them — at a
                // tenth of the requests. Draining a backlog of a few hundred
                // queued batches used to fire that many POST /acks in a tight
                // burst, which tripped the Relay's nginx rate limit; the
                // resulting 429 is not the superseded case, so it escaped the
                // per-batch catch and aborted the whole cycle with the cursor
                // still parked at its starting position.
                //
                // Crash safety: if the app dies after a page is processed but
                // before its ack lands, the next fetch re-delivers those
                // batches. `importBatch` dedups on `remote_imported_batches` and
                // `noteSupersededBatch` inserts with ON CONFLICT DO NOTHING, so
                // a redelivery is a no-op — the work is repeated at worst, never
                // double-counted.
                var processed: String?
                do {
                    for batch in page.batches {
                        do {
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
                        } catch RemoteSyncError.supersededEnvelope(let producerID, let sequence) {
                            // Authenticated backlog from a revoked Core
                            // generation: encrypted to a recipient key no current
                            // device holds, so it can never be imported. Count it
                            // as processed anyway so the page's ack lets the
                            // Relay's cursor-aware GC reclaim it, then keep going.
                            // Aborting here (the old behavior) would wedge the
                            // cursor and make every later sync repeat this
                            // failure. Every non-superseded error still propagates
                            // to the outer catch, unchanged.
                            //
                            // Skipping is not the same as ignoring: the sequence
                            // is recorded so the producer's watermark moves past
                            // it. Advancing only the Relay cursor (the dev.18
                            // behavior) left the ledger at 0 while the cursor
                            // walked over the whole superseded backlog, so the
                            // first current-epoch batch arrived as a
                            // `sequence_gap` and wedged the sync in a different
                            // place. The producer and sequence come from the error
                            // itself — both were signature-verified inside
                            // `openIngestEnvelope`, so the envelope is never
                            // parsed a second time here.
                            skippedSuperseded += 1
                            try await ledger.noteSupersededBatch(
                                workspaceID: config.workspaceID,
                                producerID: producerID,
                                sequence: sequence,
                                receivedAt: batch.receivedAt
                            )
                        }
                        processed = batch.cursor
                    }
                } catch {
                    // A non-superseded failure still aborts the cycle, exactly as
                    // before — but the batches this page already imported must not
                    // be replayed on every future cycle, so their watermark is
                    // committed before the error propagates. Both halves are
                    // best-effort on purpose: the batch failure is the one the
                    // cycle has to report, so neither a refused ack nor a ledger
                    // write may replace it.
                    if let processed {
                        try? await commitPage(
                            through: processed,
                            config: config,
                            client: client,
                            ledger: ledger,
                            generation: generation
                        )
                    }
                    throw error
                }
                guard let processed else { break }
                try await commitPage(
                    through: processed,
                    config: config,
                    client: client,
                    ledger: ledger,
                    generation: generation
                )
                cursor = processed
                if page.batches.count < 10 { break }
            }
            if skippedSuperseded > 0 {
                // Count only — never envelope contents or keys.
                SafeLog.warn(
                    "remote sync skipped \(skippedSuperseded) superseded-epoch batch(es)"
                )
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
                coreDeviceID: config.coreDeviceID,
                cursor: nil,
                errorCode: code
            )
            let summaries = try? await ledger.machineSummaries(workspaceID: config.workspaceID)
            guard generation == configurationGeneration else { return }
            machines = summaries ?? machines
        }
    }
}
