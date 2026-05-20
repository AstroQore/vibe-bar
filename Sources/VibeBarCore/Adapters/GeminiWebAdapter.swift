import Foundation

/// Fetches Gemini usage data from the signed-in `gemini.google.com`
/// web session via imported browser cookies.
///
/// **Spike-pending**: the exact endpoint, request body, anti-hijacking
/// envelope, and required `Authorization: SAPISIDHASH` header are not
/// covered by public Google documentation. The placeholder
/// implementation here intentionally fails fast with `.needsLogin`
/// when the cookie store is empty (so the UI shows "Import cookies"),
/// and otherwise throws `.parseFailure` with a developer-facing hint
/// to flip `GeminiWebQuotaFetcher.spikeComplete` and fill in the
/// real request once the spike (see plan §9) is done. This keeps the
/// dedicated-card UI shippable today without forging protocol details.
struct GeminiWebQuotaFetcher: Sendable {
    /// Flip to `true` once `gemini.google.com/usage` reverse-engineering
    /// is complete and the wire shape is locked in.
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
            // Surface a clear maintenance-time hint instead of a
            // generic network error. The dedicated card will fall
            // through to the OAuth source when the planner allows.
            throw QuotaError.parseFailure(
                "Gemini Web source is awaiting the gemini.google.com/usage spike. See plan §9."
            )
        }
        // Spike-completed implementation lives here. Expected shape:
        //   1. Build URLRequest against the confirmed endpoint
        //      (likely under gemini.google.com/_/...).
        //   2. Apply minimum cookie header + SAPISIDHASH if required.
        //   3. Strip `)]}'\n` anti-hijacking prefix from the response.
        //   4. Delegate JSON parsing to GeminiWebResponseParser.parse(_:).
        throw QuotaError.parseFailure("Gemini Web fetch not implemented yet.")
    }
}
