import Foundation

public struct ChatGPTChatSettings: Codable, Hashable, Sendable {
    /// Bumped when a default changes for everyone. A file written under an
    /// older version takes the new defaults once; a choice made after that
    /// is kept. Version 1 (2026-09-07) turned both switches on.
    public static let currentDefaultsVersion = 1
    public var enabled = true
    /// Count GPT-6 Astra Pro and GPT-5.6 Sol Pro messages in the account's
    /// saved conversation history against the allowances OpenAI publishes
    /// for the plan. It reads the model and time of every recent message;
    /// no text is kept.
    public var trackProModels = true
    public var defaultsVersion = ChatGPTChatSettings.currentDefaultsVersion
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, trackProModels, defaultsVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .defaultsVersion) ?? 0
        if version >= Self.currentDefaultsVersion {
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            trackProModels = try c.decodeIfPresent(Bool.self, forKey: .trackProModels) ?? true
        } else {
            enabled = true
            trackProModels = true
        }
        defaultsVersion = Self.currentDefaultsVersion
    }
    public var sanitized: Self {
        var copy = self
        copy.defaultsVersion = Self.currentDefaultsVersion
        return copy
    }
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
