import Foundation

/// One inferred subscription cycle for a quota bucket. The active cycle is
/// updated in place; it becomes a historical sample only after a refill is
/// observed (usage falls materially) or a scheduled reset is crossed.
public struct SubscriptionWindowSample: Codable, Hashable, Sendable {
    public enum CompletionReason: String, Codable, Hashable, Sendable {
        case refillDetected
        case scheduledReset
        case legacyTimelineMigration
    }

    public var accountId: String
    public var tool: ToolType
    public var bucketId: String
    public var windowEnd: Date
    public var windowStart: Date?
    public var rawWindowSeconds: Int?
    public var peakUsedPercent: Double
    public var lastUsedPercent: Double
    public var observationCount: Int
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var completedAt: Date?
    public var completionReason: CompletionReason?

    public var isCompleted: Bool { completedAt != nil }
    public var remainingPercentAtReset: Double {
        max(0, 100 - peakUsedPercent)
    }

    public init(
        accountId: String,
        tool: ToolType,
        bucketId: String,
        windowEnd: Date,
        windowStart: Date? = nil,
        rawWindowSeconds: Int? = nil,
        peakUsedPercent: Double,
        lastUsedPercent: Double,
        observationCount: Int = 1,
        firstSeenAt: Date,
        lastSeenAt: Date,
        completedAt: Date? = nil,
        completionReason: CompletionReason? = nil
    ) {
        self.accountId = accountId
        self.tool = tool
        self.bucketId = bucketId
        self.windowEnd = windowEnd
        self.windowStart = windowStart
        self.rawWindowSeconds = rawWindowSeconds
        self.peakUsedPercent = Self.clamp(peakUsedPercent)
        self.lastUsedPercent = Self.clamp(lastUsedPercent)
        self.observationCount = max(0, observationCount)
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.completedAt = completedAt
        self.completionReason = completionReason
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }
}

/// Composite key (accountId + bucketId) used by `QuotaService` to
/// expose subscription-history samples to SwiftUI views as one
/// dictionary. Bucket ids are stable across refreshes; account ids
/// are already privacy-preserving hashes.
public struct SubscriptionHistoryKey: Hashable, Sendable {
    public var accountId: String
    public var bucketId: String

    public init(accountId: String, bucketId: String) {
        self.accountId = accountId
        self.bucketId = bucketId
    }
}
