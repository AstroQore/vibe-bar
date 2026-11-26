import Foundation

/// Parsed Gemini Web quota data shared with the App-layer WebView
/// calibrator without exposing the internal wire envelope.
public struct GeminiWebQuotaSnapshot: Sendable {
    public var buckets: [QuotaBucket]
    public var planName: String?
    public var email: String?

    public init(buckets: [QuotaBucket], planName: String?, email: String?) {
        self.buckets = buckets
        self.planName = planName
        self.email = email
    }
}

/// Parses the JSON envelope returned by Gemini's signed-in web
/// quota endpoint (a dynamically learned batchexecute rpcid on
/// `gemini.google.com/_/BardChatUi/data/batchexecute`) into the
/// shared `GeminiWebQuotaSnapshot` shape.
///
/// Wire format (see the file-level docs on `GeminiWebQuotaFetcher`
/// for the upstream investigation):
/// - Outer body is Google's JSONP-prefixed chunked stream
///   (`)]}'\n` + lengths + JSON chunks). `stripAntiHijackingPrefix`
///   strips the prefix and the regex below isolates the `wrb.fr`
///   payload entry without needing a full chunk parser.
/// - Inner payload (once decoded — once for the outer envelope and
///   once for the inner string-escaped JSON) is shaped:
///     `[planTier, [<bucket>, <bucket>, ...], <flag>]`
///   where each `<bucket>` is
///     `[remaining, usedFraction, type, [[reset_sec, reset_ns]]]`.
///   `type=1` is the daily/current window and `type=2` is the
///   weekly window. `planTier` is an integer that maps to the
///   user-visible plan name (`2 = Pro` confirmed; `1 = Free` and
///   `3 = Ultra` inferred from Google's published tier names).
public enum GeminiWebResponseParser {
    /// Bucket ids the parser emits. Aligned with Codex's
    /// `five_hour` / `weekly` naming so the Overview/MiniWindow
    /// label catalog can share field-id conventions across providers
    /// instead of per-tool quirks. The label "5 Hours" matches the
    /// shorter-window bucket regardless of the exact reset cadence
    /// Google ships — Gemini's type=1 quota refreshes roughly every
    /// 4-6 hours in practice, close enough to Codex's 5h primary
    /// that the shared label is more useful than a brand-new one.
    // Bucket IDs follow the Codex / Claude convention — plain
    // `"five_hour"` / `"weekly"` strings, no `gemini.` prefix. The
    // tool namespace is implicit (these buckets only live on a
    // `.gemini` quota) and `MenuBarFieldCatalog.fieldId(tool:bucketId:)`
    // adds the prefix back when composing field ids, so the catalog
    // entry `option(.gemini, "five_hour", ...)` ends up with the
    // same `gemini.five_hour` field id user settings already store
    // — which is what `MiniQuotaWindowView` looks up against
    // `field.bucketId` on the live quota.
    public static let currentUsageBucketId = "five_hour"
    public static let weeklyUsageBucketId  = "weekly"

    /// Strip Google's anti-hijacking prefix `)]}'` (with or without a
    /// trailing newline) that fronts most internal JSON RPCs.
    static func stripAntiHijackingPrefix(_ data: Data) -> Data {
        let prefix = Data(")]}'".utf8)
        guard data.starts(with: prefix) else { return data }
        var idx = data.index(data.startIndex, offsetBy: prefix.count)
        while idx < data.endIndex {
            let byte = data[idx]
            if byte == 0x0A || byte == 0x0D { // \n or \r
                idx = data.index(after: idx)
            } else {
                break
            }
        }
        return data.subdata(in: idx..<data.endIndex)
    }

