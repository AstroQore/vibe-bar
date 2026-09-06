import Foundation

public struct ChatGPTChatSettings: Codable, Hashable, Sendable {
    public var enabled = false
    /// Count GPT-6 Pro and GPT-5.6 Sol Pro messages in the account's saved
    /// conversation history against the allowances OpenAI publishes for the
    /// plan. Off by default: it reads the model and time of every recent
    /// message, which the feature allowances never need.
    public var trackProModels = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, trackProModels }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        trackProModels = try c.decodeIfPresent(Bool.self, forKey: .trackProModels) ?? false
    }
    public var sanitized: Self { self }
}

/// What one read of the saved history covered, so a count can say how much
/// of the window it actually saw.
public struct ChatGPTChatHistorySummary: Codable, Hashable, Sendable {
    public var queriedAt: Date
    public var observedFrom: Date
    /// Every conversation updated inside the window was read this round or
    /// was already cached at its current revision.
    public var complete: Bool
    public var conversationsRead: Int
    public var excludedWorkConversations: Int
    public var unclassifiedTurns: Int
    public var failedConversations: Int
    public init(queriedAt: Date, observedFrom: Date, complete: Bool, conversationsRead: Int,
                excludedWorkConversations: Int, unclassifiedTurns: Int, failedConversations: Int) {
        self.queriedAt = queriedAt; self.observedFrom = observedFrom; self.complete = complete
        self.conversationsRead = conversationsRead; self.excludedWorkConversations = excludedWorkConversations
        self.unclassifiedTurns = unclassifiedTurns; self.failedConversations = failedConversations
    }
}

public struct ChatGPTChatSummary: Codable, Hashable, Sendable {
    public var transport: String
    public var planVerified: Bool?
    public var accountIdentity: String?
    public var history: ChatGPTChatHistorySummary?
    public init(transport: String, planVerified: Bool? = nil, accountIdentity: String? = nil,
                history: ChatGPTChatHistorySummary? = nil) {
        self.transport = transport; self.planVerified = planVerified; self.accountIdentity = accountIdentity
        self.history = history
    }
}
