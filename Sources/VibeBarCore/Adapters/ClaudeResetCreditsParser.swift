import Foundation

/// Claude's usage-limit resets ("Resets — Reset for free" on claude.ai).
///
/// `GET /api/organizations/{org}/usage?cedar_ember=1` adds a top-level
/// `cedar_ember` object to the usage payload the web path already reads;
/// without the query parameter the key is there but `null`:
///
/// ```
/// "cedar_ember": {
///   "eligible": true, "at_limit": false, "exhausted": [],
///   "grants": [ { "id": "…", "resets_total": 1, "resets_left": 1,
///                 "starts_at": "…", "ends_at": "…",
///                 "clears": ["five_hour", "seven_day", "seven_day_overage_included"],
///                 "paused": false, "usable_now": true, … } ],
///   "next_grant_id": "…", "weekly_resets_at": "…", "cooldown_until": null }
/// ```
///
/// Claude publishes no redemption history, so each grant becomes a
/// `ResetCreditToken` and `SubscriptionHistoryStore` infers a redemption
/// when `resets_left` falls while the grant is still valid.
public enum ClaudeResetCreditsParser {
    /// `nil` when the payload carries no `cedar_ember` object (absent or
    /// `null`), so the card shows no row rather than a made-up zero.
    public static func parse(data: Data, buckets: [QuotaBucket], now: Date = Date()) -> ResetCredits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ember = root["cedar_ember"] as? [String: Any] else { return nil }
        let grants = ember["grants"] as? [[String: Any]] ?? []
        let bucketIDs = buckets.map(\.id)
        var tokens: [ResetCreditToken] = []
        var expirations: [Date] = []
        var available = 0
        for grant in grants {
            guard let rawID = grant["id"] as? String, !rawID.isEmpty,
                  let left = intValue(grant["resets_left"]) else { continue }
            let starts = parseDate(grant["starts_at"])
            let ends = parseDate(grant["ends_at"])
            let clears = (grant["clears"] as? [String] ?? []).flatMap { bucketIDsCleared(by: $0, in: bucketIDs) }
            let token = ResetCreditToken(
                id: PrivacyPreservingHash.fileComponent(prefix: "reset-grant", rawValue: rawID),
                remaining: left, expiresAt: ends, clears: clears.isEmpty ? nil : uniqued(clears))
            tokens.append(token)
            // A grant that has not opened yet or has already lapsed is not
            // a reset the user can spend now.
            let live = (starts.map { $0 <= now } ?? true) && (ends.map { $0 > now } ?? true)
            guard live, token.remaining > 0 else { continue }
            available += token.remaining
            if let ends { expirations += Array(repeating: ends, count: token.remaining) }
        }
        return ResetCredits(
            availableCount: available,
            availableExpirations: expirations.count == available ? expirations : nil,
            tokens: tokens)
    }

    /// Maps one of Claude's `clears` window names onto the bucket ids
    /// `ClaudeResponseParser` gives those windows. `seven_day_overage_included`
    /// is the per-model weekly allowance (it tracks `weekly_fable` on a Max
    /// plan), so it names every scoped weekly the account currently shows.
    static func bucketIDsCleared(by window: String, in bucketIDs: [String]) -> [String] {
        switch window {
        case "five_hour": return ["five_hour"]
        case "seven_day": return ["weekly"]
        case "seven_day_overage_included":
            return bucketIDs.filter { $0.hasPrefix("weekly_") }
        default:
            guard window.hasPrefix("seven_day_") else { return [] }
            let scoped = "weekly_" + window.dropFirst("seven_day_".count)
            return bucketIDs.contains(scoped) ? [scoped] : []
        }
    }

    private static func uniqued(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
