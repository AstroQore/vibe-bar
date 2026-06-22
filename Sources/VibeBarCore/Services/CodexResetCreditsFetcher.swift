import Foundation

/// Fetches Codex manual rate-limit reset credits from
/// `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`.
///
/// Response shape:
/// ```
/// {
///   "credits": [
///     { "status": "available", "granted_at": "…", "expires_at": "…" },
///     …
///   ],
///   "available_count": 2
/// }
/// ```
/// `available_count` is authoritative for the headline number. `nextExpiresAt`
/// is the earliest `expires_at` among credits whose `status` is `available` and
/// whose expiry is still in the future (mirroring CodexBar's
/// "next expiring available credit").
///
/// Auth mirrors `CodexQuotaAdapter`: a Bearer access token (OAuth / CLI) plus
/// the optional `ChatGPT-Account-Id` header. Returns `nil` silently on any
/// network / decode failure so the caller can fall back to the inline count or
/// simply omit the row.
public enum CodexResetCreditsFetcher {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    public static func fetch(
        accessToken: String,
        accountId: String?,
        session: URLSession = .shared
    ) async -> CodexResetCredits? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parse(data: data)
        } catch {
            return nil
        }
    }

    /// Internal entry point usable from tests with raw payload bytes. `now` is
    /// injectable so the "skip stale available expiry" filter is deterministic.
    public static func parse(data: Data, now: Date = Date()) -> CodexResetCredits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let count = anyInt(root["available_count"]), count >= 0 else { return nil }

        let credits = (root["credits"] as? [[String: Any]]) ?? []
        let nextExpiry = credits
            .filter { isAvailable($0["status"]) }
            .compactMap { parseDate($0["expires_at"]) }
            .filter { $0 > now }
            .min()

        return CodexResetCredits(availableCount: count, nextExpiresAt: nextExpiry)
    }

    private static func isAvailable(_ raw: Any?) -> Bool {
        (raw as? String)?.caseInsensitiveCompare("available") == .orderedSame
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

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
