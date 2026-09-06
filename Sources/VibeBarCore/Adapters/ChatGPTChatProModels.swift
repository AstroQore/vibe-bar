import Foundation

/// One Pro-model allowance as OpenAI publishes it for a plan's Chat surface.
///
/// Source: "GPT-5.6 and GPT-6 Pro in ChatGPT", help.openai.com article
/// 20001354, read 2026-09-07. The service reports no count for these models
/// — `conversation/init` names a model only once it is exhausted — so the
/// count comes from the saved history and the total from this table. Work
/// and Codex have their own rules and are never charged here.
public struct ChatGPTChatProAllowance: Hashable, Sendable {
    public let id: String
    /// The L3 group the bucket files under — the model, as the picker names
    /// it — so the card draws it the way it draws Codex's Spark lanes: the
    /// model as a header, the window as the row.
    public let group: String
    /// The window, as the row's title: "Weekly" or "Daily".
    public let title: String
    public let models: Set<String>
    public let limit: Int
    public let windowSeconds: Int
    public init(id: String, group: String, title: String, models: Set<String>, limit: Int, windowSeconds: Int) {
        self.id = id; self.group = group; self.title = title; self.models = models; self.limit = limit; self.windowSeconds = windowSeconds
    }
}

public enum ChatGPTChatProAllowances {
    /// The picker slugs, as `/backend-api/models` lists them for a Pro account.
    public static let gpt6Pro = "gpt-6-pro"
    public static let solPro = "gpt-5-6-pro"
    public static let week = 7 * 86_400
    public static let day = 86_400
    /// The names the help article and the picker use. GPT-6 Pro is
    /// "powered by GPT-6 Astra"; the shared lane covers both Pro models.
    public static let gpt6ProName = "GPT-6 Astra Pro"
    public static let solProName = "GPT-5.6 Sol Pro"
    public static let proModelsName = "Pro Models"

    /// `plan_type` as `/backend-api/wham/usage` reports it: `pro` is the
    /// $200 plan and `prolite` the $100 one. Plans without Pro models get
    /// nothing; so does an unrecognized plan, rather than a guessed total.
    public static func allowances(plan: String?) -> [ChatGPTChatProAllowance] {
        switch plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pro":
            return [
                ChatGPTChatProAllowance(id: "gpt6_pro_weekly", group: gpt6ProName, title: "Weekly", models: [gpt6Pro], limit: 200, windowSeconds: week),
                ChatGPTChatProAllowance(id: "sol_pro_daily", group: solProName, title: "Daily", models: [solPro], limit: 170, windowSeconds: day),
                ChatGPTChatProAllowance(id: "pro_daily", group: proModelsName, title: "Daily", models: [gpt6Pro, solPro], limit: 200, windowSeconds: day)
            ]
        case "prolite":
            return [ChatGPTChatProAllowance(id: "pro_weekly", group: proModelsName, title: "Weekly", models: [gpt6Pro, solPro], limit: 50, windowSeconds: week)]
        default:
            return []
        }
    }
}

/// A user message and the model that answered it. The id is a
/// privacy-preserving hash of the conversation and message ids; no text is kept.
public struct ChatGPTChatTurn: Codable, Hashable, Sendable {
    public let id: String
    public let createdAt: Date
    public let model: String
    public init(id: String, createdAt: Date, model: String) { self.id = id; self.createdAt = createdAt; self.model = model }
}

/// A model the service reports as unavailable until `resetsAt`, during which
/// the picker substitutes `fallbackModel`. This is the only reset the
/// service ever states for a Pro model.
public struct ChatGPTChatModelLimit: Hashable, Sendable {
    public let model: String
    public let resetsAt: Date?
    public let fallbackModel: String?
    public init(model: String, resetsAt: Date?, fallbackModel: String?) {
        self.model = model; self.resetsAt = resetsAt; self.fallbackModel = fallbackModel
    }
}

/// What the reader keeps of one conversation: when it last changed, and the
/// turns inside the window with their models.
public struct ChatGPTChatConversation: Codable, Hashable, Sendable {
    public var updatedAt: Date
    public var turns: [ChatGPTChatTurn]
    public var isWork: Bool
    public var unclassifiedTurns: Int
    public init(updatedAt: Date, turns: [ChatGPTChatTurn], isWork: Bool, unclassifiedTurns: Int) {
        self.updatedAt = updatedAt; self.turns = turns; self.isWork = isWork; self.unclassifiedTurns = unclassifiedTurns
    }
}

extension ChatGPTChatParser {
    /// `model_limits` as the ChatGPT client's own schema reads it:
    /// `{model_slug, resets_after, using_default_model_slug, description?}`,
    /// kept only while `resets_after` lies ahead. An empty list means no
    /// model is throttled right now, not that any allowance is full.
    public static func modelLimits(_ data: Data, now: Date) -> [ChatGPTChatModelLimit] {
        guard let root = try? object(data), let rows = root["model_limits"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let model = row["model_slug"] as? String, validModel(model) else { return nil }
            let reset = date(row["resets_after"])
            if let reset, reset <= now { return nil }
            let fallback = (row["using_default_model_slug"] as? String).flatMap { validModel($0) ? $0 : nil }
            return ChatGPTChatModelLimit(model: model, resetsAt: reset, fallbackModel: fallback)
        }
    }

    /// Work conversations carry `conversation_origin` `tpp` or `flora` and
    /// answer with `-wm` models; both are ChatGPT Agentic's, never Chat's.
    public static func isWork(origin: String?, model: String?) -> Bool {
        ["tpp", "flora", "codex"].contains(origin?.lowercased() ?? "")
            || (model?.lowercased().hasSuffix("-wm") ?? false)
            || (model?.lowercased().contains("codex") ?? false)
    }

