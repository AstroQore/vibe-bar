import Foundation

public struct AccountQuota: Codable, Hashable, Sendable {
    public var accountId: String
    public var tool: ToolType
    public var buckets: [QuotaBucket]
    public var plan: String?
    public var email: String?
    public var queriedAt: Date
    public var error: QuotaError?
    public var providerExtras: ProviderExtras?

    public init(
        accountId: String,
        tool: ToolType,
        buckets: [QuotaBucket],
        plan: String? = nil,
        email: String? = nil,
        queriedAt: Date = Date(),
        error: QuotaError? = nil,
        providerExtras: ProviderExtras? = nil
    ) {
        self.accountId = accountId
        self.tool = tool
        self.buckets = buckets
        self.plan = VisibleSecretRedactor.dropIfSensitive(plan)
        self.email = email
        self.queriedAt = queriedAt
        self.error = error
        self.providerExtras = providerExtras
    }

    public func bucket(id: String) -> QuotaBucket? {
        buckets.first { $0.id == id }
    }

    public var primaryBucket: QuotaBucket? {
        bucket(id: "five_hour") ?? buckets.first
    }

    public var weeklyBucket: QuotaBucket? {
        bucket(id: "weekly")
    }

    enum CodingKeys: String, CodingKey {
        case accountId, tool, buckets, plan, email, queriedAt, error, providerExtras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(String.self, forKey: .accountId)
        tool = try c.decode(ToolType.self, forKey: .tool)
        buckets = try c.decode([QuotaBucket].self, forKey: .buckets)
        plan = VisibleSecretRedactor.dropIfSensitive(try c.decodeIfPresent(String.self, forKey: .plan))
        email = try c.decodeIfPresent(String.self, forKey: .email)
        queriedAt = try c.decode(Date.self, forKey: .queriedAt)
        providerExtras = try c.decodeIfPresent(ProviderExtras.self, forKey: .providerExtras)
        error = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(tool, forKey: .tool)
        try c.encode(buckets, forKey: .buckets)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encode(queriedAt, forKey: .queriedAt)
        try c.encodeIfPresent(providerExtras, forKey: .providerExtras)
    }
}
