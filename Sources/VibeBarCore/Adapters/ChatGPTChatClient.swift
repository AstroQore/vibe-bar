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
        if path == "/api/auth/session" || parts.path == "/backend-api/conversations" || parts.path == "/backend-api/models" { return true }
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

public actor ChatGPTChatHistoryStore {
    public static let shared = ChatGPTChatHistoryStore()
    public struct Cache: Codable, Sendable {
        public var conversations: [String: ChatGPTChatParser.Conversation] = [:]
        public init() {}
    }
    private let url: URL
    public init(url: URL = VibeBarLocalStore.chatGPTChatHistoryURL) { self.url = url }
    public func load(identity: String) -> Cache {
        (try? VibeBarLocalStore.readJSON([String: Cache].self, from: url))?[identity] ?? Cache()
    }
    public func save(_ value: Cache, identity: String) {
        var all = (try? VibeBarLocalStore.readJSON([String: Cache].self, from: url)) ?? [:]
        all[identity] = value
        try? VibeBarLocalStore.writeJSON(all, to: url)
    }
}

public struct ChatGPTChatClient: Sendable {
    private let transport: any ChatGPTChatTransport
    private let store: ChatGPTChatHistoryStore
    public init(transport: any ChatGPTChatTransport, store: ChatGPTChatHistoryStore = .shared) {
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
        let body = try JSONSerialization.data(withJSONObject: [
            "conversation_id": NSNull(), "gizmo_id": NSNull(), "requested_default_model": NSNull(),
            "system_hints": [], "timezone_offset_min": -TimeZone.current.secondsFromGMT() / 60
        ])
        let featureData = try await transport.request(path: "/backend-api/conversation/init", method: "POST", bearer: token, body: body)
        var buckets = try ChatGPTChatParser.features(featureData)
        guard !buckets.isEmpty else { throw QuotaError.parseFailure("ChatGPT Chat returned no supported feature allowances.") }
        let modelData = try? await transport.request(path: "/backend-api/models?iim=false&include_icons=false", method: "GET", bearer: token, body: nil)
        let catalog = modelData.flatMap { try? ChatGPTChatModelCatalog.parse($0) } ?? .empty
        try Task.checkCancellation()
        var summary = ChatGPTChatSummary(transport: transport.name)
        if settings.includeHistory {
            let scope = ChatGPTChatParser.identity(userID + ":" + (account.accountId ?? "personal"))
            let history = await history(bearer: token, identity: scope, now: now, catalog: catalog)
            try Task.checkCancellation()
            summary = history.summary
            buckets += ChatGPTChatParser.modelBuckets(turns: history.turns, settings: settings.sanitized,
                                                      complete: summary.historyComplete, now: now, catalog: catalog)
        }
        return AccountQuota(accountId: account.id, tool: .chatgptChat, buckets: buckets,
                            plan: account.plan, email: user["email"] as? String,
                            queriedAt: now, chatGPTChat: summary)
    }

    private func history(bearer: String, identity: String, now: Date, catalog: ChatGPTChatModelCatalog) async -> (turns: [ChatGPTChatTurn], summary: ChatGPTChatSummary) {
        let cutoff = now.addingTimeInterval(-604_800)
        var cache = await store.load(identity: identity)
        cache.conversations = cache.conversations.filter { $0.value.updatedAt >= now.addingTimeInterval(-1_209_600) }
        var seen: Set<String> = []
        var offset = 0
        var completedStreams = 0
        var failures = 0
        var work = 0
        var unknown = 0
        var fetched = 0
        var turns: [ChatGPTChatTurn] = []
        let deadline = Date().addingTimeInterval(20)
        do {
            for archived in [false, true] {
            offset = 0
            var reachedEnd = false
            for _ in 0..<10 {
                try Task.checkCancellation()
                guard Date() < deadline else { break }
                let path = "/backend-api/conversations?offset=\(offset)&limit=50&order=updated&is_archived=\(archived)&is_starred=false"
                let data = try await transport.request(path: path, method: "GET", bearer: bearer, body: nil)
                let root = try ChatGPTChatParser.object(data)
                guard let items = root["items"] as? [[String: Any]] else { throw QuotaError.parseFailure("Missing ChatGPT Chat history items.") }
                let previousCount = seen.count
                for item in items {
                    guard let id = item["id"] as? String, !id.isEmpty else { failures += 1; continue }
                    guard seen.insert(id).inserted else { continue }
                    let updated = ChatGPTChatParser.date(item["update_time"])
                    if let updated, updated < cutoff { reachedEnd = true; continue }
                    // A positively identified Work row needs no Chat transcript
                    // lookup, even while it still carries a provisional WEB id.
                    if ChatGPTChatParser.isWork(origin: item["conversation_origin"] as? String, model: nil) { work += 1; continue }
                    guard UUID(uuidString: id) != nil, let updatedAt = updated else { failures += 1; continue }
                    let key = ChatGPTChatParser.identity(id)
                    var parsed = cache.conversations[key]
                    if parsed?.updatedAt != updatedAt || (parsed?.unclassifiedTurns ?? 0) > 0 {
                        if fetched < 24, Date() < deadline {
                            do {
                                fetched += 1
                                let detail = try await transport.request(path: "/backend-api/conversation/" + id,
                                                                         method: "GET", bearer: bearer, body: nil)
                                parsed = try ChatGPTChatParser.conversation(detail, id: id, updatedAt: updatedAt, since: cutoff, workModels: catalog.workModels)
                                cache.conversations[key] = parsed
                            } catch { failures += 1 }
                        } else { failures += 1 }
                    }
                    if let parsed {
                        work += parsed.isWork ? 1 : 0
                        unknown += parsed.unclassifiedTurns
                        turns += parsed.turns.filter { !catalog.workModels.contains($0.model) }
                    }
                }
                offset += items.count
                if items.isEmpty { reachedEnd = true }
                if let total = ChatGPTChatParser.integer(root["total"]), offset >= total { reachedEnd = true }
                if reachedEnd { break }
                if seen.count == previousCount { failures += 1; break }
            }
            if reachedEnd { completedStreams += 1 }
            }
        } catch { failures += 1 }
        if !Task.isCancelled { await store.save(cache, identity: identity) }
        let recent = turns.filter { $0.createdAt >= cutoff && $0.createdAt <= now }
        let summary = ChatGPTChatSummary(historyQueriedAt: now, historyComplete: completedStreams == 2 && failures == 0 && unknown == 0 && !Task.isCancelled,
                                        excludedWorkConversations: work, unclassifiedTurns: unknown,
                                        failedConversations: failures, observedFrom: cutoff, transport: transport.name)
        return (recent, summary)
    }
}
