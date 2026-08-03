import Foundation
import Combine

@MainActor
public final class RemoteProbeService: ObservableObject {
    @Published public private(set) var machines: [RemoteMachineSummary] = []
    @Published public private(set) var isConfigured = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var lastErrorCode: String?

    private let config: RemoteCoreConfig?
    private let identity: RemoteCoreIdentity?
    private let client: RemoteRelayClient?
    private let ledger: RemoteUsageLedger?
    private var refreshLoop: Task<Void, Never>?

    public init() {
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
        } catch {
            self.config = nil
            self.identity = nil
            self.client = nil
            self.ledger = nil
            self.isConfigured = false
            self.lastErrorCode = (error as? RemoteSyncError)?.code
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
        guard !isRefreshing,
              let config, let identity, let client, let ledger
        else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var cursor = try await ledger.relayCursor(workspaceID: config.workspaceID)
            var pageCount = 0
            while pageCount < 100 {
                pageCount += 1
                let page = try await client.fetch(after: cursor)
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
            machines = try await ledger.machineSummaries(workspaceID: config.workspaceID)
            lastUpdated = Date()
            lastErrorCode = nil
        } catch {
            let code = (error as? RemoteSyncError)?.code ?? "sync_failed"
            lastErrorCode = code
            try? await ledger.recordSync(
                workspaceID: config.workspaceID,
                cursor: nil,
                errorCode: code
            )
            machines = (try? await ledger.machineSummaries(workspaceID: config.workspaceID)) ?? machines
        }
    }
}
