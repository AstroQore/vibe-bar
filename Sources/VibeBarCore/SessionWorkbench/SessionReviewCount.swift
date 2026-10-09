import Foundation

/// A Codex session's Auto Reviews and how many there are — one rule for
/// every surface that states the number.
///
/// The Sessions list row, the conversation masthead and MCP's
/// `sessions.transcript` all show a review count, and three call sites each
/// deciding whether to trust a bounded list or ask for the grouped count is
/// how they would come to disagree. A list shorter than its bound is
/// complete and is its own count; at the bound, the grouped count — the same
/// query `SessionReviewIndex.overview()` answers the list rows from — is the
/// number.
public struct SessionReviewSet: Sendable, Hashable {
    public var reviews: [SessionSummary]
    public var count: Int

    public init(reviews: [SessionSummary] = [], count: Int = 0) {
        self.reviews = reviews
        self.count = max(count, reviews.count)
    }

    public static let empty = SessionReviewSet()
}

extension SessionReviewIndex {
    /// The reviews of `summary`, oldest first and at most `limit`, with the
    /// count of all of them. Empty for anything but a listed Codex session.
    public func reviewSet(for summary: SessionSummary, limit: Int) async -> SessionReviewSet {
        guard summary.provider == .codex,
              SessionVisibleRows.reviewParentID(of: summary) == nil,
              let list = try? reviews(forParents: [summary.sessionID], limit: limit),
              !list.isEmpty
        else { return .empty }
        guard list.count >= limit else { return SessionReviewSet(reviews: list, count: list.count) }
        let count = (try? reviewCount(forParent: summary.sessionID)) ?? list.count
        return SessionReviewSet(reviews: list, count: count)
    }
}

/// What the conversation masthead says about a session's Auto Reviews: how
/// many there are (`SessionReviewSet.count`, the list row's and MCP's
/// number) and the verdicts read out of them, by the parent turn each names.
public struct SessionReviewVerdicts: Sendable, Hashable {
    public var reviewCount: Int
    public var byTurnID: [String: [SessionStructure.GuardianVerdict]]

    public init(reviewCount: Int = 0, byTurnID: [String: [SessionStructure.GuardianVerdict]] = [:]) {
        self.reviewCount = reviewCount
        self.byTurnID = byTurnID
    }

    public static let none = SessionReviewVerdicts()
}
