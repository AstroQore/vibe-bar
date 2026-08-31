import Foundation

/// One inferred subscription cycle for a quota bucket. The active cycle is
/// updated in place; it becomes a historical sample after a refill is inferred
/// from usage, a proportional reset-time advance, or both signals together.
public struct SubscriptionWindowSample: Codable, Hashable, Sendable {
    public enum CompletionReason: String, Codable, Hashable, Sendable {
        case refillDetected
        case scheduledReset
        case legacyTimelineMigration
    }

    /// What the provider did to the clock when it refilled, which is a
    /// different question from how the refill was noticed.
    ///
    /// A window that refills before it said it would is an event worth
    /// showing, and the two early shapes mean opposite things. When the next
    /// reset moves out to a full window from the refill, a whole window lies
    /// ahead and the extra capacity is usable. When it does not move, less
    /// than a window remains to spend the refill in, so it is the easier one
    /// to waste.
    public enum ResetKind: String, Codable, Hashable, Sendable {
        case onSchedule
        case earlyClockRestarted
        case earlyClockUnchanged
        case earlyUnclear
        /// Asked and unanswerable: the observations this cycle would have been
        /// judged from are gone, pruned or never recorded. Distinct from `nil`,
        /// which means nobody has looked — without the difference the backfill
        /// would retry every launch, forever, for a cycle whose evidence no
        /// longer exists.
        case unobserved
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
    /// Optional so samples written before this existed still decode; a nil on
    /// a completed cycle means it finished before the app classified them.
    public var resetKind: ResetKind?
    /// How long after the previous refill this one arrived. Compared against
    /// `rawWindowSeconds`, this is what shows a bucket keeping a schedule
    /// other than the one it advertises.
    public var intervalSeconds: TimeInterval?

    public var isCompleted: Bool { completedAt != nil }

    /// Did this window refill before it said it would?
    public var refilledEarly: Bool {
        switch resetKind {
        case .earlyClockRestarted, .earlyClockUnchanged, .earlyUnclear: true
        case .onSchedule, .unobserved, nil: false
        }
    }
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
        completionReason: CompletionReason? = nil,
        resetKind: ResetKind? = nil,
        intervalSeconds: TimeInterval? = nil
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
        self.resetKind = resetKind
        self.intervalSeconds = intervalSeconds
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
