import Foundation

/// Reads quota from the OpenCode Go usage API using the selected instance's
/// API key. The default instance can also use an explicit environment key.
public struct OpenCodeGoQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .openCodeGo

    private let session: URLSession
    private let environment: [String: String]
    private let storedAPIKey: @Sendable (String) -> String?
    private let now: @Sendable () -> Date

    private static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let apiSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // The endpoint is fixed; never forward its bearer key on a redirect.
        return URLSession(configuration: configuration, delegate: RemoteNoRedirectDelegate(), delegateQueue: nil)
    }()

    public init() {
        self.init(
            session: Self.apiSession,
            environment: ProcessInfo.processInfo.environment,
            storedAPIKey: { Self.readStoredAPIKey($0) }
        )
    }

    init(
        session: URLSession,
        environment: [String: String],
        storedAPIKey: @escaping @Sendable (String) -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.environment = environment
        self.storedAPIKey = storedAPIKey
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        try Task.checkCancellation()
        let instanceID = AccountStore.miscInstanceID(fromAccountID: account.id, fallbackTool: .openCodeGo)
        guard account.tool == tool, account.id == AccountStore.miscAccountId(forInstanceID: instanceID),
              let key = Self.resolveAPIKey(for: instanceID, environment: environment, storedAPIKey: storedAPIKey) else {
            throw QuotaError.noCredential
        }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw QuotaError.credentialRejected("")
        }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Transport diagnostics may include request metadata.
            throw QuotaError.network("")
        }
        guard let http = response as? HTTPURLResponse else { throw QuotaError.network("") }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw QuotaError.credentialRejected("")
        case 403 where OpenCodeGoUsageResponse.requiresSubscription(data):
            throw QuotaError.parseFailure(L10n.Error.openCodeGoSubscriptionRequired)
        case 429:
            throw QuotaError.rateLimited
        default:
            throw QuotaError.network("HTTP \(http.statusCode)")
        }

        return AccountQuota(
            accountId: account.id,
            tool: .openCodeGo,
            buckets: try OpenCodeGoUsageResponse.buckets(from: data),
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }

    static func resolveAPIKey(
        for instanceID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedAPIKey: (String) -> String? = readStoredAPIKey
    ) -> String? {
        let stored = storedAPIKey(instanceID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        guard instanceID == ToolType.openCodeGo.rawValue,
              let fallback = environment["OPENCODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else { return nil }
        return fallback
    }

    private static func readStoredAPIKey(_ instanceID: String) -> String? {
        MiscCredentialStore.readString(tool: .openCodeGo, kind: .apiKey, instanceID: instanceID)
    }
}

private struct OpenCodeGoUsageResponse: Decodable {
    struct Usage: Decodable {
        let rolling: Window
        let weekly: Window
        let monthly: Window
    }

    struct Window: Decodable {
        enum Status: String, Decodable {
            case ok
            case rateLimited = "rate-limited"
        }

        let status: Status
        let percent: Double
        let resetsAt: String?

        private enum CodingKeys: String, CodingKey { case status, percent, resetsAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decode(Status.self, forKey: .status)
            percent = try values.decode(Double.self, forKey: .percent)
            resetsAt = try? values.decode(String.self, forKey: .resetsAt)
        }
    }

    let usage: Usage

    static func buckets(from data: Data) throws -> [QuotaBucket] {
        guard let usage = (try? JSONDecoder().decode(Self.self, from: data))?.usage else {
            throw QuotaError.parseFailure("")
        }

        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func resetDate(_ value: String?) -> Date? {
            guard let value else { return nil }
            return dateParser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }

        func bucket(_ window: Window, id: String, title: String, label: String, duration: Int) throws -> QuotaBucket {
            guard (0...100).contains(window.percent) else { throw QuotaError.parseFailure("") }
            return QuotaBucket(
                id: "opencodego.\(id)",
                title: title,
                shortLabel: label,
                usedPercent: window.percent,
                resetAt: resetDate(window.resetsAt),
                rawWindowSeconds: duration
            )
        }

        return try [
            bucket(usage.rolling, id: "rolling", title: "5 Hours", label: "5h", duration: 5 * 3600),
            bucket(usage.weekly, id: "weekly", title: "Weekly", label: "Wk", duration: 7 * 86_400),
            bucket(usage.monthly, id: "monthly", title: "Monthly", label: "Month", duration: 30 * 86_400)
        ]
    }

    static func requiresSubscription(_ data: Data) -> Bool {
        struct ErrorEnvelope: Decodable {
            struct Detail: Decodable { let type: String }
            let error: Detail
        }

        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.type == "EntitlementError"
    }
}
