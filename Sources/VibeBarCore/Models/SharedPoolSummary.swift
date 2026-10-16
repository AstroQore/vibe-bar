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
    /// The product row's name when an account is on the bundle; a glossary
    /// term in vibe-bar-i18n, never translated.
    public static let subProviderName = "X Subscription"

    /// Which mark a product row wears.
    public enum Member: String, Sendable {
        /// Grok's own products: Build, Chat, Imagine, Voice, API …
        case grok
        case grokBot
        case cursor
        /// A product xAI has not named yet.
        case other
    }

    /// One product's share of the pool, as xAI lists it — "Chat 1% ·
    /// Grok Bot 1% · Cursor 1%" on grok.com's usage page — with the mark
    /// it wears.
    public struct MemberShare: Equatable, Sendable {
        public let label: String
        public let member: Member
        public let usedPercent: Double

        public init(label: String, member: Member, usedPercent: Double) {
            self.label = label
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

    /// The order grok.com's usage page lists the products in; anything it
    /// does not name follows, in the order reported.
    static let displayOrder = ["Chat", "Imagine", "Voice", "Grok Build", "Grok Bot", "Cursor"]

    /// One row per product, in grok.com's order, a repeated label folded
    /// into one.
    static func members(from shares: [QuotaBucketShare]) -> [MemberShare] {
        var order: [String] = []
        var totals: [String: Double] = [:]
        for share in shares {
            if totals[share.label] == nil { order.append(share.label) }
            totals[share.label, default: 0] += share.usedPercent
        }
        func rank(_ label: String) -> Int {
            Self.displayOrder.firstIndex { $0.caseInsensitiveCompare(label) == .orderedSame } ?? Self.displayOrder.count
        }
        let sorted = order.enumerated().sorted { lhs, rhs in
            let (lr, rr) = (rank(lhs.element), rank(rhs.element))
            return lr == rr ? lhs.offset < rhs.offset : lr < rr
        }.map(\.element)
        return sorted.map { label in
            MemberShare(label: label, member: Self.member(for: label), usedPercent: totals[label] ?? 0)
        }
    }

    static func member(for label: String) -> Member {
        switch label.lowercased().replacingOccurrences(of: " ", with: "") {
        case "grokbot": return .grokBot
        case "cursor": return .cursor
        case "other": return .other
        default: return .grok
        }
    }
}
