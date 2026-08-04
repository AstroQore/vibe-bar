import Foundation

public struct RemoteCoreConfig: Codable, Equatable, Sendable {
    public let schema: Int
    public let workspaceID: UUID
    public let coreDeviceID: UUID
    public let relayURL: URL
    public let coreEpoch: Int
    public let ingestKeyID: String
    public let probeSigningPublicKeys: [UUID: Data]

    public init(
        schema: Int = 1,
        workspaceID: UUID,
        coreDeviceID: UUID,
        relayURL: URL,
        coreEpoch: Int,
        ingestKeyID: String,
        probeSigningPublicKeys: [UUID: Data]
    ) throws {
        guard schema == 1 else { throw RemoteSyncError.invalidConfiguration }
        guard relayURL.scheme?.lowercased() == "https",
              relayURL.host != nil,
              relayURL.user == nil,
              relayURL.password == nil,
              relayURL.path.isEmpty || relayURL.path == "/",
              relayURL.query == nil,
              relayURL.fragment == nil
        else { throw RemoteSyncError.invalidConfiguration }
        // An empty probe map is legitimate: a Mac that has just joined a
        // workspace is the Core before any probe has enrolled. It simply
        // authorizes no producer yet, so every envelope is refused until the
        // workspace registers its first probe.
        guard (1..<Int(Int32.max)).contains(coreEpoch),
              (1...128).contains(ingestKeyID.count),
              (0...4096).contains(probeSigningPublicKeys.count),
              probeSigningPublicKeys.values.allSatisfy({ $0.count == 65 && $0.first == 0x04 })
        else { throw RemoteSyncError.invalidConfiguration }
        self.schema = schema
        self.workspaceID = workspaceID
        self.coreDeviceID = coreDeviceID
        self.relayURL = relayURL
        self.coreEpoch = coreEpoch
        self.ingestKeyID = ingestKeyID
        self.probeSigningPublicKeys = probeSigningPublicKeys
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case workspaceID = "workspace_id"
        case coreDeviceID = "core_device_id"
        case relayURL = "relay_url"
        case coreEpoch = "core_epoch"
        case ingestKeyID = "ingest_key_id"
        case probeSigningPublicKeys = "probe_signing_public_keys"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try RemoteCoreConfig(
            schema: container.decode(Int.self, forKey: .schema),
            workspaceID: container.decode(UUID.self, forKey: .workspaceID),
            coreDeviceID: container.decode(UUID.self, forKey: .coreDeviceID),
            relayURL: container.decode(URL.self, forKey: .relayURL),
            coreEpoch: container.decode(Int.self, forKey: .coreEpoch),
            ingestKeyID: container.decode(String.self, forKey: .ingestKeyID),
            probeSigningPublicKeys: try decodeProbeSigningKeys(
                container.decode([String: Data].self, forKey: .probeSigningPublicKeys)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(coreDeviceID, forKey: .coreDeviceID)
        try container.encode(relayURL, forKey: .relayURL)
        try container.encode(coreEpoch, forKey: .coreEpoch)
        try container.encode(ingestKeyID, forKey: .ingestKeyID)
        try container.encode(encodeProbeSigningKeys(probeSigningPublicKeys), forKey: .probeSigningPublicKeys)
    }
}

public struct RemoteCoreProvisioning: Codable, Sendable {
    public let schema: Int
    public let workspaceID: UUID
    public let coreDeviceID: UUID
    public let relayURL: URL
    public let relayBearerToken: String
    public let coreEpoch: Int
    public let ingestKeyID: String
    public let probeSigningPublicKeys: [UUID: Data]

    public init(
        schema: Int = 1,
        workspaceID: UUID,
        coreDeviceID: UUID,
        relayURL: URL,
        relayBearerToken: String,
        coreEpoch: Int,
        ingestKeyID: String,
        probeSigningPublicKeys: [UUID: Data]
    ) throws {
        let config = try RemoteCoreConfig(
            schema: schema,
            workspaceID: workspaceID,
            coreDeviceID: coreDeviceID,
            relayURL: relayURL,
            coreEpoch: coreEpoch,
            ingestKeyID: ingestKeyID,
            probeSigningPublicKeys: probeSigningPublicKeys
        )
        guard (32...512).contains(relayBearerToken.utf8.count),
              relayBearerToken.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace })
        else { throw RemoteSyncError.invalidConfiguration }
        self.schema = config.schema
        self.workspaceID = config.workspaceID
        self.coreDeviceID = config.coreDeviceID
        self.relayURL = config.relayURL
        self.relayBearerToken = relayBearerToken
        self.coreEpoch = config.coreEpoch
        self.ingestKeyID = config.ingestKeyID
        self.probeSigningPublicKeys = config.probeSigningPublicKeys
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case workspaceID = "workspace_id"
        case coreDeviceID = "core_device_id"
        case relayURL = "relay_url"
        case relayBearerToken = "relay_bearer_token"
        case coreEpoch = "core_epoch"
        case ingestKeyID = "ingest_key_id"
        case probeSigningPublicKeys = "probe_signing_public_keys"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try RemoteCoreProvisioning(
            schema: container.decode(Int.self, forKey: .schema),
            workspaceID: container.decode(UUID.self, forKey: .workspaceID),
            coreDeviceID: container.decode(UUID.self, forKey: .coreDeviceID),
            relayURL: container.decode(URL.self, forKey: .relayURL),
            relayBearerToken: container.decode(String.self, forKey: .relayBearerToken),
            coreEpoch: container.decode(Int.self, forKey: .coreEpoch),
            ingestKeyID: container.decode(String.self, forKey: .ingestKeyID),
            probeSigningPublicKeys: try decodeProbeSigningKeys(
                container.decode([String: Data].self, forKey: .probeSigningPublicKeys)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(coreDeviceID, forKey: .coreDeviceID)
        try container.encode(relayURL, forKey: .relayURL)
        try container.encode(relayBearerToken, forKey: .relayBearerToken)
        try container.encode(coreEpoch, forKey: .coreEpoch)
        try container.encode(ingestKeyID, forKey: .ingestKeyID)
        try container.encode(encodeProbeSigningKeys(probeSigningPublicKeys), forKey: .probeSigningPublicKeys)
    }
}

private func decodeProbeSigningKeys(_ raw: [String: Data]) throws -> [UUID: Data] {
    var decoded: [UUID: Data] = [:]
    for (key, value) in raw {
        guard let deviceID = UUID(uuidString: key), decoded[deviceID] == nil else {
            throw RemoteSyncError.invalidConfiguration
        }
        decoded[deviceID] = value
    }
    guard decoded.count == raw.count else { throw RemoteSyncError.invalidConfiguration }
    return decoded
}

private func encodeProbeSigningKeys(_ keys: [UUID: Data]) -> [String: Data] {
    Dictionary(uniqueKeysWithValues: keys.map {
        ($0.key.uuidString.lowercased(), $0.value)
    })
}

public struct RemoteCorePublicDescriptor: Codable, Sendable {
    public let schema: Int
    public let signingPublicKey: Data
    public let recipientPublicKey: Data

    public init(schema: Int = 1, signingPublicKey: Data, recipientPublicKey: Data) {
        self.schema = schema
        self.signingPublicKey = signingPublicKey
        self.recipientPublicKey = recipientPublicKey
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case signingPublicKey = "signing_public_key"
        case recipientPublicKey = "recipient_public_key"
    }
}

public struct RemoteMachineSummary: Identifiable, Equatable, Sendable {
    public let workspaceID: UUID
    public let producerID: UUID
    public let alias: String
    public let platform: String
    public let probeVersion: String
    public let lastSeenAt: Date
    public let lastScanAt: Date
    public let lastSequence: Int64
    public let sourceStatuses: [String: String]
    public let todayTokens: Int
    public let last7DaysTokens: Int
    public let last30DaysTokens: Int
    public let allTimeTokens: Int
    public let last30DaysCostUSD: Double
    public let byTool: [RemoteToolUsageSummary]

    public var id: String { workspaceID.uuidString + ":" + producerID.uuidString }
}

public struct RemoteToolUsageSummary: Identifiable, Equatable, Sendable {
    public let tool: String
    public let tokens: Int
    public let costUSD: Double
    public var id: String { tool }
}

public enum RemoteSyncError: Error, Equatable, Sendable {
    case notConfigured
    case invalidConfiguration
    case invalidEnvelope
    case unauthorizedProducer
    case invalidSignature
    case decryptionFailed
    case invalidPayload
    /// An authenticated batch from an earlier, superseded Core generation
    /// (a strictly lower `core_epoch`). Its recipient key was revoked when the
    /// Core rotated, so no current device can ever decrypt it. This is not a
    /// failure: the batch is skipped and acknowledged so the Relay's
    /// cursor-aware GC can reclaim it, and the stream keeps advancing.
    ///
    /// The producer and sequence travel with the error because the caller has
    /// to record the skip in the ledger — a skipped sequence still consumes a
    /// slot in that producer's chain, so the watermark must move past it or the
    /// next importable batch looks like a `sequenceGap`. Both values are
    /// signature-verified before this is thrown, and neither is a secret.
    case supersededEnvelope(producerID: UUID, sequence: Int64)
    case sequenceGap(expected: Int64, received: Int64)
    case rollback
    case http(Int)
    case invalidResponse

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidConfiguration: return "invalid_configuration"
        case .invalidEnvelope: return "invalid_envelope"
        case .unauthorizedProducer: return "unauthorized_producer"
        case .invalidSignature: return "invalid_signature"
        case .decryptionFailed: return "decryption_failed"
        case .invalidPayload: return "invalid_payload"
        case .supersededEnvelope: return "superseded_envelope"
        case .sequenceGap: return "sequence_gap"
        case .rollback: return "rollback"
        case .http: return "relay_http_error"
        case .invalidResponse: return "invalid_response"
        }
    }
}
