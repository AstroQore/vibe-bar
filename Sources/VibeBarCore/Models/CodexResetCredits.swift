import Foundation

/// Codex "rate-limit reset credits" — manual reset grants the user can spend to
/// reset a rate-limit window early (Codex CLI `/reset`). Surfaced in the Codex
/// card as "N manual resets available · next expires in …".
///
/// `availableCount` is authoritative. It comes either from the inline
/// `rate_limit_reset_credits.available_count` in the `/wham/usage` payload or
/// from the dedicated `/wham/rate-limit-reset-credits` endpoint. `nextExpiresAt`
/// is the earliest expiry among still-available, non-expired credits and is only
/// populated when the dedicated endpoint is reachable.
public struct CodexResetCredits: Codable, Hashable, Sendable {
    public var availableCount: Int
    public var nextExpiresAt: Date?
    /// One entry per available credit, sorted by expiry. Nil means only the
    /// inline count was available; duplicate dates can belong to different grants.
    public var availableExpirations: [Date]?
    public var redemptions: [CodexResetCreditRedemption]?

    public init(availableCount: Int, nextExpiresAt: Date? = nil, availableExpirations: [Date]? = nil,
                redemptions: [CodexResetCreditRedemption]? = nil) {
        self.availableCount = availableCount
        self.availableExpirations = availableExpirations?.sorted()
        self.nextExpiresAt = nextExpiresAt ?? availableExpirations?.min()
        self.redemptions = redemptions
    }

    /// Whether there is at least one reset to spend (the gate the UI uses to
    /// decide whether to render the row at all).
    public var hasAvailable: Bool { availableCount > 0 }
}

public struct CodexResetCreditRedemption: Codable, Hashable, Sendable {
    /// Hash of the provider's grant id. No redeemable identifier is persisted.
    public var id: String
    public var redeemedAt: Date
    public init(id: String, redeemedAt: Date) { self.id = id; self.redeemedAt = redeemedAt }
}