    /// The user turns of one saved conversation, each charged to the model
    /// of its final answer. The user message itself names no model; the
    /// assistant and tool nodes under it do, and a regenerated answer keeps
    /// the same user node, so a turn is counted once however often it was
    /// retried. Turns before `since` are dropped, as is every message body.
    public static func conversation(_ data: Data, id: String, updatedAt: Date, since: Date) throws -> ChatGPTChatConversation {
        let root = try object(data)
        guard root["conversation_id"] as? String == id,
              let mapping = root["mapping"] as? [String: [String: Any]] else {
            throw QuotaError.parseFailure("ChatGPT Chat conversation identity or mapping is missing.")
        }
        let origin = root["conversation_origin"] as? String
        let defaultModel = root["default_model_slug"] as? String
        if isWork(origin: origin, model: defaultModel) {
            return ChatGPTChatConversation(updatedAt: updatedAt, turns: [], isWork: true, unclassifiedTurns: 0)
        }
        // A newly introduced origin is not automatically a Chat origin.
        let knownOrigin = origin == nil || origin == "chat" || origin == "chatgpt"
        var users: [String: [String: Any]] = [:]
        for (key, node) in mapping {
            if let message = node["message"] as? [String: Any], role(of: message) == "user" {
                if let created = date(message["create_time"]), created < since { continue }
                users[key] = message
            }
        }
        // Walk each final answer up to the user turn it answers.
        var replies: [String: [[String: Any]]] = [:]
        var owners = Dictionary(users.keys.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        var orphans: Set<String> = []
        for (key, node) in mapping {
            guard let message = node["message"] as? [String: Any], role(of: message) == "assistant",
                  message["recipient"] as? String == "all",
                  message["status"] as? String == "finished_successfully",
                  message["channel"] == nil || message["channel"] is NSNull || message["channel"] as? String == "final",
                  let contentType = (message["content"] as? [String: Any])?["content_type"] as? String,
                  contentType == "text" || contentType == "multimodal_text"
            else { continue }
            var cursor: String? = key
            var path: [String] = []
            var visited: Set<String> = []
            var owner: String?
            while let current = cursor, visited.insert(current).inserted {
                if let known = owners[current] { owner = known; break }
                if orphans.contains(current) { break }
                // An older user turn is a boundary, not a path to a newer one.
                if let candidate = mapping[current]?["message"] as? [String: Any], role(of: candidate) == "user" { break }
                path.append(current)
                cursor = mapping[current]?["parent"] as? String
            }
            if let owner {
                for node in path { owners[node] = owner }
                replies[owner, default: []].append(message)
            } else { orphans.formUnion(path) }
        }
        var turns: [String: ChatGPTChatTurn] = [:]
        var unknown = 0
        for (nodeID, user) in users {
            guard knownOrigin,
                  let messageID = user["id"] as? String, !messageID.isEmpty,
                  let created = date(user["create_time"]),
                  let reply = replies[nodeID]?.max(by: { (date($0["create_time"]) ?? .distantPast) < (date($1["create_time"]) ?? .distantPast) }),
                  let metadata = reply["metadata"] as? [String: Any],
                  let model = metadata["model_slug"] as? String, validModel(model)
            else { unknown += 1; continue }
            if isWork(origin: origin, model: model) { continue }
            let key = identity(id + ":" + messageID)
            turns[key] = ChatGPTChatTurn(id: key, createdAt: created, model: model)
        }
        return ChatGPTChatConversation(updatedAt: updatedAt, turns: Array(turns.values), isWork: false, unclassifiedTurns: unknown)
    }

    /// Each allowance as a quota bucket: the messages charged to its models
    /// inside a window ending now, against the published total. The service
    /// states no window start, so the count is a trailing window and is
    /// marked estimated; a throttled model overrides it with the service's
    /// own exhausted state and reset. A shared allowance counts as
    /// throttled only when every model it covers is.
    public static func proBuckets(allowances: [ChatGPTChatProAllowance], turns: [ChatGPTChatTurn],
                                  limits: [ChatGPTChatModelLimit], complete: Bool, now: Date) -> [QuotaBucket] {
        let unique = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let limited = Dictionary(limits.map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
        return allowances.map { allowance in
            let start = now.addingTimeInterval(-TimeInterval(allowance.windowSeconds))
            let used = unique.filter { allowance.models.contains($0.model) && $0.createdAt > start && $0.createdAt <= now }.count
            let exhausted = allowance.models.allSatisfy { limited[$0] != nil }
            let quantity: QuotaQuantity
            let resetAt: Date?
            if exhausted {
                quantity = QuotaQuantity(used: allowance.limit, remaining: 0, limit: allowance.limit, isEstimated: true)
                resetAt = allowance.models.compactMap { limited[$0]?.resetsAt }.max()
            } else {
                quantity = QuotaQuantity(used: used, remaining: complete ? max(0, allowance.limit - used) : nil,
                                         limit: allowance.limit, isEstimated: true, coverageComplete: complete)
                resetAt = nil
            }
            return QuotaBucket(id: allowance.id, title: allowance.title, shortLabel: allowance.title,
                               usedPercent: quantity.usedPercent ?? 0, resetAt: resetAt,
                               rawWindowSeconds: allowance.windowSeconds, groupTitle: allowance.group, quantity: quantity)
        }
    }

    private static func role(of message: [String: Any]) -> String? {
        (message["author"] as? [String: Any])?["role"] as? String
    }

    static func validModel(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", options: .regularExpression) != nil
    }
}
