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
    public let ollamaCredits: OllamaCreditUsage?

    public init(
        tool: ToolType,
        creditsRemainingUSD: Double? = nil,
        creditsTopupURL: URL? = nil,
        extraUsageSpendUSD: Double? = nil,
        extraUsageLimitUSD: Double? = nil,
        extraUsageEnabled: Bool = false,
        updatedAt: Date = Date(),
        ollamaCredits: OllamaCreditUsage? = nil
    ) {
        self.tool = tool
        self.creditsRemainingUSD = creditsRemainingUSD
        self.creditsTopupURL = creditsTopupURL
        self.extraUsageSpendUSD = extraUsageSpendUSD
        self.extraUsageLimitUSD = extraUsageLimitUSD
        self.extraUsageEnabled = extraUsageEnabled
        self.updatedAt = updatedAt
        self.ollamaCredits = ollamaCredits
    }

    public var hasAnyData: Bool {
        creditsRemainingUSD != nil || extraUsageSpendUSD != nil || ollamaCredits?.hasReportedAmounts == true
    }
}

/// Dollar-denominated wallet observations from Ollama's settings page.
public struct OllamaCreditUsage: Codable, Hashable, Sendable {
    public let balanceUSD: Double?
    public let monthlyUsedUSD: Double?
    public let refillText: String?

    var hasReportedAmounts: Bool {
        [balanceUSD, monthlyUsedUSD].contains { amount in
            guard let amount else { return false }
            return amount.isFinite && amount >= 0
        }
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

/// One hour in today's cost history.
public struct HourlyCostPoint: Sendable, Equatable, Codable, Identifiable {
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
