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

    public init(availableCount: Int, nextExpiresAt: Date? = nil) {
        self.availableCount = availableCount
        self.nextExpiresAt = nextExpiresAt
    }

    /// Whether there is at least one reset to spend (the gate the UI uses to
    /// decide whether to render the row at all).
    public var hasAvailable: Bool { availableCount > 0 }
}
