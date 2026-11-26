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
    static let trafficVerificationError = QuotaError.network("Google requested a traffic check before returning Gemini usage. The imported session has not been verified.")
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

    /// Validation of an imported header runs while the user waits on a
    /// manual import, so it gets a wall-clock bound the shared session does
    /// not have: a trickling or stalled response fails the probe instead of
    /// holding the import open.
    private static let validationSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// True only when the live endpoint turned `cookieHeader` away as logged
    /// out. Transport errors and response-shape drift answer false: neither
    /// says anything about whether the session is alive.
    static func isSignedOut(cookieHeader: String, session: URLSession? = nil) async -> Bool {
        await validationError(cookieHeader: cookieHeader, session: session) == .needsLogin
    }

    static func validationError(cookieHeader: String, session: URLSession? = nil) async -> QuotaError? {
        do {
            let snapshot = try await GeminiWebQuotaFetcher(session: session ?? validationSession).fetch(cookieHeader: cookieHeader)
            let ids = Set(snapshot.buckets.map(\.id))
            guard ids.contains(GeminiWebResponseParser.currentUsageBucketId), ids.contains(GeminiWebResponseParser.weeklyUsageBucketId) else {
                return .parseFailure("Gemini usage did not return both quota windows.")
            }
            return nil
        } catch let error as QuotaError {
            return error
        } catch {
            return .network(error.localizedDescription)
        }
    }

    func fetch(cookieHeader: String, email: String? = nil) async throws -> GeminiWebQuotaSnapshot {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuotaError.noCredential }
        // The usage page's own query is one cookie-authenticated GET with a
        // JSON answer. Only a drifted contract falls through to the older
        // batchexecute route; a signed-out, throttled or challenged session
        // would fail there the same way.
        do {
            return try await fetchUsagePageQuery(cookieHeader: trimmed, email: email)
        } catch let error as QuotaError {
            switch error {
            case .parseFailure, .unknown: break
            default: throw error
            }
        }
        // Isolate each imported profile. Let the official Gemini origin
        // update its own cookies during this one refresh. The jar is never
        // persisted, shared with another profile or sent to a sibling origin.
        let config = session.configuration
        config.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        config.urlCache = nil
        guard let jar = config.httpCookieStorage else { throw QuotaError.noCredential }
        for pair in CookieHeaderNormalizer.pairs(from: trimmed) {
            if let cookie = HTTPCookie(properties: [.name: pair.name, .value: pair.value, .domain: "gemini.google.com",
                                                     .path: "/", .secure: true]) {
                jar.setCookie(cookie)
            }
        }
        let client = URLSession(configuration: config)
        defer { client.finishTasksAndInvalidate() }
        let xsrf = try await fetchXsrfToken(client: client)
        let learned = recipeProvider()
        do {
            return try await fetch(
                recipe: learned,
                client: client,
                xsrfToken: xsrf,
                email: email
            )
        } catch {
            // A learned recipe can become stale. Retry the last broadly known
            // contract once before asking WebKit to calibrate a new one — but
            // only when it is genuinely a different request. A learned recipe
            // that re-derived the fallback's own rpcID and argument differs
            // from `.fallback` on `learnedAt` alone, and replaying it buys a
            // second identical round trip and the same failure.
            guard error as? QuotaError != Self.trafficVerificationError,
                  !learned.matchesContract(of: .fallback) else { throw error }
            return try await fetch(
                recipe: .fallback,
                client: client,
                xsrfToken: xsrf,
                email: email
            )
        }
    }

    /// `UsagePageQuery`, the persisted GraphQL query behind
    /// `gemini.google.com/usage`. The signature identifies the query in
    /// Google's public `UsagePageSurface` bundle.
    static let usagePageQueryURL: URL = {
        var components = URLComponents(
            string: "https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery"
        )!
        components.queryItems = [
            URLQueryItem(name: "query_signature", value: "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="),
            URLQueryItem(
                name: "variables",
                value: #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"#
                    + #""workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#
            )
        ]
        // `+` and `/` in the signature must not reach Google as a space or a
        // path separator.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
        return components.url!
    }()

    private func fetchUsagePageQuery(cookieHeader: String, email: String?) async throws -> GeminiWebQuotaSnapshot {
        let config = session.configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let client = URLSession(configuration: config)
        defer { client.finishTasksAndInvalidate() }

        var request = URLRequest(url: Self.usagePageQueryURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        BrowserRequestHeaders.applySameOriginFetch(to: &request, referer: "https://gemini.google.com/usage")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.data(for: request, delegate: GeminiWebRedirectDelegate())
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Gemini usage query returned no HTTP response.")
        }
        if GeminiWebRedirectDelegate.requiresVerification(http) { throw Self.trafficVerificationError }
        if let target = GeminiWebRedirectDelegate.redirectTarget(http) {
            SafeLog.net("Gemini usage query redirected to \(target.host ?? "?")\(SafeLog.sanitize(target.path))")
            throw QuotaError.needsLogin
        }
        if http.statusCode != 200 { SafeLog.net("Gemini usage query HTTP \(http.statusCode)") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw QuotaError.needsLogin
        case 429: throw QuotaError.rateLimited
        case 500...: throw QuotaError.network("Gemini usage query HTTP \(http.statusCode).")
        default: throw QuotaError.unknown("Gemini usage query HTTP \(http.statusCode).")
        }
        return try GeminiWebResponseParser.parseUsagePageQuery(data: data, email: email)
    }

    private func fetch(
        recipe: GeminiWebUsageRecipe,
        client: URLSession,
        xsrfToken: String,
        email: String?
    ) async throws -> GeminiWebQuotaSnapshot {
        let payload = try await postQuotaRequest(
            client: client,
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

    private func fetchXsrfToken(client: URLSession) async throws -> String {
        guard let url = URL(string: "https://gemini.google.com/usage?pli=1") else {
            throw QuotaError.unknown("Gemini Web URL malformed.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let cookies = client.configuration.httpCookieStorage?.cookies(for: url) {
            request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        }
        request.setValue(BrowserRequestHeaders.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.mainDocumentURL = URL(string: "https://gemini.google.com/usage")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.data(for: request, delegate: GeminiWebRedirectDelegate())
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Gemini Web initial GET returned no HTTP response.")
        }
        if GeminiWebRedirectDelegate.requiresVerification(http) { throw Self.trafficVerificationError }
        if let target = GeminiWebRedirectDelegate.redirectTarget(http), GeminiQuotaAdapter.isGoogleSignInURL(target) {
            throw QuotaError.needsLogin
        }
        switch http.statusCode {
        case 401, 403: throw QuotaError.needsLogin
        case 429: throw QuotaError.rateLimited
        case 200...299: break
        default:
            throw QuotaError.network("Gemini Web initial GET HTTP \(http.statusCode).")
        }
        // URLSession follows the /usage redirect. Google's sign-in HTML
        // also contains SNlM0e, but that token cannot authorize a quota RPC.
        if let landedURL = http.url, GeminiQuotaAdapter.isGoogleSignInURL(landedURL) {
            throw QuotaError.needsLogin
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw QuotaError.parseFailure("Gemini Web initial GET body not UTF-8.")
        }
        let token = try Self.extractXsrfToken(from: body)
        // Some URL protocols deliver the response before updating the
        // configured cookie store. Apply the official origin's successful
        // bootstrap response before constructing the second request.
        if let finalURL = http.url, finalURL.scheme == "https", finalURL.host == "gemini.google.com",
           let fields = http.allHeaderFields as? [String: String], let jar = client.configuration.httpCookieStorage {
            let issued = HTTPCookie.cookies(withResponseHeaderFields: fields, for: finalURL)
            jar.setCookies(issued, for: finalURL, mainDocumentURL: finalURL)
        }
        return token
    }

    private func postQuotaRequest(
        client: URLSession,
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
        if let cookies = client.configuration.httpCookieStorage?.cookies(for: url) {
            request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        request.setValue("https://gemini.google.com", forHTTPHeaderField: "Origin")
        request.setValue("https://gemini.google.com/usage?pli=1", forHTTPHeaderField: "Referer")
        request.setValue(BrowserRequestHeaders.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.mainDocumentURL = URL(string: "https://gemini.google.com/usage")

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
            (data, response) = try await client.data(for: request, delegate: GeminiWebRedirectDelegate())
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Gemini Web batchexecute returned no HTTP response.")
        }
        if GeminiWebRedirectDelegate.requiresVerification(http) { throw Self.trafficVerificationError }
        if let target = GeminiWebRedirectDelegate.redirectTarget(http), GeminiQuotaAdapter.isGoogleSignInURL(target) {
            throw QuotaError.needsLogin
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

}

/// Leave a Google traffic check for the visible usage page. Following
/// these redirects unattended just loops and can trigger more traffic checks.
private final class GeminiWebRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func requiresVerification(_ response: HTTPURLResponse) -> Bool {
        redirectTarget(response).map(isTrafficCheck) == true
    }

    static func redirectTarget(_ response: HTTPURLResponse) -> URL? {
        guard (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location") else { return nil }
        return URL(string: location, relativeTo: response.url)?.absoluteURL
    }

    private static func isTrafficCheck(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "www.google.com" && url.path.hasPrefix("/sorry/")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.host == "gemini.google.com", url.port == nil || url.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
