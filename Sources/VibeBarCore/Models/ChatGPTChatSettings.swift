import Foundation

public struct ChatGPTChatSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
    public var sanitized: Self { self }
}

public struct ChatGPTChatSummary: Codable, Hashable, Sendable {
    public var transport: String
    public var planVerified: Bool?
    public var accountIdentity: String?
    public init(transport: String, planVerified: Bool? = nil, accountIdentity: String? = nil) {
        self.transport = transport; self.planVerified = planVerified; self.accountIdentity = accountIdentity
    }
}