    public static func parse(
        data: Data,
        rpcID: String = GeminiWebUsageRecipe.fallback.rpcID,
        email: String? = nil,
        now: Date = Date()
    ) throws -> GeminiWebQuotaSnapshot {
        let stripped = stripAntiHijackingPrefix(data)
        guard !stripped.isEmpty else {
            throw QuotaError.parseFailure("Gemini Web response was empty after stripping anti-hijacking prefix.")
        }
        guard let text = String(data: stripped, encoding: .utf8) else {
            throw QuotaError.parseFailure("Gemini Web response not UTF-8.")
        }
        // The chunked stream is `<len>\n<json>\n<len>\n<json>...`.
        // The `wrb.fr` entry we want sits inside one of those JSON
        // chunks. The regex captures the JSON-encoded string between
        // `["wrb.fr","<rpcid>","` and the `"`-terminator immediately
        // before `,null` — handling escape sequences so a `\"` inside
        // the payload doesn't end the match early.
        let escapedRPCId = NSRegularExpression.escapedPattern(for: rpcID)
        let pattern = #"\["wrb\.fr","\#(escapedRPCId)","((?:[^"\\]|\\.)*)",null"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            throw QuotaError.parseFailure("Gemini Web parser regex failed to compile.")
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 2 else {
            throw QuotaError.parseFailure(
                "Gemini Web response did not contain an \(rpcID) payload entry."
            )
        }
        let innerEscaped = ns.substring(with: match.range(at: 1))
        // Captured string is JSON-encoded inside the outer JSON. Wrap
        // it in quotes and re-decode to get the raw payload JSON.
        let wrapped = "\"" + innerEscaped + "\""
        guard let wrappedData = wrapped.data(using: .utf8),
              let innerJsonString = (try? JSONSerialization.jsonObject(
                with: wrappedData, options: [.allowFragments])) as? String,
              let innerData = innerJsonString.data(using: .utf8) else {
            throw QuotaError.parseFailure("Gemini Web quota inner payload could not be unescaped.")
        }
        let outer: [Any]
        do {
            guard let arr = try JSONSerialization.jsonObject(with: innerData) as? [Any] else {
                throw QuotaError.parseFailure("Gemini Web quota inner payload not an array.")
            }
            outer = arr
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("Gemini Web quota inner payload not parseable: \(error.localizedDescription)")
        }
        guard outer.count >= 2, let bucketsRaw = outer[1] as? [[Any]] else {
            throw QuotaError.parseFailure("Gemini Web quota payload missing bucket array.")
        }
        let planTier = intValue(outer.first ?? 0)
        let planName = planLabel(forTierId: planTier)

        var buckets: [QuotaBucket] = []
        for entry in bucketsRaw {
            guard entry.count >= 4 else { continue }
            let usedFraction = doubleValue(entry[1])
            let bucketType = intValue(entry[2])
            let resetAt = extractResetDate(from: entry[3])
            let descriptor = bucketDescriptor(forType: bucketType)
            // The live Ultra payload currently includes an internal type-4
            // sentinel with no reset timestamp. It is not rendered on the
            // Gemini Usage page and is not a resettable user quota, so don't
            // turn it into a misleading "Bucket 4" meter. Future unknown
            // buckets with a real reset remain visible through the generic
            // fallback below.
            if descriptor.windowSeconds == nil, resetAt == nil { continue }
            let usedPercent = min(100, max(0, usedFraction * 100))
            buckets.append(QuotaBucket(
                id: descriptor.id,
                title: descriptor.title,
                shortLabel: descriptor.shortLabel,
                usedPercent: usedPercent,
                resetAt: resetAt,
                rawWindowSeconds: descriptor.windowSeconds,
                groupTitle: nil
            ))
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Gemini Web quota payload returned no buckets.")
        }
        // Google's bucket array is not stable across refreshes: live
        // responses may list the weekly window before the shorter current
        // window. Every Gemini surface renders this array directly, so lock
        // the user-facing cadence to 5 Hours -> Weekly and keep any future
        // unknown buckets after the two known windows.
        buckets = canonicalBucketOrder(buckets)
        return GeminiWebQuotaSnapshot(buckets: buckets, planName: planName, email: email)
    }

