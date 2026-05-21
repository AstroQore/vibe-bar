import Foundation

/// Fetches Gemini usage data from the signed-in `gemini.google.com`
/// web session via imported browser cookies.
///
/// **Spike-pending — endpoint not yet identified.**
///
/// Investigation summary (2026-05-22, against a live PRO account):
/// - Loading `/usage?pli=1` triggers **eight** `batchexecute` POST
///   requests with rpcids `MaZiqc`, `L5adhe`, `Bsxleb`, `GPRiHf`,
///   `maGuAc`, `Te6DCf`, `CNgdBe`, plus a repeat `MaZiqc`. **None**
///   of them returned the per-usage quota numbers — they cover
///   chats list, bootstrap flags, feature flags, an upgrade promo
///   banner, and the Gems library. So `gemini.google.com/usage`
///   does NOT lay its quota data through batchexecute.
/// - The SSR HTML response (≈ 690 KB) contains no `"% used"`
///   literal, no `AF_initDataCallback` chunk with quota fields, and
///   no quota numbers in `WIZ_global_data` either.
/// - The two visible buckets ("Current usage" + "Weekly limit",
///   percentage + reset timestamps) are rendered by the
///   `<usage-metrics-window>` Angular component into
///   `.gxu-currently-luminous` / `.gxu-items-container` divs. The
///   data source has to be either a non-batchexecute endpoint or
///   an inlined-but-encoded blob that the spike has not yet
///   recovered.
///
/// Until the real endpoint is identified, this fetcher throws a
/// `.parseFailure` with a clear maintenance hint. The dedicated
/// "Gemini Web" card stays visible (so the cookie import + delete
/// flow is exercisable) but shows the error message until the
/// spike lands and `spikeComplete` flips.
///
/// XSRF: replays observed `at=AOOh0P...` tokens 400 with `xsrf`
/// errors that *include* the right token in the response — the
/// server hands back a usable XSRF on every error, so the future
/// fetch path can probe `L5adhe` once, grab the token from the
/// error envelope, and retry. The anti-hijacking prefix `)]}'\n`
/// is consistent across all responses observed.
struct GeminiWebQuotaFetcher: Sendable {
    /// Flip to `true` once `gemini.google.com/usage`
    /// reverse-engineering identifies the real quota endpoint and
    /// `GeminiWebResponseParser.parse(_:)` can decode it.
    static let spikeComplete = false

    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    func fetch(cookieHeader: String, email: String? = nil) async throws -> GeminiResponseParser.Snapshot {
        guard !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuotaError.noCredential
        }
        guard Self.spikeComplete else {
            throw QuotaError.parseFailure(
                "Gemini Web spike incomplete: gemini.google.com/usage quota endpoint not yet identified. See GeminiWebAdapter.swift header for the 2026-05-22 investigation summary."
            )
        }
        // Spike-completed implementation lives here. Expected shape:
        //   1. Build URLRequest against the confirmed endpoint.
        //   2. Apply minimum cookie header + SAPISIDHASH if required.
        //   3. Strip `)]}'\n` anti-hijacking prefix from the response
        //      (helper already in GeminiWebResponseParser).
        //   4. Delegate JSON parsing to GeminiWebResponseParser.parse(_:)
        //      — expected to emit exactly two buckets, "current" and
        //      "weekly", matching the page UI 1:1.
        throw QuotaError.parseFailure("Gemini Web fetch not implemented yet.")
    }
}
