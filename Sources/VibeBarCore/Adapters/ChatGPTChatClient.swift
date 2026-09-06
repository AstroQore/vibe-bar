import Foundation

public protocol ChatGPTChatTransport: Sendable {
    var name: String { get }
    /// Whether the transport authenticates every request itself, so the
    /// client neither fetches a web session token nor passes one. The
    /// OAuth transport does; the cookie and WebView ones need the token
    /// the chatgpt.com session hands out.
    var ownsBearer: Bool { get }
    func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data
}

public extension ChatGPTChatTransport {
    var ownsBearer: Bool { false }
}

/// The Codex CLI's OAuth bearer, sent with the `ChatGPT-Account-Id` the
/// Codex quota adapter sends. chatgpt.com's backend accepts it for the same
/// read-only endpoints the web session token reaches — the plan, the feature
/// allowances, and the saved history — so a Codex login is a Chat login too,
/// with no web cookie or WebView needed.
public final class ChatGPTChatOAuthTransport: NSObject, ChatGPTChatTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public let name = "oauth"
    public var ownsBearer: Bool { true }
    private let credential: CodexCredential
    private var session: URLSession!

    public init(credential: CodexCredential, configuration: URLSessionConfiguration = .ephemeral) {
        self.credential = credential
        super.init()
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func close() { session.invalidateAndCancel() }

    public func request(path: String, method: String = "GET", bearer: String? = nil, body: Data? = nil) async throws -> Data {
        guard ChatGPTChatRequestPolicy.allows(path: path, method: method),
              path != "/api/auth/session",
              let url = URL(string: "https://chatgpt.com" + path) else { throw QuotaError.parseFailure("Invalid ChatGPT Chat request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(ChatGPTChatRequestPolicy.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let id = credential.accountId, !id.isEmpty {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try ChatGPTChatCookieTransport.validate(status: (response as? HTTPURLResponse)?.statusCode ?? 0, size: data.count)
        return data
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // The bearer must never leave its origin.
        completionHandler(nil)
    }
}

/// Only first-party, read-like Chat endpoints are reachable through any
/// transport: the session, the plan, the allowances, and — for counting Pro
/// model messages — the saved-conversation list and single conversations.
public enum ChatGPTChatRequestPolicy {
    /// chatgpt.com's edge answers the history endpoints only to a browser
    /// user agent (a CLI or app string gets its challenge page instead);
    /// the same string is accepted by every other Chat endpoint, so all
    /// transports send it.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let listFields: Set<String> = ["offset", "limit", "order", "is_archived"]

    public static func allows(path: String, method: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"), !path.contains("\\"),
              let parts = URLComponents(string: path), parts.host == nil, parts.scheme == nil else { return false }
        if method == "POST" { return path == "/backend-api/conversation/init" }
        guard method == "GET" else { return false }
        if path == "/api/auth/session" || path == "/backend-api/wham/usage" { return true }
        if parts.path == "/backend-api/conversations" {
            return (parts.queryItems ?? []).allSatisfy { listFields.contains($0.name) }
        }
        let prefix = "/backend-api/conversation/"
        return parts.path.hasPrefix(prefix) && parts.query == nil
            && UUID(uuidString: String(parts.path.dropFirst(prefix.count))) != nil
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
        request.setValue(ChatGPTChatRequestPolicy.userAgent, forHTTPHeaderField: "User-Agent")
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
    private let historyStore: ChatGPTChatHistoryStore
    public init(transport: any ChatGPTChatTransport, store: ChatGPTChatAllowanceStore = .shared,
                historyStore: ChatGPTChatHistoryStore = .shared) {
        self.transport = transport
        self.store = store
        self.historyStore = historyStore
    }

    public func fetch(account: AccountIdentity, settings: ChatGPTChatSettings, now: Date = Date()) async throws -> AccountQuota {
        let token: String?
        let userID: String
        let email: String?
        let plan: String?
        if transport.ownsBearer {
            // No web session to ask: the account and its plan come from
            // the usage endpoint every ChatGPT bearer can read.
            let usageData = try await transport.request(path: "/backend-api/wham/usage", method: "GET", bearer: nil, body: nil)
            let usage = try ChatGPTChatParser.object(usageData)
            guard let id = (usage["user_id"] as? String) ?? (usage["account_id"] as? String), !id.isEmpty else {
                throw QuotaError.needsLogin
            }
            token = nil
            userID = id
            email = usage["email"] as? String
            plan = CodexResponseParser.planType(data: usageData)
        } else {
            let sessionData = try await transport.request(path: "/api/auth/session", method: "GET", bearer: nil, body: nil)
            let session = try ChatGPTChatParser.object(sessionData)
            guard let webToken = session["accessToken"] as? String, !webToken.isEmpty,
                  let user = session["user"] as? [String: Any], let id = user["id"] as? String else {
                throw QuotaError.needsLogin
            }
            token = webToken
            userID = id
            email = user["email"] as? String
            // Reuse Agentic's existing account-plan endpoint and parser, through
            // this Chat account's transport so a different CLI account cannot leak in.
            let planData = try? await transport.request(path: "/backend-api/wham/usage", method: "GET", bearer: webToken, body: nil)
            plan = planData.flatMap { CodexResponseParser.planType(data: $0) }
        }
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
        var buckets = samples.map { sample in
            let title = sample.id == "image_gen" ? "Image Generation" : "Deep Research"
            return QuotaBucket(id: sample.id, title: title, shortLabel: title, usedPercent: 0,
                               resetAt: sample.resetAt, rawWindowSeconds: quantities[sample.id]?.windowSeconds,
                               quantity: quantities[sample.id]?.quantity)
        }
        var summary = ChatGPTChatSummary(transport: transport.name, planVerified: plan != nil, accountIdentity: identity)
        // The Pro models have no service count: their buckets are the saved
        // history's turns against the plan's published allowance, and only
        // when the plan is one that has Pro models. The same `init` reply
        // names any model that is exhausted right now.
        let allowances = ChatGPTChatProAllowances.allowances(plan: plan)
        if settings.trackProModels, !allowances.isEmpty {
            let history = await ChatGPTChatHistoryReader(transport: transport, store: historyStore)
                .read(bearer: token, identity: identity, now: now)
            try Task.checkCancellation()
            summary.history = history.summary
            buckets += ChatGPTChatParser.proBuckets(allowances: allowances, turns: history.turns,
                                                   limits: ChatGPTChatParser.modelLimits(data, now: now),
                                                   complete: history.summary.complete, now: now)
        }
        return AccountQuota(accountId: account.id, tool: .chatgptChat, buckets: buckets,
                            plan: plan, email: email, queriedAt: now, chatGPTChat: summary)
    }
}
