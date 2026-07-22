import Foundation

/// Fetches Gemini usage data from the signed-in `gemini.google.com`
/// web session via imported browser cookies.
///
/// The live quota data rendered by Gemini's usage component comes from a
/// private batchexecute RPC. Its identifier and argument are runtime
/// implementation details, so Vibe Bar replays a small learned recipe and
/// lets the App-layer hidden `/usage` WebView calibrate a replacement when
/// Google changes it.
///
/// Wire format (cookie-authenticated, no SAPISIDHASH required):
/// - URL: `https://gemini.google.com/_/BardChatUi/data/batchexecute`
///   with query items `rpcids=<learned>&source-path=/usage&hl=en&_reqid=<rand>&rt=c`.
/// - Method: POST, `Content-Type:
///   application/x-www-form-urlencoded;charset=UTF-8`.
/// - Body: `f.req=[[["<learned>","<learned args>",null,
///   "generic"]]]&at=<XSRF>&`. `at=` carries the
///   `WIZ_global_data.SNlM0e` XSRF token extracted from the SSR
///   HTML of `https://gemini.google.com/usage?pli=1`.
/// - Response: JSONP-prefixed (`)]}'\n`) chunked stream. The
///   `["wrb.fr","<learned>","<encoded JSON>",...]` entry carries the
///   payload. See `GeminiWebResponseParser` for the decoded shape.
struct GeminiWebQuotaFetcher: Sendable {
    /// Set to `true` now that the live quota endpoint is implemented.
    static let spikeComplete = true
    static let quotaRPCId = GeminiWebUsageRecipe.fallback.rpcID

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let recipeProvider: @Sendable () -> GeminiWebUsageRecipe

    init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        recipeProvider: @escaping @Sendable () -> GeminiWebUsageRecipe = {
            GeminiWebUsageRecipeStore.load()
        }
    ) {
        self.session = session
        self.now = now
        self.recipeProvider = recipeProvider
    }

    func fetch(cookieHeader: String, email: String? = nil) async throws -> GeminiWebQuotaSnapshot {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuotaError.noCredential }
        let xsrf = try await fetchXsrfToken(cookieHeader: trimmed)
        let learned = recipeProvider()
        do {
            return try await fetch(
                recipe: learned,
                cookieHeader: trimmed,
                xsrfToken: xsrf,
                email: email
            )
        } catch {
            // A learned recipe can become stale. Retry the last broadly known
            // contract once before asking WebKit to calibrate a new one.
            guard learned != .fallback else { throw error }
            return try await fetch(
                recipe: .fallback,
                cookieHeader: trimmed,
                xsrfToken: xsrf,
                email: email
            )
        }
    }

    private func fetch(
        recipe: GeminiWebUsageRecipe,
        cookieHeader: String,
        xsrfToken: String,
        email: String?
    ) async throws -> GeminiWebQuotaSnapshot {
        let payload = try await postQuotaRequest(
            cookieHeader: cookieHeader,
            xsrfToken: xsrfToken,
            recipe: recipe
        )
        return try GeminiWebResponseParser.parse(
            data: payload,
            rpcID: recipe.rpcID,
            email: email,
            now: now()
        )
    }

    private func fetchXsrfToken(cookieHeader: String) async throws -> String {
        guard let url = URL(string: "https://gemini.google.com/usage?pli=1") else {
            throw QuotaError.unknown("Gemini Web URL malformed.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.httpShouldHandleCookies = false

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Gemini Web initial GET returned no HTTP response.")
        }
        switch http.statusCode {
        case 401, 403: throw QuotaError.needsLogin
        case 429: throw QuotaError.rateLimited
        case 200...299: break
        default:
            throw QuotaError.network("Gemini Web initial GET HTTP \(http.statusCode).")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw QuotaError.parseFailure("Gemini Web initial GET body not UTF-8.")
        }
        return try Self.extractXsrfToken(from: body)
    }

    private func postQuotaRequest(
        cookieHeader: String,
        xsrfToken: String,
        recipe: GeminiWebUsageRecipe
    ) async throws -> Data {
        let reqid = Int.random(in: 100_000...999_999)
        guard var components = URLComponents(string: "https://gemini.google.com/_/BardChatUi/data/batchexecute") else {
            throw QuotaError.unknown("Gemini Web batchexecute URL malformed.")
        }
        components.queryItems = [
            URLQueryItem(name: "rpcids", value: recipe.rpcID),
            URLQueryItem(name: "source-path", value: "/usage"),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "_reqid", value: String(reqid)),
            URLQueryItem(name: "rt", value: "c")
        ]
        guard let url = components.url else {
            throw QuotaError.unknown("Gemini Web batchexecute URL malformed.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        request.setValue("https://gemini.google.com", forHTTPHeaderField: "Origin")
        request.setValue("https://gemini.google.com/usage?pli=1", forHTTPHeaderField: "Referer")
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let requestEnvelope: [Any] = [[[recipe.rpcID, recipe.argument, NSNull(), "generic"]]]
        guard let envelopeData = try? JSONSerialization.data(withJSONObject: requestEnvelope),
              let innerArgs = String(data: envelopeData, encoding: .utf8) else {
            throw QuotaError.parseFailure("Gemini Web request recipe could not be encoded.")
        }
        let bodyString = "f.req=" + Self.formEncode(innerArgs)
            + "&at=" + Self.formEncode(xsrfToken) + "&"
        request.httpBody = bodyString.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Gemini Web batchexecute returned no HTTP response.")
        }
        switch http.statusCode {
        case 401, 403: throw QuotaError.needsLogin
        case 429: throw QuotaError.rateLimited
        case 200...299: return data
        default:
            throw QuotaError.network("Gemini Web batchexecute HTTP \(http.statusCode).")
        }
    }

    /// Extract the `SNlM0e` XSRF token from the SSR `WIZ_global_data`
    /// blob. Returns `QuotaError.needsLogin` if the token is missing —
    /// the page renders a generic logged-out shell in that case and we
    /// have no usable session.
    static func extractXsrfToken(from html: String) throws -> String {
        let pattern = #""SNlM0e"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw QuotaError.parseFailure("Gemini Web XSRF regex failed to compile.")
        }
        let ns = html as NSString
        guard let match = regex.firstMatch(
            in: html,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 2 else {
            throw QuotaError.needsLogin
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated private static var safariUA: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }
}
