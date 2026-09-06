import Foundation

/// The reader's cache: one entry per saved conversation at the revision it
/// was last parsed, so an unchanged conversation is never fetched twice.
/// Keyed by the Chat account identity; holds hashed ids, times and model
/// slugs only.
public actor ChatGPTChatHistoryStore {
    public static let shared = ChatGPTChatHistoryStore()
    public struct Cache: Codable, Sendable {
        public var conversations: [String: ChatGPTChatConversation] = [:]
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

/// Reads the account's saved conversations updated inside the counting
/// window and collects their turns. The list is walked newest first and
/// stops at the first conversation older than the window; only
/// conversations whose revision changed are fetched in full, within a
/// per-refresh budget so one refresh cannot run away on a busy account.
/// Whatever the budget or a failure left unread is reported, not hidden.
public struct ChatGPTChatHistoryReader: Sendable {
    public struct Result: Sendable {
        public let turns: [ChatGPTChatTurn]
        public let summary: ChatGPTChatHistorySummary
    }
    /// The longest published Pro window: a week.
    public static let windowSeconds: TimeInterval = 7 * 86_400
    public static let pageSize = 50
    public static let maxPages = 4
    public static let detailBudget = 24
    public static let deadlineSeconds: TimeInterval = 25

    private let transport: any ChatGPTChatTransport
    private let store: ChatGPTChatHistoryStore
    public init(transport: any ChatGPTChatTransport, store: ChatGPTChatHistoryStore = .shared) {
        self.transport = transport
        self.store = store
    }

    public func read(bearer: String?, identity: String, now: Date) async -> Result {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        var cache = await store.load(identity: identity)
        cache.conversations = cache.conversations.filter { $0.value.updatedAt >= now.addingTimeInterval(-2 * Self.windowSeconds) }
        var seen: Set<String> = []
        var streamsFinished = 0, failures = 0, work = 0, unknown = 0, fetched = 0, read = 0
        var turns: [ChatGPTChatTurn] = []
        let deadline = Date().addingTimeInterval(Self.deadlineSeconds)
        do {
            for archived in [false, true] {
                var offset = 0
                var reachedEnd = false
                for _ in 0..<Self.maxPages {
                    try Task.checkCancellation()
                    guard Date() < deadline else { break }
                    let path = "/backend-api/conversations?offset=\(offset)&limit=\(Self.pageSize)&order=updated&is_archived=\(archived)"
                    let data = try await transport.request(path: path, method: "GET", bearer: bearer, body: nil)
                    let root = try ChatGPTChatParser.object(data)
                    guard let items = root["items"] as? [[String: Any]] else {
                        throw QuotaError.parseFailure("ChatGPT Chat history list has no items.")
                    }
                    let before = seen.count
                    for item in items {
                        guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
                        let updated = ChatGPTChatParser.date(item["update_time"])
                        if let updated, updated < cutoff { reachedEnd = true; continue }
                        // A Work row is known from the list alone; no transcript is read for it.
                        if ChatGPTChatParser.isWork(origin: item["conversation_origin"] as? String, model: nil) { work += 1; continue }
                        if item["is_temporary_chat"] as? Bool == true { continue }
                        guard UUID(uuidString: id) != nil, let updatedAt = updated else { failures += 1; continue }
                        let key = ChatGPTChatParser.identity(id)
                        var parsed = cache.conversations[key]
                        if parsed?.updatedAt != updatedAt {
                            if fetched < Self.detailBudget, Date() < deadline {
                                fetched += 1
                                do {
                                    let detail = try await transport.request(path: "/backend-api/conversation/" + id,
                                                                             method: "GET", bearer: bearer, body: nil)
                                    parsed = try ChatGPTChatParser.conversation(detail, id: id, updatedAt: updatedAt, since: cutoff)
                                    cache.conversations[key] = parsed
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch { failures += 1 }
                            } else { failures += 1 }
                        }
                        if let parsed {
                            read += 1
                            if parsed.isWork { work += 1 }
                            unknown += parsed.unclassifiedTurns
                            turns += parsed.turns
                        }
                    }
                    offset += items.count
                    if items.isEmpty { reachedEnd = true }
                    if let total = ChatGPTChatParser.integer(root["total"]), offset >= total { reachedEnd = true }
                    if reachedEnd { break }
                    if seen.count == before { failures += 1; break }
                }
                if reachedEnd { streamsFinished += 1 }
            }
        } catch is CancellationError {
            // Reported below as incomplete; nothing partial is saved.
        } catch { failures += 1 }
        if !Task.isCancelled { await store.save(cache, identity: identity) }
        let recent = turns.filter { $0.createdAt >= cutoff && $0.createdAt <= now }
        let complete = streamsFinished == 2 && failures == 0 && !Task.isCancelled
        let summary = ChatGPTChatHistorySummary(queriedAt: now, observedFrom: cutoff, complete: complete,
                                                conversationsRead: read, excludedWorkConversations: work,
                                                unclassifiedTurns: unknown, failedConversations: failures)
        return Result(turns: recent, summary: summary)
    }
}
