import Foundation

private final class RemoteNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
        config.relayURL
            .appendingPathComponent("v1")
            .appendingPathComponent("workspaces")
            .appendingPathComponent(config.workspaceID.uuidString.lowercased())
            .appendingPathComponent("streams")
            .appendingPathComponent("ingest")
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
