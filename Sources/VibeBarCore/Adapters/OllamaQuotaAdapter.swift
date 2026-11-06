import Foundation

/// Ollama Cloud usage adapter.
///
/// Reads legacy rate limits and current credit usage from the signed-in
/// ollama.com settings page.
public struct OllamaQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .ollama

    private static let settingsURL = URL(string: "https://ollama.com/settings")!
    private static let noRedirect = RemoteNoRedirectDelegate()

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
        let resolutions = MiscCookieResolver.resolveAll(for: Self.cookieSpec, account: account)
            .filter { Self.hasRecognizedSessionCookie($0.header) }

        let queriedAt = now()
        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: Self.cookieSpec,
            account: account,
            resolutions: resolutions,
            resolutionFilter: { Self.hasRecognizedSessionCookie($0.header) }
        ) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return Self.resolveSlotResults(
            results,
            slotOrder: resolutions.compactMap(\.slotID),
            account: account,
            queriedAt: queriedAt
        )
    }

    static func resolveSlotResults(
        _ results: [MiscQuotaAggregator.SlotResult],
        slotOrder: [UUID],
        account: AccountIdentity,
        queriedAt: Date
    ) -> AccountQuota {
        let successes = results.compactMap { result -> (slotID: UUID?, quota: AccountQuota)? in
            guard case let .success(quota) = result.outcome else { return nil }
            return (result.slotID, quota)
        }
        if successes.contains(where: { $0.quota.ollamaCredits != nil }) {
            // Keep balances, plan, identity and quota windows from one login.
            // A silent import can supply new slots absent from the initial order.
            let positions = Dictionary(
                slotOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: min
            )
            func priority(_ slotID: UUID?) -> (Int, String) {
                let position = slotID.flatMap { positions[$0] } ?? Int.max
                return (position, slotID?.uuidString ?? "~")
            }
            if let preferred = successes.min(by: { priority($0.slotID) < priority($1.slotID) }) {
                return preferred.quota
            }
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
        var request = URLRequest(url: Self.settingsURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue(resolution.header, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: Self.noRedirect)
        } catch {
            throw QuotaError.network("Ollama network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Ollama: invalid response object")
        }
        if Self.isSignInURL(http.url) {
            throw QuotaError.needsLogin
        }
        if (300..<400).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           Self.isSignInURL(URL(string: location, relativeTo: Self.settingsURL)?.absoluteURL) {
            throw QuotaError.needsLogin
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Ollama returned HTTP \(http.statusCode).")
        }
        let snapshot = try OllamaResponseParser.parse(html: String(decoding: data, as: UTF8.self), now: queriedAt)
        return AccountQuota(
            accountId: account.id,
            tool: .ollama,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: snapshot.email ?? account.email,
            queriedAt: queriedAt,
            error: nil,
            providerExtras: snapshot.credits.map {
                ProviderExtras(tool: .ollama, updatedAt: queriedAt, ollamaCredits: $0)
            }
        )
    }

    public static func hasRecognizedSessionCookie(_ header: String) -> Bool {
        CookieHeaderNormalizer.pairs(from: header).contains { name, value in
            guard !value.isEmpty else { return false }
            return name == "wos-session" ||
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

    static func isSignInURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "ollama.com", "www.ollama.com":
            return ["signin", "login", "auth/signin", "api/auth/signin"].contains(path)
        case "signin.ollama.com":
            return true
        default:
            return host.hasSuffix(".workos.com") && path == "user_management/authorize"
        }
    }
}

enum OllamaResponseParser {
    struct Snapshot {
        let buckets: [QuotaBucket]
        let planName: String?
        let email: String?
        let credits: OllamaCreditUsage?
    }

    private static let usageLabels = #"Monthly usage|Free usage|Session usage|Hourly usage|Weekly usage"#
    private static let dollarNumber = #"(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?"#
    private static let walletHeading = #"<h[1-6]\b[^>]*>\s*Usage credits\s*(?:<span\b[^>]*>\s*([^<]*)</span\s*>\s*)?</h[1-6]\s*>"#

