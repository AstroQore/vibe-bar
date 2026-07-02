import Foundation

/// Parses the JSON envelope returned by Gemini's signed-in web
/// quota endpoint (rpcid `jSf9Qc` on
/// `gemini.google.com/_/BardChatUi/data/batchexecute`) into the
/// shared `GeminiResponseParser.Snapshot` shape.
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
enum GeminiWebResponseParser {
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
    static let currentUsageBucketId = "five_hour"
    static let weeklyUsageBucketId  = "weekly"

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

    static func parse(
        data: Data,
        email: String? = nil,
        now: Date = Date()
    ) throws -> GeminiResponseParser.Snapshot {
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
        // `["wrb.fr","jSf9Qc","` and the `"`-terminator immediately
        // before `,null` — handling escape sequences so a `\"` inside
        // the payload doesn't end the match early.
        let pattern = #"\["wrb\.fr","jSf9Qc","((?:[^"\\]|\\.)*)",null"#
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
            throw QuotaError.parseFailure("Gemini Web response did not contain a jSf9Qc payload entry.")
        }
        let innerEscaped = ns.substring(with: match.range(at: 1))
        // Captured string is JSON-encoded inside the outer JSON. Wrap
        // it in quotes and re-decode to get the raw payload JSON.
        let wrapped = "\"" + innerEscaped + "\""
        guard let wrappedData = wrapped.data(using: .utf8),
              let innerJsonString = (try? JSONSerialization.jsonObject(
                with: wrappedData, options: [.allowFragments])) as? String,
              let innerData = innerJsonString.data(using: .utf8) else {
            throw QuotaError.parseFailure("Gemini Web jSf9Qc inner payload could not be unescaped.")
        }
        let outer: [Any]
        do {
            guard let arr = try JSONSerialization.jsonObject(with: innerData) as? [Any] else {
                throw QuotaError.parseFailure("Gemini Web jSf9Qc inner payload not an array.")
            }
            outer = arr
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("Gemini Web jSf9Qc inner payload not parseable: \(error.localizedDescription)")
        }
        guard outer.count >= 2, let bucketsRaw = outer[1] as? [[Any]] else {
            throw QuotaError.parseFailure("Gemini Web jSf9Qc payload missing bucket array.")
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
            throw QuotaError.parseFailure("Gemini Web jSf9Qc returned no buckets.")
        }
        return GeminiResponseParser.Snapshot(buckets: buckets, planName: planName, email: email)
    }

    /// Map Google's `planTier` integer to the user-visible plan label.
    /// Confirmed `2 = "Pro"` (Google AI Pro). `1 = Free` / `3 = Ultra`
    /// are inferred from Google's published tier names and the
    /// "20x more usage than AI Pro" upgrade banner — adjust when a
    /// real Ultra or Free account becomes available for verification.
    static func planLabel(forTierId id: Int) -> String? {
        switch id {
        case 1: return "Free"
        case 2: return "Pro"
        case 3: return "Ultra"
        default: return nil
        }
    }

    // MARK: - Helpers

    private struct BucketDescriptor {
        let id: String
        let title: String
        let shortLabel: String
        /// Fixed window length for `UsagePace`. Google's jSf9Qc payload
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
