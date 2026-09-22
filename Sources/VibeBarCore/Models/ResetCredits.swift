import Foundation

/// Usage-limit reset credits — grants a provider gives the user to spend on
/// resetting a rate-limit window early. Codex calls them "rate-limit reset
/// credits" (Codex CLI `/reset`), Claude calls them "Resets" (the
/// `cedar_ember` block of the usage payload) and Grok "remaining resets"
/// (`ConsumerUiSvc/GetRemainingResets`). One model for all three, rendered by
/// the same card row.
///
/// `availableCount` is authoritative. `nextExpiresAt` is the earliest expiry
/// among still-available, non-expired credits when the provider reports one.
///
/// Stored as `AccountQuota.resetCredits` and in `~/.vibebar/quotas/`; the
/// property names are the wire keys, so they stay as the Codex-only type
/// spelled them and older cache files decode unchanged.
public struct ResetCredits: Codable, Hashable, Sendable {
    public var availableCount: Int
    public var nextExpiresAt: Date?
    /// One entry per available credit, sorted by expiry. Nil means only the
    /// inline count was available; duplicate dates can belong to different grants.
    public var availableExpirations: [Date]?
    /// Credits spent. Server receipts (Codex history) unless marked inferred.
    public var redemptions: [ResetCreditEvent]?
    /// Credits received, when the provider publishes that (Codex history).
    public var grants: [ResetCreditEvent]?
    /// Per-credit inventory when the provider lists credits individually.
    /// This is what a falling count is judged from on providers that publish
    /// no receipts (Claude, Grok).
    public var tokens: [ResetCreditToken]?
    /// Record an inferred redemption only when a window the credit clears
    /// was also seen refilling early in the same interval. Grok's tokens say
    /// nothing about why one disappeared, so the reset is the corroboration.
    public var inferenceRequiresObservedReset: Bool?

    public init(availableCount: Int, nextExpiresAt: Date? = nil, availableExpirations: [Date]? = nil,
                redemptions: [ResetCreditEvent]? = nil, grants: [ResetCreditEvent]? = nil,
                tokens: [ResetCreditToken]? = nil, inferenceRequiresObservedReset: Bool? = nil) {
        self.availableCount = availableCount
        self.availableExpirations = availableExpirations?.sorted()
        self.nextExpiresAt = nextExpiresAt ?? availableExpirations?.min()
        self.redemptions = redemptions
        self.grants = grants
        self.tokens = tokens
        self.inferenceRequiresObservedReset = inferenceRequiresObservedReset
    }

    /// Whether there is at least one reset to spend (the gate the UI uses to
    /// decide whether to render the row at all).
    public var hasAvailable: Bool { availableCount > 0 }

    /// Bucket ids the available credits clear, in first-seen order. Empty
    /// when the provider does not say (Codex, Grok).
    public var clearedBucketIDs: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for token in tokens ?? [] where token.remaining > 0 {
            for id in token.clears ?? [] where seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}

/// One credit spent or received.
public struct ResetCreditEvent: Codable, Hashable, Sendable {
    /// Hash of the provider's grant / event id. No redeemable identifier is persisted.
    public var id: String
    /// When it happened: the server's timestamp for a receipt, the read that
    /// first saw the count fall for an inferred redemption.
    public var occurredAt: Date
    /// True when no receipt exists and the event was inferred from a credit
    /// count falling while the credit was still valid. Nil means a receipt.
    public var inferred: Bool?
    /// For an inferred event, the previous read: the redemption happened in
    /// `(observedAfter, occurredAt]`.
    public var observedAfter: Date?
    /// Vibe Bar bucket ids the credit cleared, when the provider says.
    /// Nil means every window of the account (Codex).
    public var clears: [String]?

    public init(id: String, occurredAt: Date, inferred: Bool? = nil, observedAfter: Date? = nil,
                clears: [String]? = nil) {
        self.id = id
        self.occurredAt = occurredAt
        self.inferred = inferred == true ? true : nil
        self.observedAfter = observedAfter
        self.clears = clears
    }

    public var isInferred: Bool { inferred == true }

    /// `redeemedAt` is the key the Codex-only receipts were written under;
    /// `~/.vibebar/subscription_history.json` is also read by older builds.
    enum CodingKeys: String, CodingKey {
        case id, occurredAt = "redeemedAt", inferred, observedAfter, clears
    }
}

/// One available credit (or one grant carrying several) as the provider
/// lists it.
public struct ResetCreditToken: Codable, Hashable, Sendable {
    /// Hash of the provider's id. Grok's token id is the handle that spends
    /// the reset, so only its digest is ever held past the parse.
    public var id: String
    /// Resets left on this grant (Claude `resets_left`; 1 per Grok token).
    public var remaining: Int
    public var expiresAt: Date?
    /// Vibe Bar bucket ids this credit clears, when the provider says.
    public var clears: [String]?

    public init(id: String, remaining: Int, expiresAt: Date?, clears: [String]? = nil) {
        self.id = id
        self.remaining = max(0, remaining)
        self.expiresAt = expiresAt
        self.clears = clears
    }
}

public extension ResetCredits {
    /// Credits whose count fell between two reads while the credit was still
    /// valid, i.e. spent rather than expired.
    ///
    /// A token that vanished is read as `remaining == 0`. One that expired
    /// at or before `now` is left out: its count falls because it lapsed.
    /// So is one with no known expiry, because nothing then separates the
    /// two. A read that failed is never passed here — a missing inventory is
    /// not an empty one — so an outage cannot look like every credit spent.
    static func inferredRedemptions(
        previous: [ResetCreditToken],
        previousObservedAt: Date,
        current: [ResetCreditToken],
        now: Date
    ) -> [ResetCreditEvent] {
        guard now > previousObservedAt else { return [] }
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var events: [ResetCreditEvent] = []
        for token in previous {
            guard let expiry = token.expiresAt, expiry > now else { continue }
            let after = currentByID[token.id]?.remaining ?? 0
            let spent = token.remaining - after
            guard spent > 0 else { continue }
            for index in 0..<spent {
                events.append(ResetCreditEvent(
                    id: PrivacyPreservingHash.fileComponent(
                        prefix: "reset-inferred",
                        rawValue: token.id + ":" + String(token.remaining - index) + ":"
                            + String(Int(now.timeIntervalSince1970))),
                    occurredAt: now, inferred: true, observedAfter: previousObservedAt,
                    clears: token.clears))
            }
        }
        return events
    }
}

/// One line of an account's credit record: a credit received or spent.
public struct ResetCreditLedgerEntry: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case used, granted }
    public var kind: Kind
    public var event: ResetCreditEvent
    public var id: String { kind.rawValue + ":" + event.id }

    public init(kind: Kind, event: ResetCreditEvent) {
        self.kind = kind
        self.event = event
    }

    /// Newest-first records per account id, built once per store change so
    /// no card derives it while rendering.
    public static func ledger(
        redemptions: [QuotaResetRedemption],
        grants: [QuotaResetRedemption]
    ) -> [String: [ResetCreditLedgerEntry]] {
        var out: [String: [ResetCreditLedgerEntry]] = [:]
        for record in redemptions {
            out[record.accountId, default: []].append(.init(kind: .used, event: record.credit))
        }
        for record in grants {
            out[record.accountId, default: []].append(.init(kind: .granted, event: record.credit))
        }
        for key in out.keys {
            out[key]?.sort { $0.event.occurredAt > $1.event.occurredAt }
        }
        return out
    }
}
