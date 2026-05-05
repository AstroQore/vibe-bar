import Foundation

/// Pure parser for the Anthropic `/api/oauth/usage` response.
///
/// Each Claude usage dimension is rendered as its own labeled section in the
/// popover (mirroring how Codex shows GPT-5.3 Codex Spark in its own column).
/// Today's known dimensions:
///   - `five_hour`              → "5 Hours" (rolling 5h, headline)
///   - `seven_day`              → "Weekly" / All Models (headline)
///   - `seven_day_sonnet`       → "Sonnet" (own section)
///   - `seven_day_omelette`     → "Designs" (own section)
///   - `seven_day_opus`         → "Opus" (own section, when present)
///   - `seven_day_oauth_apps`   → "OAuth Apps" (own section, when present)
///
/// Daily Routines has a dedicated endpoint — see `ClaudeRoutinesFetcher` and
/// `ClaudeQuotaAdapter` — but the OAuth/Web usage payload also exposes a set of
/// routine aliases on some accounts. We keep that as a visible fallback so the
/// Claude card still shows a Daily Routines section even when the separate web
/// budget endpoint rejects a stale browser cookie.
public enum ClaudeResponseParser {
    private struct BucketSpec {
        let key: String
        let id: String
        let title: String
        let shortLabel: String
        let windowSeconds: Int?
        let groupTitle: String?
    }

    /// The Claude APIs rotate through several aliases for the same logical
    /// bucket. We list the primary key here and the parser also tries known
    /// aliases.
    ///
    /// Order matters: when a single payload key matches both a top-level spec
    /// and an alias for another spec, the first match in this array wins.
    private static let knownBuckets: [BucketSpec] = [
        .init(key: "five_hour", id: "five_hour", title: "5 Hours", shortLabel: "5h", windowSeconds: 18_000, groupTitle: nil),
        .init(key: "seven_day", id: "weekly", title: "Weekly", shortLabel: "All models", windowSeconds: 604_800, groupTitle: nil),
        // Each model dimension below gets its own section, matching the
        // OpenAI layout (main / Spark / etc.).
        .init(key: "seven_day_sonnet", id: "weekly_sonnet", title: "Weekly", shortLabel: "Sonnet wk", windowSeconds: 604_800, groupTitle: "Sonnet"),
        .init(key: "seven_day_omelette", id: "weekly_design", title: "Weekly", shortLabel: "Designs", windowSeconds: 604_800, groupTitle: "Designs"),
        .init(key: "seven_day_opus", id: "weekly_opus", title: "Weekly", shortLabel: "Opus wk", windowSeconds: 604_800, groupTitle: "Opus"),
        .init(key: "seven_day_oauth_apps", id: "weekly_oauth_apps", title: "Weekly", shortLabel: "OAuth wk", windowSeconds: 604_800, groupTitle: "OAuth Apps"),
        .init(key: "iguana_necktie", id: "iguana_necktie", title: "Weekly", shortLabel: "Iguana wk", windowSeconds: 604_800, groupTitle: "Iguana")
    ]

    /// Aliases the API may use for the same logical key. Tried in order.
    private static let bucketAliases: [String: [String]] = [
        "seven_day_omelette": ["seven_day_design", "seven_day_claude_design", "claude_design", "design", "omelette", "omelette_promotional"]
    ]

    private static let routineAliases = [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork"
    ]

    public static func parse(data: Data) throws -> [QuotaBucket] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw QuotaError.parseFailure("invalid json")
        }
        guard let root = json as? [String: Any] else {
            throw QuotaError.parseFailure("root is not an object")
        }

        var out: [QuotaBucket] = []
        for spec in knownBuckets {
            let candidateKeys = [spec.key] + (bucketAliases[spec.key] ?? [])
            var entry: [String: Any]? = nil
            for key in candidateKeys {
                if let dict = root[key] as? [String: Any] {
                    entry = dict
                    break
                }
            }
            guard let entry else { continue }
            guard let utilization = Self.numberValue(entry["utilization"])
                                       ?? Self.numberValue(entry["used_percent"])
            else { continue }
            let resetDate = Self.parseDate(entry["resets_at"])
                ?? Self.parseDate(entry["reset_at"])
            out.append(QuotaBucket(
                id: spec.id,
                title: spec.title,
                shortLabel: spec.shortLabel,
                usedPercent: utilization,
                resetAt: resetDate,
                rawWindowSeconds: spec.windowSeconds,
                groupTitle: spec.groupTitle
            ))
        }

        if let routine = routineBucket(from: root) {
            out.append(routine)
        }

        if out.isEmpty {
            throw QuotaError.parseFailure("no recognized buckets")
        }
        return out
    }

    /// Pull the raw `extra_usage` block out of the OAuth usage response so the
    /// live extras pipeline can surface spend / limit / utilization. The API
    /// returns amounts in **cents** (minor units), so we divide by 100 here.
    ///
    /// Returns nil when the field is missing or has no usable numeric value.
    public static func parseExtraUsage(data: Data) -> ProviderExtras? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return nil }
        guard let extra = json["extra_usage"] as? [String: Any] else { return nil }
        // Anthropic's actual key set:
        //   `is_enabled` (Bool), `monthly_limit` (cents), `used_credits` (cents),
        //   `utilization` (0-100), `currency`. Older / web aliases included as
        //   defensive fallbacks in case the schema rotates again.
        let usedCents = Self.numberValue(extra["used_credits"])
            ?? Self.numberValue(extra["amount_used"])
            ?? Self.numberValue(extra["spend"])
            ?? Self.numberValue(extra["used"])
        let limitCents = Self.numberValue(extra["monthly_limit"])
            ?? Self.numberValue(extra["amount_limit"])
            ?? Self.numberValue(extra["limit"])
            ?? Self.numberValue(extra["cap"])
        let enabled = (extra["is_enabled"] as? Bool)
            ?? (extra["enabled"] as? Bool)
            ?? (usedCents != nil)
        // Convert from cents to dollars to match the rest of the app.
        let spendUSD = usedCents.map { $0 / 100.0 }
        let limitUSD = limitCents.map { $0 / 100.0 }
        guard spendUSD != nil || limitUSD != nil || enabled else { return nil }
        return ProviderExtras(
            tool: .claude,
            creditsRemainingUSD: nil,
            creditsTopupURL: nil,
            extraUsageSpendUSD: spendUSD,
            extraUsageLimitUSD: limitUSD,
            extraUsageEnabled: enabled
        )
    }

    private static func numberValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double:   return d
        case let i as Int:      return Double(i)
        case let s as String:   return Double(s)
        default:                return nil
        }
    }

    private static func routineBucket(from root: [String: Any]) -> QuotaBucket? {
        for key in routineAliases {
            guard root.keys.contains(key) else { continue }
            let entry = root[key] as? [String: Any]
            let utilization = numberValue(entry?["utilization"])
                ?? numberValue(entry?["used_percent"])
                ?? 0
            let resetDate = parseDate(entry?["resets_at"])
                ?? parseDate(entry?["reset_at"])
            return QuotaBucket(
                id: "daily_routines",
                title: "Weekly",
                shortLabel: "Routine wk",
                usedPercent: utilization,
                resetAt: resetDate,
                rawWindowSeconds: 604_800,
                groupTitle: "Daily Routines"
            )
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            return isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
        }
        if let n = numberValue(any) {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }

}
