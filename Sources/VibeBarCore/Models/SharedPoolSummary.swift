import Foundation

/// The X Subscription's one weekly pool, assembled from the two accounts that
/// read it: Grok's (the pool and its split by product) and Cursor's (the same
/// pool as the `grok_bot_weekly` bucket, to a finer precision).
///
/// Grok's headline percent is a whole number — xAI rounds it — while Cursor
/// reports the pool with decimals, so when both describe one pool the pool is
/// drawn with Cursor's figure. One pool is recognised by its reset, which the
/// two providers report to the millisecond; two readings that do not reset
/// together are two pools, and this summary does not exist.
public struct SharedPoolSummary: Equatable, Sendable {
    public enum Member: String, CaseIterable, Sendable {
        case grok
        case grokBot
        case cursor
        case other
    }

    public struct MemberShare: Equatable, Sendable {
        public let member: Member
        public let usedPercent: Double

        public init(member: Member, usedPercent: Double) {
            self.member = member
            self.usedPercent = usedPercent
        }
    }

    /// The pool as a bucket, ready to draw: Grok's Weekly, its percent
    /// replaced by Cursor's finer reading, its shares removed (the members
    /// below carry them).
    public let bucket: QuotaBucket
    /// Who drew from the pool, in display order, only the members with a
    /// known share. Empty when xAI reported no split.
    public let members: [MemberShare]

    /// How far apart two readings of one pool may reset.
    public static let resetTolerance: TimeInterval = 60

    public init(bucket: QuotaBucket, members: [MemberShare]) {
        self.bucket = bucket
        self.members = members
    }

    /// `nil` unless Grok's quota has a live Weekly and Cursor's quota is a
    /// unified seat (no legacy monthly buckets) reading the same pool.
    public static func make(grok: AccountQuota?, cursor: AccountQuota?) -> SharedPoolSummary? {
        guard let grok, grok.error == nil, let weekly = grok.weeklyBucket, weekly.hasPercentage,
              let cursor, cursor.error == nil,
              !cursor.buckets.contains(where: { $0.id == "models" || $0.id == "other_models" }),
              let poolOnCursor = cursor.bucket(id: "grok_bot_weekly"),
              let grokReset = weekly.resetAt, let cursorReset = poolOnCursor.resetAt,
              abs(grokReset.timeIntervalSince(cursorReset)) <= Self.resetTolerance
        else { return nil }

        var bucket = weekly
        bucket.usedPercent = poolOnCursor.usedPercent
        bucket.shares = nil
        return SharedPoolSummary(bucket: bucket, members: Self.members(from: weekly.shares ?? []))
    }

    /// Fold xAI's per-product shares into the members a user recognises:
    /// Grok's own products together, Grok Bot, Cursor, and anything xAI has
    /// not named yet.
    static func members(from shares: [QuotaBucketShare]) -> [MemberShare] {
        var totals: [Member: Double] = [:]
        for share in shares {
            totals[Self.member(for: share.label), default: 0] += share.usedPercent
        }
        return Member.allCases.compactMap { member in
            totals[member].map { MemberShare(member: member, usedPercent: $0) }
        }
    }

    static func member(for label: String) -> Member {
        switch label.lowercased().replacingOccurrences(of: " ", with: "") {
        case "grokbot": return .grokBot
        case "cursor": return .cursor
        case "build", "chat", "imagine", "voice", "grok": return .grok
        default: return .other
        }
    }
}
