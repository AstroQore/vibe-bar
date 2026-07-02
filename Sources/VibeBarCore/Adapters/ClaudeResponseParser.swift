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
///   - `seven_day_fable`        → "Fable" (own section, when present)
///   - `seven_day_oauth_apps`   → "OAuth Apps" (own section, when present)
///
/// Adding a new per-model dimension is a checklist, not a one-liner: see
/// `AGENTS.md` § "Adding a new Claude usage-limit model". The
/// `ClaudeModelBucketParityTests` suite fails `swift test` if a `knownBuckets`
/// entry with a `groupTitle` has no matching menu-bar field, so the
/// correctness-critical half of that checklist is self-enforcing.
///
/// **`limits[]` (2026-07 schema).** Anthropic moved per-model limits out of
/// the legacy `seven_day_<model>` keys (which now come back `null`) into a
/// structured `limits` array whose scoped entries carry the model's display
/// name, e.g. `{"kind": "weekly_scoped", "group": "weekly", "percent": 1,
/// "scope": {"model": {"display_name": "Fable"}}}`. `parseLimitsArray`
/// surfaces every scoped entry as its own section and derives the bucket id
/// from the display name (`Fable` → `weekly_fable`), so a brand-new model
/// shows up in the popover with zero code changes; the checklist above is
/// then only needed to make it selectable in the menu bar / mini window.
/// Legacy keys still win when both are present, keeping ids stable.
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
        .init(key: "seven_day_fable", id: "weekly_fable", title: "Weekly", shortLabel: "Fable wk", windowSeconds: 604_800, groupTitle: "Fable"),
        .init(key: "seven_day_oauth_apps", id: "weekly_oauth_apps", title: "Weekly", shortLabel: "OAuth wk", windowSeconds: 604_800, groupTitle: "OAuth Apps")
    ]

    /// Bucket ids for Claude's per-model weekly dimensions — every
    /// `knownBuckets` entry that carries a `groupTitle`. Exposed read-only so
    /// `ClaudeModelBucketParityTests` can assert the menu-bar field catalog
    /// stays in lockstep with the parser: adding a model here without a
    /// matching `MenuBarFieldCatalog.claudeFields` entry fails the suite.
    public static var perModelBucketIDs: [String] {
        knownBuckets.compactMap { $0.groupTitle == nil ? nil : $0.id }
    }

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

        appendLimitsArrayBuckets(from: root, to: &out)

        if let routine = routineBucket(from: root) {
            out.append(routine)
        }

        if out.isEmpty {
            throw QuotaError.parseFailure("no recognized buckets")
        }
        return out
    }

    // MARK: - `limits[]` array (2026-07 schema)

    /// Surface entries of the structured `limits` array that the legacy
    /// top-level keys no longer carry. Scoped entries (per-model / per-surface)
    /// each get their own section; headline `session` / `weekly_all` entries
    /// are used only as a fallback when the legacy `five_hour` / `seven_day`
    /// keys are missing, so ids stay stable during Anthropic's migration.
    private static func appendLimitsArrayBuckets(
        from root: [String: Any],
        to out: inout [QuotaBucket]
    ) {
        guard let rawEntries = root["limits"] as? [Any] else { return }
        let entries = rawEntries.compactMap { $0 as? [String: Any] }
        var existingIDs = Set(out.map(\.id))
        for entry in entries {
            guard let percent = numberValue(entry["percent"])
                ?? numberValue(entry["utilization"])
            else { continue }
            let kind = (entry["kind"] as? String) ?? ""
            let group = (entry["group"] as? String) ?? kind
            let resetDate = parseDate(entry["resets_at"]) ?? parseDate(entry["reset_at"])
            let isSession = group == "session"
            let windowSeconds = isSession ? 18_000 : 604_800
            let idPrefix = isSession ? "session" : "weekly"

            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let scopeName = ((model?["display_name"] as? String)
                ?? (scope?["surface"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let bucket: QuotaBucket
            if let scopeName, !scopeName.isEmpty {
                // Scoped limit → its own section, id derived from the name so
                // known models land on their existing ids (Fable →
                // weekly_fable) and unknown ones still render via groupTitle.
                let id = "\(idPrefix)_\(slug(scopeName))"
                guard !existingIDs.contains(id) else { continue }
                bucket = QuotaBucket(
                    id: id,
                    title: isSession ? "5 Hours" : "Weekly",
                    shortLabel: isSession ? "\(scopeName) 5h" : "\(scopeName) wk",
                    usedPercent: percent,
                    resetAt: resetDate,
                    rawWindowSeconds: windowSeconds,
                    groupTitle: scopeName
                )
            } else if group == "session" || group == "weekly" {
                // Headline limit — fallback only, legacy keys win.
                let id = isSession ? "five_hour" : "weekly"
                guard !existingIDs.contains(id) else { continue }
                bucket = QuotaBucket(
                    id: id,
                    title: isSession ? "5 Hours" : "Weekly",
                    shortLabel: isSession ? "5h" : "All models",
                    usedPercent: percent,
                    resetAt: resetDate,
                    rawWindowSeconds: windowSeconds,
                    groupTitle: nil
                )
            } else {
                continue
            }
            existingIDs.insert(bucket.id)
            out.append(bucket)
        }
    }

    /// "Fable" → "fable", "Opus 4.8" → "opus_4_8". Keeps derived bucket ids
    /// aligned with the legacy `weekly_<model>` naming.
    private static func slug(_ name: String) -> String {
        let scalars = name.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        var result = ""
        for ch in scalars {
            if ch == "_", result.last == "_" { continue }
            result.append(ch)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
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
            // Only surface Daily Routines when the alias carries a real
            // utilization number. A present-but-null key (e.g.
            // `"seven_day_cowork": null`) must not synthesize a misleading
            // "0% used" routines section — Claude dropped Daily Routines from
            // the usage payload, so absence means "don't show it".
            guard let entry = root[key] as? [String: Any] else { continue }
            guard let utilization = numberValue(entry["utilization"])
                ?? numberValue(entry["used_percent"])
            else { continue }
            let resetDate = parseDate(entry["resets_at"])
                ?? parseDate(entry["reset_at"])
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