    /// The English usage page renders each percentage and reset time in
    /// its own labelled list item. Accept a snapshot only when both rows
    /// describe a plausible current window in the page's local time zone.
    public static func renderedUsage(rows: [String], plan: String?, now: Date, timeZone: TimeZone) -> GeminiWebQuotaSnapshot? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var buckets: [QuotaBucket] = []
        for (type, label) in [(1, "Current usage"), (2, "Weekly limit")] {
            let matches = rows.filter { $0.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) == label }
            guard matches.count == 1, let row = matches.first,
                  let percent = row.firstMatch(of: #/\b(\d{1,3}(?:\.\d+)?)% used\b/#),
                  let used = Double(percent.1), (0...100).contains(used),
                  let reset = row.firstMatch(of: #/Resets (?:([A-Z][a-z]{2}) (\d{1,2}) )?at (\d{1,2}):(\d{2}) (AM|PM)/#),
                  let hour = Int(reset.3), (1...12).contains(hour),
                  let minute = Int(reset.4), (0..<60).contains(minute) else { return nil }
            var parts = DateComponents(hour: hour % 12 + (reset.5 == "PM" ? 12 : 0), minute: minute, second: 0)
            if let month = reset.1, let day = reset.2 {
                let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                guard let index = months.firstIndex(of: String(month)), let day = Int(day) else { return nil }
                parts.month = index + 1
                parts.day = day
            }
            let descriptor = bucketDescriptor(forType: type)
            guard let date = calendar.nextDate(after: now.addingTimeInterval(-59), matching: parts, matchingPolicy: .strict),
                  let duration = descriptor.windowSeconds, date.timeIntervalSince(now) <= Double(duration) + 60 else { return nil }
            buckets.append(QuotaBucket(id: descriptor.id, title: descriptor.title, shortLabel: descriptor.shortLabel,
                                       usedPercent: used, resetAt: date, rawWindowSeconds: duration))
        }
        return GeminiWebQuotaSnapshot(buckets: buckets, planName: plan, email: nil)
    }

    /// Normalize both fresh responses and persisted caches. Older cache files
    /// may retain the server's weekly-first order even after a protocol change
    /// prevents an immediate refresh; every surface should still render the
    /// shorter current window before Weekly.
    static func canonicalBucketOrder(_ buckets: [QuotaBucket]) -> [QuotaBucket] {
        buckets.sorted { lhs, rhs in
            let lhsRank = displayRank(forBucketId: lhs.id)
            let rhsRank = displayRank(forBucketId: rhs.id)
            return lhsRank == rhsRank ? lhs.id < rhs.id : lhsRank < rhsRank
        }
    }