    static func parse(html: String, now _: Date) throws -> Snapshot {
        let page = html.replacingOccurrences(
            of: #"(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&#160;", with: " ")

        let wallet = parseWallet(page)
        let plan = capture(#">\s*(?:Included usage|Cloud Usage)\s*(?:</span\s*>\s*)?<span\b[^>]*>([^<]+)</span\s*>"#, in: page)
            ?? wallet.plan
        let email = capture(#"id=["']header-email["'][^>]*>([^<]+)"#, in: page)
            ?? capture(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, in: page)

        var buckets: [QuotaBucket] = []
        if let monthly = parseWindow(["Monthly usage", "Free usage"], in: page, supportsDollarRatio: true) {
            buckets.append(QuotaBucket(
                id: "ollama.monthly",
                title: "Monthly",
                shortLabel: "Monthly",
                usedPercent: monthly.percent,
                resetAt: monthly.resetAt,
                rawWindowSeconds: 30 * 86_400
            ))
        } else {
            if let fiveHour = parseWindow(["Session usage", "Hourly usage"], in: page) {
                buckets.append(QuotaBucket(
                    id: "ollama.fiveHour",
                    title: "5 Hours",
                    shortLabel: "5h",
                    usedPercent: fiveHour.percent,
                    resetAt: fiveHour.resetAt,
                    rawWindowSeconds: 5 * 3600
                ))
            }
            if let weekly = parseWindow(["Weekly usage"], in: page) {
                buckets.append(QuotaBucket(
                    id: "ollama.weekly",
                    title: "Weekly",
                    shortLabel: "Wk",
                    usedPercent: weekly.percent,
                    resetAt: weekly.resetAt,
                    rawWindowSeconds: 7 * 86_400
                ))
            }
        }

        guard !buckets.isEmpty || wallet.credits != nil else {
            if looksSignedOut(page) { throw QuotaError.needsLogin }
            throw QuotaError.parseFailure("Ollama usage counters were not found.")
        }
        return Snapshot(buckets: buckets, planName: plan, email: email, credits: wallet.credits)
    }

    private static func looksSignedOut(_ html: String) -> Bool {
        capture(#">\s*(?:Sign in|Log in) to Ollama\s*<"#, in: html) != nil ||
            capture(#"<form\b[^>]*\baction=["']/(?:api/)?(?:auth/)?(?:signin|login)(?:[?"'/])"#, in: html) != nil
    }

    private static func parseWindow(
        _ labels: [String],
        in page: String,
        supportsDollarRatio: Bool = false
    ) -> (percent: Double, resetAt: Date?)? {
        let nextLabel = #">\s*(?:\#(usageLabels)|Monthly credits used)\s*<"#
        for label in labels {
            guard let chunk = content(after: #">\s*\#(label)\s*<"#, in: page, stoppingAt: nextLabel) else { continue }
            let percent = capture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*used\b"#, in: chunk).flatMap(Double.init)
                ?? (supportsDollarRatio ? dollarUsagePercent(in: chunk) : nil)
                ?? capture(#"(?<![-\w])width\s*:\s*([0-9]+(?:\.[0-9]+)?)%"#, in: chunk).flatMap(Double.init)
                ?? capture(#"aria-valuenow\s*=\s*["']([0-9]+(?:\.[0-9]+)?)["']"#, in: chunk).flatMap(Double.init)
            guard let percent, percent.isFinite else { continue }
            let timestamp = #"\bdata-time\s*=\s*["']([^"']+)["']"#
            let reset = capture(
                #"<time\b[^>]*\#(timestamp)|<[a-z][^>]*\#(timestamp)[^>]*>\s*Resets?\b"#, in: chunk
            ).flatMap(parseDate)
            return (percent, reset)
        }
        return nil
    }

    private static func dollarUsagePercent(in chunk: String) -> Double? {
        let amounts = captures(#"\$(\#(dollarNumber))\s+of\s+\$(\#(dollarNumber))\s+used\b"#, in: chunk)
        guard amounts.count == 2,
              let used = usd(amounts[0]), let limit = usd(amounts[1]), limit > 0
        else { return nil }
        let percent = used / limit * 100
        return percent.isFinite ? percent : nil
    }

    private static func parseWallet(_ page: String) -> (plan: String?, credits: OllamaCreditUsage?) {
        guard let chunk = content(after: walletHeading, in: page, stoppingAt: #">\s*(?:\#(usageLabels))\s*<"#) else {
            return (nil, nil)
        }
        let amount = #"\$(\#(dollarNumber))"#
        let balance = capture(
            #"^\s*(?:<div\b[^>]*>\s*)*<span\b[^>]*>\s*\#(amount)\s*</span\s*>"#, in: chunk
        ).flatMap(usd)
        let used = capture(
            #">\s*Monthly credits used\s*</span\s*>\s*<span\b[^>]*>\s*\#(amount)\s*</span\s*>"#, in: chunk
        ).flatMap(usd)
        let plan = capture(walletHeading, in: page)
        guard balance != nil || used != nil else { return (plan, nil) }

        // The refill caption is relative text and its target is not a usage limit.
        let refill = capture(
            #"<p\b[^>]*>\s*(Refills\s+to\s+\$\#(dollarNumber)\s+in\s+[^<]{1,100}?)\s*</p\s*>"#, in: chunk
        ).flatMap(VisibleSecretRedactor.dropIfSensitive)
        return (plan, OllamaCreditUsage(balanceUSD: balance, monthlyUsedUSD: used, refillText: refill))
    }

    private static func usd(_ raw: String) -> Double? {
        guard let value = Double(raw.replacingOccurrences(of: ",", with: "")), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Bound a window at the next meter, heading, or section boundary.
    private static func content(after pattern: String, in page: String, stoppingAt nextLabel: String) -> String? {
        guard let label = page.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tail = page[label.upperBound...].prefix(5000)
        let boundary = #"</(?:section|main)\s*>|<h[1-6]\b|\#(nextLabel)"#
        let end = tail.range(of: boundary, options: [.regularExpression, .caseInsensitive])?.lowerBound ?? tail.endIndex
        return String(tail[..<end])
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        else { return [] }
        let groups = match.numberOfRanges > 1 ? 1..<match.numberOfRanges : 0..<1
        return groups.compactMap { index in
            Range(match.range(at: index), in: text)
                .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let number = Double(raw), number.isFinite {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
