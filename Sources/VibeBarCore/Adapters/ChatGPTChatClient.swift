import Foundation

public protocol ChatGPTChatTransport: Sendable {
    var name: String { get }
    func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data
}

/// Only first-party, read-like Chat endpoints are reachable through either transport.
public enum ChatGPTChatRequestPolicy {
    public static func allows(path: String, method: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"), !path.contains("\\"),
              let parts = URLComponents(string: path), parts.host == nil, parts.scheme == nil else { return false }
        if method == "POST" { return path == "/backend-api/conversation/init" }
        guard method == "GET" else { return false }
        return path == "/api/auth/session" || path == "/backend-api/wham/usage"
    }
}

public final class ChatGPTChatCookieTransport: NSObject, ChatGPTChatTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public let name = "cookie"
    private let cookieHeader: String
    private var session: URLSession!

    public init(cookieHeader: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.cookieHeader = cookieHeader
        super.init()
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func close() { session.invalidateAndCancel() }

    public func request(path: String, method: String = "GET", bearer: String? = nil, body: Data? = nil) async throws -> Data {
        guard ChatGPTChatRequestPolicy.allows(path: path, method: method),
              let url = URL(string: "https://chatgpt.com" + path) else { throw QuotaError.parseFailure("Invalid ChatGPT Chat request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        do {
            let maximum = 8 * 1024 * 1024
            try Self.validate(status: (response as? HTTPURLResponse)?.statusCode ?? 0, size: 0)
            guard response.expectedContentLength <= maximum else {
                throw QuotaError.parseFailure("ChatGPT Chat response exceeds 8 MiB.")
            }
            var data = Data()
            data.reserveCapacity(Int(max(0, response.expectedContentLength)))
            for try await byte in bytes {
                guard data.count < maximum else {
                    throw QuotaError.parseFailure("ChatGPT Chat response exceeds 8 MiB.")
                }
                data.append(byte)
            }
            return data
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    public static func validate(status: Int, size: Int) throws {
        switch status {
        case 200: break
        case 401, 403: throw QuotaError.needsLogin
        case 429: throw QuotaError.rateLimited
        default: throw QuotaError.network("ChatGPT Chat HTTP \(status)")
        }
        guard size <= 8 * 1024 * 1024 else { throw QuotaError.parseFailure("ChatGPT Chat response exceeds 8 MiB.") }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirected auth cookies/tokens must never leave their owning origin.
        completionHandler(nil)
    }
}

public struct ChatGPTChatClient: Sendable {
    private let transport: any ChatGPTChatTransport
    private let store: ChatGPTChatAllowanceStore
    public init(transport: any ChatGPTChatTransport, store: ChatGPTChatAllowanceStore = .shared) {
        self.transport = transport
        self.store = store
    }

    public func fetch(account: AccountIdentity, settings: ChatGPTChatSettings, now: Date = Date()) async throws -> AccountQuota {
        let sessionData = try await transport.request(path: "/api/auth/session", method: "GET", bearer: nil, body: nil)
        let session = try ChatGPTChatParser.object(sessionData)
        guard let token = session["accessToken"] as? String, !token.isEmpty,
              let user = session["user"] as? [String: Any], let userID = user["id"] as? String else {
            throw QuotaError.needsLogin
        }
        // Reuse Agentic's existing account-plan endpoint and parser, through
        // this Chat account's transport so a different CLI account cannot leak in.
        let planData = try? await transport.request(path: "/backend-api/wham/usage", method: "GET", bearer: token, body: nil)
        let plan = planData.flatMap { CodexResponseParser.planType(data: $0) }
        let body = try JSONSerialization.data(withJSONObject: [
            "conversation_id": NSNull(), "gizmo_id": NSNull(), "requested_default_model": NSNull(),
            "system_hints": [], "timezone": TimeZone.current.identifier,
            "timezone_offset_min": -TimeZone.current.secondsFromGMT() / 60
        ])
        let data = try await transport.request(path: "/backend-api/conversation/init", method: "POST", bearer: token, body: body)
        let samples = try ChatGPTChatParser.samples(data, now: now)
        guard !samples.isEmpty else { throw QuotaError.parseFailure("ChatGPT Chat returned no supported feature allowances.") }
        try Task.checkCancellation()
        let identity = ChatGPTChatParser.identity(userID + ":" + (account.accountId ?? "personal"))
        let quantities = try await store.observe(localAccount: account.id, identity: identity,
                                                plan: plan?.lowercased(), samples: samples)
        let buckets = samples.map { sample in
            let title = sample.id == "image_gen" ? "Image Generation" : "Deep Research"
            return QuotaBucket(id: sample.id, title: title, shortLabel: title, usedPercent: 0,
                               resetAt: sample.resetAt, rawWindowSeconds: quantities[sample.id]?.windowSeconds,
                               quantity: quantities[sample.id]?.quantity)
        }
        return AccountQuota(accountId: account.id, tool: .chatgptChat, buckets: buckets,
                            plan: plan, email: user["email"] as? String, queriedAt: now,
                            chatGPTChat: ChatGPTChatSummary(transport: transport.name, planVerified: plan != nil, accountIdentity: identity))
    }
}
