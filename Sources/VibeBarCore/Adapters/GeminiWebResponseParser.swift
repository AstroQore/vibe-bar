import Foundation

/// Parses the JSON envelope returned by Gemini's signed-in web usage
/// endpoint into the shared `GeminiResponseParser.Snapshot` shape so the
/// `GeminiQuotaAdapter` produces an identical `AccountQuota` regardless
/// of which credential source won.
///
/// **Spike-pending**: the exact field names and per-model layout are
/// not covered by public Google documentation. Treat this file as the
/// home for the wire-shape decoder once the spike is complete.
enum GeminiWebResponseParser {
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
        // Spike-completed shape decoding goes here. Expect either:
        //   * per-model buckets (Pro / Flash / Flash-Lite / Deep
        //     Research / Veo), each with `usedPercent` + `resetTime`;
        //   * or a single aggregate "compute usage" percentage — emit
        //     one bucket with id `gemini.web.compute` and no
        //     `groupTitle` in that case.
        // For now, signal a clear parse failure so the adapter falls
        // through to the OAuth source and the UI shows a maintenance
        // hint rather than a misleading "everything is fine" card.
        _ = stripped
        throw QuotaError.parseFailure(
            "Gemini Web response parser not implemented yet (awaiting spike, see plan §9)."
        )
    }
}
