import Foundation

/// Parses the JSON envelope returned by Gemini's signed-in web usage
/// endpoint into the shared `GeminiResponseParser.Snapshot` shape.
///
/// **Spike-pending — wire shape not yet captured.**
///
/// What the live page renders (confirmed by direct DOM inspection
/// of a PRO account, 2026-05-22):
/// - One "Current usage" bar — a single percentage + a "Resets at HH:MM AM/PM" line.
/// - One "Weekly limit" bar — same shape, "Resets <Date> at HH:MM AM/PM".
/// - A plan badge in the page header — "PRO" / "FREE" / etc.
/// So whenever the spike yields a real response, this parser is
/// expected to emit exactly two `QuotaBucket`s (ids `gemini.web.current`
/// and `gemini.web.weekly`), plus the plan name on `Snapshot.planName`.
///
/// `stripAntiHijackingPrefix` is ready to use — every observed
/// `gemini.google.com` response starts with `)]}'\n` followed by a
/// length-prefixed chunked JSON stream. See the file-level docs on
/// `GeminiWebQuotaFetcher` for the investigation notes.
enum GeminiWebResponseParser {
    /// Bucket ids the parser will emit once the spike is complete.
    static let currentUsageBucketId = "gemini.web.current"
    static let weeklyUsageBucketId  = "gemini.web.weekly"

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
        _ = stripped
        throw QuotaError.parseFailure(
            "Gemini Web response parser not implemented yet — expected two buckets (current + weekly) once the spike completes. See GeminiWebAdapter.swift for investigation notes."
        )
    }
}
