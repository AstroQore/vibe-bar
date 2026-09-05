import Foundation
import CoreFoundation

public struct ChatGPTChatTurn: Codable, Hashable, Sendable {
    public let id: String
    public let createdAt: Date
    public let model: String
    public let effort: String?
}

public enum ChatGPTChatParser {
    public struct Conversation: Codable, Sendable {
        public var updatedAt: Date
        public var turns: [ChatGPTChatTurn]
        public var isWork: Bool
        public var unclassifiedTurns: Int
    }

    public static func identity(_ value: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "chat", rawValue: value)
    }

    public static func features(_ data: Data) throws -> [QuotaBucket] {
        let root = try object(data)
        guard let rows = root["limits_progress"] as? [[String: Any]] else {
            throw QuotaError.parseFailure("ChatGPT Chat response has no limits_progress.")
        }
        return rows.compactMap { row in
            guard let feature = row["feature_name"] as? String,
                  let remaining = integer(row["remaining"]), remaining >= 0 else { return nil }
            let title: String
            switch feature {
            case "image_gen": title = "Image Generation"
            case "deep_research": title = "Deep Research"
            default: return nil
            }
            // The observed API supplies a remainder, not the plan's total.
            let quantity = QuotaQuantity(remaining: remaining)
            return QuotaBucket(id: feature, title: title, shortLabel: title, usedPercent: 0,
                               resetAt: date(row["reset_after"]), groupTitle: title, quantity: quantity)
        }
    }

    public static func conversation(_ data: Data, id: String, updatedAt: Date, since: Date? = nil, workModels: Set<String> = []) throws -> Conversation {
        let root = try object(data)
        guard root["conversation_id"] as? String == id,
              let mapping = root["mapping"] as? [String: [String: Any]] else {
            throw QuotaError.parseFailure("ChatGPT Chat conversation identity or mapping is missing.")
        }
        let origin = root["conversation_origin"] as? String
        let defaultModel = root["default_model_slug"] as? String
        if isWork(origin: origin, model: defaultModel) || defaultModel.map(workModels.contains) == true {
            return Conversation(updatedAt: updatedAt, turns: [], isWork: true, unclassifiedTurns: 0)
        }
        // A newly introduced source is not automatically a Chat source.
        let knownOrigin = origin == nil || origin == "chat" || origin == "chatgpt"
        var users: [String: [String: Any]] = [:]
        for (key, node) in mapping {
            if let message = node["message"] as? [String: Any],
               (message["author"] as? [String: Any])?["role"] as? String == "user" {
                if let since, let created = date(message["create_time"]), created < since { continue }
                users[key] = message
            }
        }
        var replies: [String: [[String: Any]]] = [:]
        var owners = Dictionary(users.keys.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        var missingOwners: Set<String> = []
        for (key, node) in mapping {
            guard let message = node["message"] as? [String: Any],
                  (message["author"] as? [String: Any])?["role"] as? String == "assistant",
                  message["recipient"] as? String == "all",
                  message["status"] as? String == "finished_successfully",
                  message["channel"] == nil || message["channel"] is NSNull || message["channel"] as? String == "final",
                  (message["content"] as? [String: Any])?["content_type"] as? String == "text"
            else { continue }
            var cursor: String? = key
            var path: [String] = []
            var visited: Set<String> = []
            var owner: String?
            while let current = cursor, visited.insert(current).inserted {
                if let known = owners[current] { owner = known; break }
                if missingOwners.contains(current) { break }
                // An older user turn is a boundary, not a path to a newer user.
                if let candidate = mapping[current]?["message"] as? [String: Any],
                   (candidate["author"] as? [String: Any])?["role"] as? String == "user" { break }
                path.append(current)
                cursor = mapping[current]?["parent"] as? String
            }
            if let owner {
                for node in path { owners[node] = owner }
                replies[owner, default: []].append(message)
            } else { missingOwners.formUnion(path) }

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
            if isWork(origin: origin, model: model) || workModels.contains(model) { continue }
            // Exact message model is essential: image helpers may differ from
            // the conversation's currently selected Pro model.
            let key = identity(id + ":" + messageID)
            let effort = (metadata["thinking_effort"] as? String).flatMap { validModel($0) ? $0 : nil }
            turns[key] = ChatGPTChatTurn(id: key, createdAt: created, model: model, effort: effort)
        }
        return Conversation(updatedAt: updatedAt, turns: Array(turns.values), isWork: false, unclassifiedTurns: unknown)
    }

    public static func isWork(origin: String?, model: String?) -> Bool {
        ["tpp", "flora", "codex"].contains(origin?.lowercased() ?? "")
            || (model?.lowercased().hasSuffix("-wm") ?? false)
            || (model?.lowercased().contains("codex") ?? false)
    }

    public static func modelBuckets(turns: [ChatGPTChatTurn], settings: ChatGPTChatSettings,
                                    complete: Bool, now: Date, catalog: ChatGPTChatModelCatalog = .empty) -> [QuotaBucket] {
        let unique = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let weeklyStart = periodStart(reset: settings.astraResetsAt, seconds: 604_800, now: now)
        let dailyStart = periodStart(reset: settings.dailyResetsAt, seconds: 86_400, now: now)
        let astra: Set<String> = ["gpt-6-pro", "gpt-6-astra-pro"]
        let sol: Set<String> = ["gpt-5-6-pro", "gpt-5.6-sol-pro", "gpt-5-6-sol-pro"]
        func bucket(id: String, title: String, modelSet: Set<String>, start: Date, limit: Int,
                    reset: Date?, window: Int) -> QuotaBucket {
            let used = unique.filter { modelSet.contains($0.model) && $0.createdAt >= start && $0.createdAt <= now }.count
            let quantity = QuotaQuantity(used: used, remaining: complete && limit > 0 ? max(0, limit - used) : nil,
                                         limit: limit, isEstimated: true, coverageComplete: complete)
            return QuotaBucket(id: id, title: title, shortLabel: title,
                               usedPercent: quantity.usedPercent ?? 0, resetAt: futureReset(reset, now: now),
                               rawWindowSeconds: window, groupTitle: title, quantity: quantity)
        }
        var result = [bucket(id: "astra_weekly", title: "GPT-6 Pro", modelSet: astra, start: weeklyStart,
                             limit: settings.astraWeeklyLimit, reset: settings.astraResetsAt, window: 604_800)]
        // Do not relabel Sol Thinking / Max as Pro. Those are kept as separate
        // observed model rows until the account's actual Pro slug is observed.
        if unique.contains(where: { sol.contains($0.model) }) || catalog.models["gpt-5-6-pro"]?.isPro == true {
            result.append(bucket(id: "sol_pro_daily", title: "GPT-5.6 Sol Pro", modelSet: sol, start: dailyStart,
                                 limit: settings.solDailyLimit, reset: settings.dailyResetsAt, window: 86_400))
        }
        if settings.sharedDailyLimit > 0 {
            result.append(bucket(id: "pro_shared_daily", title: "Pro Shared", modelSet: astra.union(sol), start: dailyStart,
                                 limit: settings.sharedDailyLimit, reset: settings.dailyResetsAt, window: 86_400))
        }
        let other = Set(unique.map(\.model)).subtracting(astra.union(sol)).sorted()
        for model in other {
            result.append(bucket(id: "model_" + model, title: catalog.models[model]?.displayTitle ?? model, modelSet: [model],
                                 start: now.addingTimeInterval(-604_800), limit: 0, reset: nil, window: 604_800))
        }
        return result
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("ChatGPT Chat response exceeds the read bound or is not an object.")
        }
        return value
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber, seconds.doubleValue.isFinite, seconds.doubleValue > 0 {
            return Date(timeIntervalSince1970: seconds.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func validModel(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", options: .regularExpression) != nil
    }

    private static func futureReset(_ reset: Date?, now: Date) -> Date? {
        reset.flatMap { $0 > now ? $0 : nil }
    }

    private static func periodStart(reset: Date?, seconds: TimeInterval, now: Date) -> Date {
        guard let reset, reset.timeIntervalSince(now) > 0, reset.timeIntervalSince(now) <= seconds else {
            return now.addingTimeInterval(-seconds)
        }
        return reset.addingTimeInterval(-seconds)
    }
}
