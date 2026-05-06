import Foundation

/// Fetches the user's Daily Included Routine Runs budget from
/// `https://claude.ai/v1/code/routines/run-budget`.
///
/// Response shape:
/// ```
/// {"limit":"15","unified_billing_enabled":true,"used":"0"}
/// ```
/// `limit` and `used` are returned as strings — we parse them to ints and
/// derive `usedPercent = used / limit * 100`.
///
/// Auth: claude.ai session cookies (same source the web fetcher uses). Returns
/// `nil` silently when cookies are missing, the request fails, or the payload
/// is unparseable; callers can keep a placeholder bucket visible.
public enum ClaudeRoutinesFetcher {
    private static let endpoint = URL(string: "https://claude.ai/v1/code/routines/run-budget")!

    public struct Result: Sendable, Equatable {
        public let used: Int
        public let limit: Int
        public let usedPercent: Double
        public let unifiedBillingEnabled: Bool

        public init(used: Int, limit: Int, unifiedBillingEnabled: Bool) {
            self.used = used
            self.limit = limit
            self.usedPercent = limit > 0 ? Double(used) / Double(limit) * 100 : 0
            self.unifiedBillingEnabled = unifiedBillingEnabled
        }
    }

    public static func fetch(session: URLSession = .shared) async -> Result? {
        // Stay inside Vibe Bar's minimized cookie store. If the endpoint needs
        // more than sessionKey for a particular account, keep the placeholder
        // bucket visible instead of broadening stored cookies.
        let headers = ClaudeWebCookieStore.candidateCookieHeaders()
        for header in headers {
            if let result = await fetch(cookieHeader: header, session: session) {
                return result
            }
        }
        return nil
    }

    public static func fetch(cookieHeader: String, session: URLSession = .shared) async -> Result? {
        let header = ClaudeWebCookieStore.normalizedCookieHeader(from: cookieHeader)
        guard !header.isEmpty else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://claude.ai/code", forHTTPHeaderField: "Referer")
        request.setValue("claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPResponseLimit.boundedData(from: session, for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return parse(data: data)
    }

    /// Internal entry point usable from tests with raw payload bytes.
    public static func parse(data: Data) -> Result? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The API returns `used` and `limit` as strings; tolerate the int
        // form too in case the schema rotates.
        guard let used = anyInt(json["used"]),
              let limit = anyInt(json["limit"]),
              limit > 0
        else { return nil }
        let unified = (json["unified_billing_enabled"] as? Bool) ?? false
        return Result(used: used, limit: limit, unifiedBillingEnabled: unified)
    }

    private static func anyInt(_ raw: Any?) -> Int? {
        switch raw {
        case let n as NSNumber: return n.intValue
        case let i as Int:      return i
        case let d as Double:   return Int(d)
        case let s as String:   return Int(s)
        default:                return nil
        }
    }
}