    /// Map Google's `planTier` integer to the user-visible plan label.
    /// `2 = Pro`; the current live Ultra response uses tier id `6`.
    /// Older captures used `3` for Ultra, so retain that alias.
    /// Parse the `UsagePageQuery` GraphQL answer:
    /// `[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":…,
    /// "pools":[{"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.0,
    /// "gxu":{"windowRefreshesAt":"…"}}]}}}}}]`. `percentageUsed` is a
    /// fraction. A null `viewer`, or an HTML body, is a signed-out session.
    static func parseUsagePageQuery(data: Data, email: String?) throws -> GeminiWebQuotaSnapshot {
        let body = stripAntiHijackingPrefix(data)
        if body.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "<") {
            throw QuotaError.needsLogin
        }
        let drift = QuotaError.parseFailure("Gemini usage query response changed.")
        guard let results = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]],
              let result = results.compactMap({ $0["data"] as? [String: Any] }).first(where: { $0["viewer"] != nil })
        else { throw drift }
        guard let viewer = result["viewer"] as? [String: Any] else {
            if result["viewer"] is NSNull { throw QuotaError.needsLogin }
            throw drift
        }
        guard let usage = (viewer["rpcs"] as? [String: Any])?["getUsageInfo"] as? [String: Any],
              let pools = usage["pools"] as? [[String: Any]] else { throw drift }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var buckets: [QuotaBucket] = []
        for (poolType, bucketType) in [("GXU_FIVE_HOURLY", 1), ("GXU_WEEKLY", 2)] {
            guard let pool = pools.first(where: { $0["poolType"] as? String == poolType }),
                  let used = (pool["percentageUsed"] as? NSNumber)?.doubleValue, used.isFinite, used >= 0
            else { continue }
            let descriptor = bucketDescriptor(forType: bucketType)
            let rawReset = (pool["gxu"] as? [String: Any])?["windowRefreshesAt"] as? String
            buckets.append(QuotaBucket(
                id: descriptor.id,
                title: descriptor.title,
                shortLabel: descriptor.shortLabel,
                usedPercent: min(100, used * 100),
                resetAt: rawReset.flatMap { formatter.date(from: $0) ?? plain.date(from: $0) },
                rawWindowSeconds: descriptor.windowSeconds,
                groupTitle: nil
            ))
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Gemini usage query returned no usage windows.")
        }
        return GeminiWebQuotaSnapshot(
            buckets: buckets,
            planName: planLabel(forSubscriptionTier: usage["subscriptionTier"] as? String),
            email: email
        )
    }

    static func planLabel(forSubscriptionTier tier: String?) -> String? {
        switch tier {
        case "TIER1": return "Pro"
        case "TIER_NEON": return "Ultra"
        default: return nil
        }
    }

    static func planLabel(forTierId id: Int) -> String? {
        switch id {
        case 1: return "Free"
        case 2: return "Pro"
        case 3, 6: return "Ultra"
        default: return nil
        }
    }

    // MARK: - Helpers

    private struct BucketDescriptor {
        let id: String
        let title: String
        let shortLabel: String
        /// Fixed window length for `UsagePace`. Google's quota payload
        /// carries reset timestamps but no window duration, so the two
        /// known bucket types get the same 5h / 7d constants Codex and
        /// Claude use. Unknown types stay nil (no pace caption).
        let windowSeconds: Int?
    }

    private static func bucketDescriptor(forType type: Int) -> BucketDescriptor {
        switch type {
        case 1:
            return BucketDescriptor(id: currentUsageBucketId, title: "5 Hours", shortLabel: "5h", windowSeconds: 18_000)
        case 2:
            return BucketDescriptor(id: weeklyUsageBucketId,  title: "Weekly",  shortLabel: "Wk", windowSeconds: 604_800)
        default:
            return BucketDescriptor(
                id: "gemini.bucket\(type)",
                title: "Bucket \(type)",
                shortLabel: "B\(type)",
                windowSeconds: nil
            )
        }
    }

    private static func displayRank(forBucketId id: String) -> Int {
        switch id {
        case currentUsageBucketId: return 0
        case weeklyUsageBucketId: return 1
        default: return 2
        }
    }

    private static func intValue(_ v: Any) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func doubleValue(_ v: Any) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func extractResetDate(from any: Any) -> Date? {
        // The reset wrapper is shaped `[[reset_sec, reset_ns]]`.
        if let outer = any as? [Any], let pair = outer.first as? [Any], pair.count >= 1 {
            let secs = doubleValue(pair[0])
            let nanos = pair.count >= 2 ? doubleValue(pair[1]) : 0
            if secs > 0 {
                return Date(timeIntervalSince1970: secs + nanos / 1_000_000_000)
            }
        }
        // Defensive: also accept `[sec, ns]` without the extra nesting.
        if let pair = any as? [Any], pair.count >= 1 {
            let secs = doubleValue(pair[0])
            let nanos = pair.count >= 2 ? doubleValue(pair[1]) : 0
            if secs > 0 {
                return Date(timeIntervalSince1970: secs + nanos / 1_000_000_000)
            }
        }
        return nil
    }
}
