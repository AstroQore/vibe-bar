import Foundation

/// Google Gemini partial-primary usage adapter.
///
/// Live quota is intentionally Web-only: imported `gemini.google.com`
/// cookies are routed through `GeminiWebQuotaFetcher`. Local Gemini CLI
/// telemetry and chat-history files still feed historical cost/usage
/// scanning, but `~/.gemini/oauth_creds.json` is no longer used for
/// quota fetching.
public struct GeminiQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .gemini

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let cookieHeader: @Sendable () throws -> String
    private let browserCookieImporter: @Sendable () -> GeminiBrowserCookieImporter.Result?
    private let webFallback: (@Sendable (AccountIdentity, String) async throws -> AccountQuota)?

    public init(
        session: URLSession = .shared,
        homeDirectory _: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() },
        cookieHeader: @escaping @Sendable () throws -> String = {
            try GeminiWebCookieStore.readCookieHeader()
        },
        browserCookieImporter: @escaping @Sendable () -> GeminiBrowserCookieImporter.Result? = {
            GeminiBrowserCookieImporter.importFromBrowsers(allowKeychainPrompt: false)
        },
        webFallback: (@Sendable (AccountIdentity, String) async throws -> AccountQuota)? = nil
    ) {
        self.session = session
        self.now = now
        self.cookieHeader = cookieHeader
        self.browserCookieImporter = browserCookieImporter
        self.webFallback = webFallback
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard account.source == .webCookie else {
            throw QuotaError.unknown("Gemini live quota supports only imported gemini.google.com cookies.")
        }
        let header: String
        do {
            header = try cookieHeader()
        } catch {
            throw QuotaError.noCredential
        }
        let fetcher = GeminiWebQuotaFetcher(session: session, now: now)
        let snapshot: GeminiWebQuotaSnapshot
        do {
            snapshot = try await fetcher.fetch(cookieHeader: header)
        } catch let initialError {
            // Google rotates the browser session more often than Vibe Bar's
            // persisted Keychain copy. Refresh it directly from an installed
            // browser once before surfacing a login error; this keeps the
            // source purely gemini.google.com and never falls back to CLI
            // OAuth quota.
            if let imported = browserCookieImporter(), imported.header != header {
                do {
                    let refreshed = try await fetcher.fetch(cookieHeader: imported.header)
                    try? GeminiWebCookieStore.writeCookieHeader(imported.header, source: .browser)
                    return quota(from: refreshed, for: account)
                } catch {
                    if shouldCalibrate(error), let webFallback {
                        let calibrated = try await webFallback(account, imported.header)
                        try? GeminiWebCookieStore.writeCookieHeader(imported.header, source: .browser)
                        return calibrated
                    }
                    throw error
                }
            }
            if shouldCalibrate(initialError), let webFallback {
                return try await webFallback(account, header)
            }
            throw initialError
        }
        return quota(from: snapshot, for: account)
    }

    private func quota(
        from snapshot: GeminiWebQuotaSnapshot,
        for account: AccountIdentity
    ) -> AccountQuota {
        return AccountQuota(
            accountId: account.id,
            tool: .gemini,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: snapshot.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func shouldCalibrate(_ error: Error) -> Bool {
        guard let quotaError = error as? QuotaError else { return false }
        switch quotaError {
        case .parseFailure:
            return true
        case .network(let message):
            // Transport failures should surface immediately. Only an HTTP
            // response from the private RPC itself indicates a likely rotated
            // route/argument that WebKit can learn.
            return message.contains("Gemini Web batchexecute HTTP")
        case .noCredential, .needsLogin, .rateLimited, .notImplemented, .unknown:
            return false
        }
    }
}

// MARK: - Response parsing

enum GeminiResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
        var email: String?
    }

    static func parse(data: Data, email: String?, now: Date) throws -> Snapshot {
        let response: GeminiAPIResponse
        do {
            response = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
        } catch {
            throw QuotaError.parseFailure("Gemini quota response not parseable: \(error.localizedDescription)")
        }

        guard let raw = response.buckets, !raw.isEmpty else {
            throw QuotaError.parseFailure("Gemini returned no quota buckets.")
        }

        // Group by model. For each model, keep the row with the
        // lowest remainingFraction — that's typically the input-token
        // bucket and is the user's actual bottleneck.
        var byModel: [String: (fraction: Double, resetString: String?)] = [:]
        for bucket in raw {
            guard let modelId = bucket.modelId,
                  let fraction = bucket.remainingFraction else { continue }
            if let existing = byModel[modelId], existing.fraction <= fraction { continue }
            byModel[modelId] = (fraction, bucket.resetTime)
        }

        // Gemini's reset times can come in either ISO8601 with or
        // without fractional seconds. Try both formatters.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        plainISO.formatOptions = [.withInternetDateTime]

        let buckets = byModel
            .sorted { $0.key < $1.key }
            .map { (modelId: String, info: (fraction: Double, resetString: String?)) in
                let resetAt = info.resetString.flatMap { raw in
                    withFractional.date(from: raw) ?? plainISO.date(from: raw)
                }
                return QuotaBucket(
                    id: modelId,
                    title: prettyModelName(modelId),
                    shortLabel: shortLabel(for: modelId),
                    usedPercent: max(0, min(100, (1 - info.fraction) * 100)),
                    resetAt: resetAt,
                    rawWindowSeconds: nil,
                    groupTitle: prettyModelName(modelId)
                )
            }

        return Snapshot(buckets: buckets, planName: nil, email: email)
    }

    static func prettyModelName(_ id: String) -> String {
        let lower = id.lowercased()
        let version = extractGeminiVersion(from: lower)
        let suffix = version.isEmpty ? "" : " \(version)"
        if lower.contains("flash-lite") { return "Flash Lite\(suffix)" }
        if lower.contains("flash")      { return "Flash\(suffix)" }
        if lower.contains("pro")        { return "Pro\(suffix)" }
        if lower.contains("ultra")      { return "Ultra\(suffix)" }
        return id
    }

    static func shortLabel(for id: String) -> String {
        let lower = id.lowercased()
        let version = extractGeminiVersion(from: lower)
        let suffix = version.isEmpty ? "" : " \(version)"
        if lower.contains("flash-lite") { return "Lite\(suffix)" }
        if lower.contains("flash")      { return "Flash\(suffix)" }
        if lower.contains("pro")        { return "Pro\(suffix)" }
        if lower.contains("ultra")      { return "Ultra\(suffix)" }
        return id
    }

    /// Best-effort version extractor for Gemini model identifiers.
    /// Handles `"gemini-2.5-flash-lite"`, `"gemini-3-pro"`,
    /// `"models/gemini-3.0-pro"` → `"2.5"` / `"3"` / `"3.0"`. Returns
    /// `""` when no version segment is recognisable so callers can
    /// fall back to the plain family name.
    static func extractGeminiVersion(from id: String) -> String {
        let pattern = #"gemini[-_/]?(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
              let range = Range(match.range(at: 1), in: id) else {
            return ""
        }
        return String(id[range])
    }
}

// MARK: - Wire types

private struct GeminiAPIResponse: Decodable {
    let buckets: [GeminiAPIBucket]?
}

private struct GeminiAPIBucket: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let modelId: String?
    let tokenType: String?
}
