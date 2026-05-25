import Foundation

/// One observed reset window for a single quota bucket of a single
/// account. The store keeps a rolling history of these per (account,
/// bucket) so the UI can render a sparkline of "how full did I get in
/// each of the last N windows."
///
/// Identity for max-merge is `(accountId, bucketId, windowEnd)`. A
/// window is uniquely identified by its `resetAt` — every observation
/// of the same bucket within the same window converges to one sample,
/// with `peakUsedPercent` rising monotonically as new observations
/// arrive and `lastUsedPercent` tracking the time-newest value.
public struct SubscriptionWindowSample: Codable, Hashable, Sendable {
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
        lastSeenAt: Date
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
