import Foundation

public struct ChatGPTChatSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var includeHistory = true
    /// Zero means unknown. Limits are user-confirmed, never inferred from "Pro" alone.
    public var astraWeeklyLimit = 0
    public var solDailyLimit = 0
    public var sharedDailyLimit = 0
    /// Optional provider-displayed reset anchors; otherwise history uses rolling windows.
    public var astraResetsAt: Date?
    public var dailyResetsAt: Date?

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, includeHistory, astraWeeklyLimit, solDailyLimit, sharedDailyLimit, astraResetsAt, dailyResetsAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        includeHistory = try c.decodeIfPresent(Bool.self, forKey: .includeHistory) ?? true
        astraWeeklyLimit = try c.decodeIfPresent(Int.self, forKey: .astraWeeklyLimit) ?? 0
        solDailyLimit = try c.decodeIfPresent(Int.self, forKey: .solDailyLimit) ?? 0
        sharedDailyLimit = try c.decodeIfPresent(Int.self, forKey: .sharedDailyLimit) ?? 0
        astraResetsAt = try c.decodeIfPresent(Date.self, forKey: .astraResetsAt)
        dailyResetsAt = try c.decodeIfPresent(Date.self, forKey: .dailyResetsAt)
        self = sanitized
    }


    public var sanitized: Self {
        var value = self
        value.astraWeeklyLimit = min(100_000, max(0, astraWeeklyLimit))
        value.solDailyLimit = min(100_000, max(0, solDailyLimit))
        value.sharedDailyLimit = min(100_000, max(0, sharedDailyLimit))
        return value
    }
}

public struct ChatGPTChatSummary: Codable, Hashable, Sendable {
    public var historyQueriedAt: Date?
    public var historyComplete: Bool
    public var excludedWorkConversations: Int
    public var unclassifiedTurns: Int
    public var failedConversations: Int
    public var observedFrom: Date?
    public var transport: String

    public init(historyQueriedAt: Date? = nil, historyComplete: Bool = false,
                excludedWorkConversations: Int = 0, unclassifiedTurns: Int = 0,
                failedConversations: Int = 0, observedFrom: Date? = nil, transport: String = "cookie") {
        self.historyQueriedAt = historyQueriedAt
        self.historyComplete = historyComplete
        self.excludedWorkConversations = excludedWorkConversations
        self.unclassifiedTurns = unclassifiedTurns
        self.failedConversations = failedConversations
        self.observedFrom = observedFrom
        self.transport = transport
    }
}
