import Foundation

/// Extra cost on top of the subscription plan: pay-as-you-go credits balance
/// (Codex) and overage spend (Claude).
public struct ProviderExtras: Sendable, Equatable, Codable, Hashable {
    public let tool: ToolType
    public let creditsRemainingUSD: Double?     // Codex pay-as-you-go credits balance
    public let creditsTopupURL: URL?            // direct link to the Buy Credits page
    public let extraUsageSpendUSD: Double?      // Claude / Gemini overage spend
    public let extraUsageLimitUSD: Double?      // overage cap
    public let extraUsageEnabled: Bool          // whether the user has opted in
    public let updatedAt: Date

    public init(
        tool: ToolType,
        creditsRemainingUSD: Double? = nil,
        creditsTopupURL: URL? = nil,
        extraUsageSpendUSD: Double? = nil,
        extraUsageLimitUSD: Double? = nil,
        extraUsageEnabled: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.tool = tool
        self.creditsRemainingUSD = creditsRemainingUSD
        self.creditsTopupURL = creditsTopupURL
        self.extraUsageSpendUSD = extraUsageSpendUSD
        self.extraUsageLimitUSD = extraUsageLimitUSD
        self.extraUsageEnabled = extraUsageEnabled
        self.updatedAt = updatedAt
    }

    public var hasAnyData: Bool {
        creditsRemainingUSD != nil || extraUsageSpendUSD != nil
    }
}

/// One day in a rolling cost history.
public struct DailyCostPoint: Sendable, Equatable, Codable, Identifiable {
    public let date: Date
    public let costUSD: Double
    public let totalTokens: Int

    public var id: Date { date }

    public init(date: Date, costUSD: Double, totalTokens: Int) {
        self.date = date
        self.costUSD = costUSD
        self.totalTokens = totalTokens
    }
}

public struct CostHistory: Sendable, Equatable {
    public let tool: ToolType
    public let days: [DailyCostPoint]
    public let updatedAt: Date

    public init(tool: ToolType, days: [DailyCostPoint], updatedAt: Date = Date()) {
        self.tool = tool
        self.days = days
        self.updatedAt = updatedAt
    }
}

/// Hour-of-day × day-of-week heatmap — "when do I burn through my quota?"
public struct UsageHeatmap: Sendable, Equatable, Codable {
    public let tool: ToolType
    /// 7 × 24 grid: weekday (1 = Sunday) → hour (0–23) → token count for that bucket.
    public let cells: [[Int]]
    public let totalTokens: Int

    public init(tool: ToolType, cells: [[Int]], totalTokens: Int) {
        self.tool = tool
        self.cells = cells
        self.totalTokens = totalTokens
    }

    public static func empty(tool: ToolType) -> UsageHeatmap {
        UsageHeatmap(tool: tool, cells: Array(repeating: Array(repeating: 0, count: 24), count: 7), totalTokens: 0)
    }
}
