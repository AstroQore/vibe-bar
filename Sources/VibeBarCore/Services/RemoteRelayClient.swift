import Foundation

/// Shared by every remote-sync session (Relay batches and control-center
/// enrollment): a redirect off the configured origin would move a bearer
/// token or a one-time pairing code to a host the user never approved.
final class RemoteNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct RemoteRelayBatch: Sendable {
    let cursor: String
    let receivedAt: Date
    let envelope: Data
}

struct RemoteRelayPage: Sendable {
    let batches: [RemoteRelayBatch]
    let nextCursor: String
}

/// One row of the Relay's device roster. Public material only: who the device
/// is, whether the workspace still trusts it, and the signing key its
/// envelopes must carry. `signingPublicKey` is nil when the Relay omitted it
/// or it was not an uncompressed P-256 x963 point.
struct RemoteRelayDevice: Sendable, Equatable {
    let deviceID: UUID
    let role: String
    let status: String
    let signingPublicKey: Data?
}

/// Turns the Relay's device roster into the set of producers a Core
/// authorizes. Kept pure and separate from both the HTTP client and the
/// service so the "which probes may publish to me" rule is testable on its
/// own.
enum RemoteProbeRoster {
    struct Resolution: Equatable {
        let keys: [UUID: Data]
        /// Active probes the Core had to ignore because their signing key was
        /// missing or unusable. Counted so the failure is observable without
        /// ever logging the offending value.
        let skipped: Int
    }

    static func resolve(from devices: [RemoteRelayDevice]) -> Resolution {
        var keys: [UUID: Data] = [:]
        var skipped = 0
        for device in devices where device.role == "probe" && device.status == "active" {
            guard let key = device.signingPublicKey else {
                skipped += 1
                continue
            }
            keys[device.deviceID] = key
        }
        return Resolution(keys: keys, skipped: skipped)
    }

    /// The configuration this Core should adopt, or nil when the installed
    /// roster already matches — the caller then skips both the store write and
    /// the in-memory swap, so an unchanged workspace costs one GET per cycle
    /// and nothing else.
    static func updatedConfiguration(
        for config: RemoteCoreConfig,
        resolution: Resolution
    ) throws -> RemoteCoreConfig? {
        guard resolution.keys != config.probeSigningPublicKeys else { return nil }
        return try RemoteCoreConfig(
            schema: config.schema,
            workspaceID: config.workspaceID,
            coreDeviceID: config.coreDeviceID,
            relayURL: config.relayURL,
            coreEpoch: config.coreEpoch,
            ingestKeyID: config.ingestKeyID,
            probeSigningPublicKeys: resolution.keys
        )
    }
}

struct RemoteRelayClient: Sendable {
    let config: RemoteCoreConfig
    let bearerToken: String
    let session: URLSession

    init(
        config: RemoteCoreConfig,
        bearerToken: String,
        session: URLSession = RemoteRelayClient.makeSession()
    ) {
        self.config = config
        self.bearerToken = bearerToken
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: RemoteNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func fetch(after cursor: String?) async throws -> RemoteRelayPage {
        var components = URLComponents(
            url: endpoint(resource: "batches"),
            resolvingAgainstBaseURL: false
        )
        var query = [URLQueryItem(name: "limit", value: "10")]
        if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
        components?.queryItems = query
        guard let url = components?.url else { throw RemoteSyncError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await HTTPResponseLimit.boundedData(
            from: session,
            for: request,
            maxBytes: 12 * 1_048_576
        )
        try validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["batches", "next_cursor"],
              let rawBatches = object["batches"] as? [[String: Any]],
              rawBatches.count <= 10,
              let nextCursor = object["next_cursor"] as? String
        else { throw RemoteSyncError.invalidResponse }
        let batches = try rawBatches.map { raw -> RemoteRelayBatch in
            guard Set(raw.keys) == ["cursor", "received_at", "envelope"],
                  let batchCursor = raw["cursor"] as? String,
                  let received = exactNonnegativeInteger(raw["received_at"]),
                  let envelope = raw["envelope"] as? [String: Any]
            else { throw RemoteSyncError.invalidResponse }
            return RemoteRelayBatch(
                cursor: batchCursor,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(received)),
                envelope: try JSONSerialization.data(withJSONObject: envelope)
            )
        }
        if let last = batches.last, last.cursor != nextCursor {
            throw RemoteSyncError.invalidResponse
        }
        return RemoteRelayPage(batches: batches, nextCursor: nextCursor)
    }

    /// The workspace's current device roster. Same device-bearer credential,
    /// no-redirect session, and bounded response as the batch calls; the Relay
    /// requires the caller to be the workspace's Core.
    func fetchDevices() async throws -> [RemoteRelayDevice] {
        var request = URLRequest(url: workspaceEndpoint(resource: "devices"))
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await HTTPResponseLimit.boundedData(
            from: session,
            for: request,
            maxBytes: 1_048_576
        )
        try validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDevices = object["devices"] as? [[String: Any]],
              rawDevices.count <= 4096
        else { throw RemoteSyncError.invalidResponse }
        return try rawDevices.map { raw in
            guard let idRaw = raw["device_id"] as? String,
                  let deviceID = UUID(uuidString: idRaw),
                  let role = raw["role"] as? String,
                  let status = raw["status"] as? String
            else { throw RemoteSyncError.invalidResponse }
            // A key this Core cannot use is not a malformed roster: the row is
            // still authoritative about the device's role and status, so keep
            // it and let the roster policy decide (and count) the skip.
            var signingPublicKey: Data?
            if let keyRaw = raw["signing_public_key"] as? String,
               let key = Data(base64Encoded: keyRaw),
               key.count == 65, key.first == 0x04 {
                signingPublicKey = key
            }
            return RemoteRelayDevice(
                deviceID: deviceID,
                role: role,
                status: status,
                signingPublicKey: signingPublicKey
            )
        }
    }

    func acknowledge(cursor: String) async throws {
        var request = URLRequest(url: endpoint(resource: "acks"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor])
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await HTTPResponseLimit.boundedData(
            from: session,
            for: request,
            maxBytes: 64 * 1024
        )
        try validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["acknowledged_cursor"],
              let acknowledged = object["acknowledged_cursor"] as? String,
              acknowledged == cursor
        else { throw RemoteSyncError.invalidResponse }
    }

    private func endpoint(resource: String) -> URL {
        workspaceEndpoint(resource: "streams")
            .appendingPathComponent("ingest")
            .appendingPathComponent(resource)
    }

    private func workspaceEndpoint(resource: String) -> URL {
        config.relayURL
            .appendingPathComponent("v1")
            .appendingPathComponent("workspaces")
            .appendingPathComponent(config.workspaceID.uuidString.lowercased())
            .appendingPathComponent(resource)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteSyncError.invalidResponse
        }
        guard http.statusCode == 200 else { throw RemoteSyncError.http(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true else {
            throw RemoteSyncError.invalidResponse
        }
    }

    private func exactNonnegativeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d", number.int64Value >= 0 else { return nil }
        return number.int64Value
    }
}
