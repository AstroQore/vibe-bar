import Foundation

/// Ollama Cloud usage adapter.
///
/// Auth: ollama.com browser session cookies. Ollama does not expose a
/// quota API key; the settings page renders Cloud Usage counters for
/// the signed-in account.
public struct OllamaQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .ollama

    private let session: URLSession
    private let now: @Sendable () -> Date

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .ollama,
        domains: ["ollama.com", "www.ollama.com"],
        requiredNames: []
    )

    public init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: Self.cookieSpec)
            .filter { Self.hasRecognizedSessionCookie($0.header) }
        guard !resolutions.isEmpty else { throw QuotaError.noCredential }

        let queriedAt = now()
        let results = await MiscQuotaAggregator.gatherSlotResults(resolutions) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .ollama,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        var request = URLRequest(url: URL(string: "https://ollama.com/settings")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Ollama network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Ollama: invalid response object")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Ollama returned HTTP \(http.statusCode).")
        }
        if OllamaResponseParser.looksSignedOut(text) {
            throw QuotaError.needsLogin
        }

        let snapshot = try OllamaResponseParser.parse(html: text, now: queriedAt)
        return AccountQuota(
            accountId: account.id,
            tool: .ollama,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: snapshot.email ?? account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    public static func hasRecognizedSessionCookie(_ header: String) -> Bool {
        let names = CookieHeaderNormalizer.pairs(from: header).map(\.name)
        return names.contains { name in
            name == "session" ||
                name == "__Secure-session" ||
                name == "ollama_session" ||
                name == "__Host-ollama_session" ||
                name == "__Secure-next-auth.session-token" ||
                name == "next-auth.session-token" ||
                name.hasPrefix("__Secure-next-auth.session-token.") ||
                name.hasPrefix("next-auth.session-token.")
        }
    }
}

enum OllamaResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
        var planName: String?
        var email: String?
    }

    static func parse(html: String, now: Date) throws -> Snapshot {
        let plan = extractFirst(
            patterns: [
                #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#,
                #"Cloud Usage[\s\S]{0,300}?>(Free|Pro|Team|Enterprise|[^<]{1,80})<"#
            ],
            text: html
        )?.trimmed
        let email = extractFirst(
            patterns: [
                #"id=["']header-email["'][^>]*>([^<]+)"#,
                #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
            ],
            text: html,
            options: [.caseInsensitive]
        )?.trimmed

        var buckets: [QuotaBucket] = []
        if let hourly = parseWindow(labels: ["Session usage", "Hourly usage"], html: html, now: now) {
            buckets.append(QuotaBucket(
                id: "ollama.hourly",
                title: hourly.title,
                shortLabel: hourly.shortLabel,
                usedPercent: hourly.percent,
                resetAt: hourly.resetAt,
                rawWindowSeconds: 3600
            ))
        }
        if let weekly = parseWindow(labels: ["Weekly usage"], html: html, now: now) {
            buckets.append(QuotaBucket(
                id: "ollama.weekly",
                title: "Weekly",
                shortLabel: "Wk",
                usedPercent: weekly.percent,
                resetAt: weekly.resetAt,
                rawWindowSeconds: 7 * 86_400
            ))
        }

        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Ollama Cloud Usage counters were not found.")
        }
        return Snapshot(buckets: buckets, planName: plan, email: email)
    }

    static func looksSignedOut(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("/signin") ||
            lower.contains("/login") ||
            lower.contains("sign in to") ||
            lower.contains("log in to")
    }

    private static func parseWindow(
        labels: [String],
        html: String,
        now: Date
    ) -> (title: String, shortLabel: String, percent: Double, resetAt: Date?)? {
        for label in labels {
            guard let range = html.range(of: label, options: [.caseInsensitive]) else { continue }
            let end = html.index(range.lowerBound, offsetBy: 5000, limitedBy: html.endIndex) ?? html.endIndex
            let chunk = String(html[range.lowerBound..<end])
            guard let percent = extractPercent(from: chunk) else { continue }
            let reset = extractFirst(patterns: [#"data-time=["']([^"']+)["']"#], text: chunk)
                .flatMap(parseDate)
            let title = label.lowercased().contains("weekly") ? "Weekly" :
                (label.lowercased().contains("hourly") ? "Hourly" : "Session")
            let short = title == "Weekly" ? "Wk" : "Hr"
            return (title, short, percent, reset)
        }
        return nil
    }

    private static func extractPercent(from text: String) -> Double? {
        let raw = extractFirst(
            patterns: [
                #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#,
                #"width\s*:\s*([0-9]+(?:\.[0-9]+)?)%"#,
                #"aria-valuenow=["']([0-9]+(?:\.[0-9]+)?)["']"#
            ],
            text: text,
            options: [.caseInsensitive]
        )
        guard let value = raw.flatMap(Double.init) else { return nil }
        return max(0, min(100, value <= 1 ? value * 100 : value))
    }

    private static func extractFirst(
        patterns: [String],
        text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsrange) else { continue }
            if match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
            if let range = Range(match.range(at: 0), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
