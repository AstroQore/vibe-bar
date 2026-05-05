import Foundation

public struct AccountIdentity: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var tool: ToolType
    public var email: String?
    public var alias: String?
    public var plan: String?
    public var accountId: String?
    public var source: CredentialSource
    public var allowsWebFallback: Bool
    public var allowsCLIFallback: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        tool: ToolType,
        email: String? = nil,
        alias: String? = nil,
        plan: String? = nil,
        accountId: String? = nil,
        source: CredentialSource,
        allowsWebFallback: Bool = false,
        allowsCLIFallback: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tool = tool
        self.email = email
        self.alias = alias
        self.plan = plan
        self.accountId = accountId
        self.source = source
        self.allowsWebFallback = allowsWebFallback
        self.allowsCLIFallback = allowsCLIFallback
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayLabel: String {
        if let alias, !alias.isEmpty { return alias }
        if let email, !email.isEmpty { return email }
        if let accountId, !accountId.isEmpty { return accountId }
        return "\(tool.displayName) account"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tool
        case email
        case alias
        case plan
        case accountId
        case source
        case allowsWebFallback
        case allowsCLIFallback
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.tool = try c.decode(ToolType.self, forKey: .tool)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        self.alias = try c.decodeIfPresent(String.self, forKey: .alias)
        self.plan = try c.decodeIfPresent(String.self, forKey: .plan)
        self.accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        self.source = try c.decode(CredentialSource.self, forKey: .source)
        self.allowsWebFallback = try c.decodeIfPresent(Bool.self, forKey: .allowsWebFallback) ?? false
        self.allowsCLIFallback = try c.decodeIfPresent(Bool.self, forKey: .allowsCLIFallback) ?? false
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tool, forKey: .tool)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(alias, forKey: .alias)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encodeIfPresent(accountId, forKey: .accountId)
        try c.encode(source, forKey: .source)
        try c.encode(allowsWebFallback, forKey: .allowsWebFallback)
        try c.encode(allowsCLIFallback, forKey: .allowsCLIFallback)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
