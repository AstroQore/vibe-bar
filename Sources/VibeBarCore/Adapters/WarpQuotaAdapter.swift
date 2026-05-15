import Foundation

/// Warp (warp.dev terminal) usage adapter.
///
/// Warp is an API-key-only provider — no cookies, no OAuth. The user
/// pastes an API key in Settings (`MiscCredentialStore.Kind.apiKey`),
/// or sets `WARP_API_KEY` / `WARP_TOKEN` in the environment.
///
/// Warp surfaces usage through a GraphQL endpoint:
///
///     POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo
///
/// The query returns the current rate-limit window
/// (`requestLimitInfo`) plus any user/workspace-level bonus credit
/// grants. We render two buckets:
///
/// - **Credits** (primary) — `requestsUsed / requestLimit` of the
///   current refresh window. Unlimited plans render as 0%.
/// - **Bonus** (optional) — combined remaining bonus credits across
///   user + workspace grants; expiry of the earliest expiring batch
///   surfaces in `groupTitle`.
///
/// Modeled after CodexBar's `WarpUsageFetcher` (which we port 1:1 for
/// the request shape and bonus aggregation) and `OpenRouterQuotaAdapter`
/// (for the API-key + Keychain wiring).
public struct WarpQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .warp

    private let session: URLSession
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public static let apiURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    /// Warp's GraphQL edge limiter rejects requests whose User-Agent
    /// doesn't match the official client pattern (HTTP 429
    /// "Rate exceeded.").
    public static let userAgent = "Warp/1.0"
    public static let clientID = "warp-app"

    public init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.environment = environment
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = MiscProviderSettings.current(for: .warp)
        guard settings.allowsAPIOrOAuthAccess,
              let apiKey = WarpQuotaAdapter.resolveAPIKey(environment: environment) else {
            throw QuotaError.noCredential
        }

        let data = try await postGraphQL(apiKey: apiKey)
        let snapshot = try WarpResponseParser.parse(data: data, now: now())
        let parsed = WarpResponseParser.buckets(from: snapshot)

        return AccountQuota(
            accountId: account.id,
            tool: .warp,
            buckets: parsed.buckets,
            plan: parsed.planName,
            email: account.email,
            queriedAt: now(),
            error: nil
        )
    }

    private func postGraphQL(apiKey: String) async throws -> Data {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        var request = URLRequest(url: WarpQuotaAdapter.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(WarpQuotaAdapter.clientID, forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersionString, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(WarpQuotaAdapter.userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "query": WarpResponseParser.graphQLQuery,
            "operationName": "GetRequestLimitInfo",
            "variables": [
                "requestContext": [
                    "clientContext": [String: Any](),
                    "osContext": [
                        "category": "macOS",
                        "name": "macOS",
                        "version": osVersionString
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Warp network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Warp: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Warp returned HTTP \(http.statusCode).")
        }
        return data
    }

    public static func resolveAPIKey(environment: [String: String]) -> String? {
        if let stored = MiscCredentialStore.readString(tool: .warp, kind: .apiKey),
           !stored.isEmpty {
            return stored
        }
        if let key = nonEmpty(environment["WARP_API_KEY"]) { return key }
        if let key = nonEmpty(environment["WARP_TOKEN"]) { return key }
        return nil
    }
}

// MARK: - Response parsing

public enum WarpResponseParser {
    public struct Snapshot: Equatable, Sendable {
        public var requestLimit: Int
        public var requestsUsed: Int
        public var nextRefreshTime: Date?
        public var isUnlimited: Bool
        public var bonusCreditsRemaining: Int
        public var bonusCreditsTotal: Int
        public var bonusNextExpiration: Date?
        public var bonusNextExpirationRemaining: Int
        public var updatedAt: Date
    }

    public struct ParsedBuckets {
        public let buckets: [QuotaBucket]
        public let planName: String?
    }

    public static let graphQLQuery = """
    query GetRequestLimitInfo($requestContext: RequestContext!) {
      user(requestContext: $requestContext) {
        __typename
        ... on UserOutput {
          user {
            requestLimitInfo {
              isUnlimited
              nextRefreshTime
              requestLimit
              requestsUsedSinceLastRefresh
            }
            bonusGrants {
              requestCreditsGranted
              requestCreditsRemaining
              expiration
            }
            workspaces {
              bonusGrantsInfo {
                grants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
              }
            }
          }
        }
      }
    }
    """

    public static func parse(data: Data, now: Date) throws -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any] else {
            throw QuotaError.parseFailure("Warp: root JSON is not an object.")
        }

        if let rawErrors = json["errors"] as? [Any], !rawErrors.isEmpty {
            let messages = rawErrors.compactMap(graphQLErrorMessage(from:))
            let joined = messages.prefix(3).joined(separator: " | ")
            // Authentication failures surface in GraphQL errors, not in
            // the HTTP status code (the limiter happily returns a 200).
            if joined.lowercased().contains("authenticated") ||
                joined.lowercased().contains("unauthorized") {
                throw QuotaError.needsLogin
            }
            throw QuotaError.parseFailure(joined.isEmpty ? "Warp GraphQL error." : joined)
        }

        guard let dataObj = json["data"] as? [String: Any],
              let userObj = dataObj["user"] as? [String: Any] else {
            throw QuotaError.parseFailure("Warp: missing data.user.")
        }

        let typeName = (userObj["__typename"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let innerUserObj = userObj["user"] as? [String: Any],
              let limitInfo = innerUserObj["requestLimitInfo"] as? [String: Any] else {
            if let typeName, !typeName.isEmpty, typeName != "UserOutput" {
                throw QuotaError.parseFailure("Warp: unexpected user type '\(typeName)'.")
            }
            throw QuotaError.parseFailure("Warp: missing requestLimitInfo.")
        }

        let isUnlimited = boolValue(limitInfo["isUnlimited"])
        let requestLimit = intValue(limitInfo["requestLimit"])
        let requestsUsed = intValue(limitInfo["requestsUsedSinceLastRefresh"])
        let nextRefreshTime = (limitInfo["nextRefreshTime"] as? String).flatMap(parseDate)

        let bonus = parseBonusCredits(from: innerUserObj)

        return Snapshot(
            requestLimit: requestLimit,
            requestsUsed: requestsUsed,
            nextRefreshTime: nextRefreshTime,
            isUnlimited: isUnlimited,
            bonusCreditsRemaining: bonus.remaining,
            bonusCreditsTotal: bonus.total,
            bonusNextExpiration: bonus.nextExpiration,
            bonusNextExpirationRemaining: bonus.nextExpirationRemaining,
            updatedAt: now
        )
    }

    public static func buckets(from snapshot: Snapshot) -> ParsedBuckets {
        var buckets: [QuotaBucket] = []

        let primaryPercent: Double
        let primaryGroup: String
        if snapshot.isUnlimited {
            primaryPercent = 0
            primaryGroup = "Unlimited"
        } else if snapshot.requestLimit > 0 {
            primaryPercent = min(100.0, max(0.0, Double(snapshot.requestsUsed) / Double(snapshot.requestLimit) * 100.0))
            primaryGroup = "\(snapshot.requestsUsed) / \(snapshot.requestLimit) credits"
        } else {
            primaryPercent = 0
            primaryGroup = "No active plan"
        }

        buckets.append(QuotaBucket(
            id: "warp.credits",
            title: "Credits",
            shortLabel: "Credits",
            usedPercent: primaryPercent,
            resetAt: snapshot.isUnlimited ? nil : snapshot.nextRefreshTime,
            rawWindowSeconds: nil,
            groupTitle: primaryGroup
        ))

        if snapshot.bonusCreditsTotal > 0 || snapshot.bonusCreditsRemaining > 0 {
            let bonusUsed = max(0, snapshot.bonusCreditsTotal - snapshot.bonusCreditsRemaining)
            let bonusPercent: Double
            if snapshot.bonusCreditsTotal > 0 {
                bonusPercent = min(100.0, max(0.0, Double(bonusUsed) / Double(snapshot.bonusCreditsTotal) * 100.0))
            } else {
                bonusPercent = snapshot.bonusCreditsRemaining > 0 ? 0 : 100
            }

            let bonusGroup: String
            if let expiry = snapshot.bonusNextExpiration,
               snapshot.bonusNextExpirationRemaining > 0 {
                let dateText = expiry.formatted(date: .abbreviated, time: .omitted)
                bonusGroup = "\(snapshot.bonusCreditsRemaining) bonus left · expires \(dateText)"
            } else {
                bonusGroup = "\(snapshot.bonusCreditsRemaining) bonus credits left"
            }

            buckets.append(QuotaBucket(
                id: "warp.bonus",
                title: "Bonus",
                shortLabel: "Bonus",
                usedPercent: bonusPercent,
                resetAt: snapshot.bonusNextExpiration,
                rawWindowSeconds: nil,
                groupTitle: bonusGroup
            ))
        }

        let planName: String? = snapshot.isUnlimited ? "Unlimited" : nil
        return ParsedBuckets(buckets: buckets, planName: planName)
    }

    // MARK: - Private helpers

    private struct BonusGrant {
        let granted: Int
        let remaining: Int
        let expiration: Date?
    }

    private struct BonusSummary {
        let remaining: Int
        let total: Int
        let nextExpiration: Date?
        let nextExpirationRemaining: Int
    }

    private static func parseBonusCredits(from userObj: [String: Any]) -> BonusSummary {
        var grants: [BonusGrant] = []

        if let bonusGrants = userObj["bonusGrants"] as? [[String: Any]] {
            for grant in bonusGrants {
                grants.append(parseBonusGrant(from: grant))
            }
        }

        if let workspaces = userObj["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                guard let bonusGrantsInfo = workspace["bonusGrantsInfo"] as? [String: Any],
                      let workspaceGrants = bonusGrantsInfo["grants"] as? [[String: Any]] else {
                    continue
                }
                for grant in workspaceGrants {
                    grants.append(parseBonusGrant(from: grant))
                }
            }
        }

        let totalRemaining = grants.reduce(0) { $0 + $1.remaining }
        let totalGranted = grants.reduce(0) { $0 + $1.granted }

        let expiring = grants.compactMap { grant -> (date: Date, remaining: Int)? in
            guard grant.remaining > 0, let expiration = grant.expiration else { return nil }
            return (expiration, grant.remaining)
        }

        let nextExpiration: Date?
        let nextExpirationRemaining: Int
        if let earliest = expiring.min(by: { $0.date < $1.date }) {
            let earliestKey = Int(earliest.date.timeIntervalSince1970)
            let remaining = expiring.reduce(0) { result, item in
                let key = Int(item.date.timeIntervalSince1970)
                return result + (key == earliestKey ? item.remaining : 0)
            }
            nextExpiration = earliest.date
            nextExpirationRemaining = remaining
        } else {
            nextExpiration = nil
            nextExpirationRemaining = 0
        }

        return BonusSummary(
            remaining: totalRemaining,
            total: totalGranted,
            nextExpiration: nextExpiration,
            nextExpirationRemaining: nextExpirationRemaining
        )
    }

    private static func parseBonusGrant(from grant: [String: Any]) -> BonusGrant {
        let granted = intValue(grant["requestCreditsGranted"])
        let remaining = intValue(grant["requestCreditsRemaining"])
        let expiration = (grant["expiration"] as? String).flatMap(parseDate)
        return BonusGrant(granted: granted, remaining: remaining, expiration: expiration)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let num = value as? NSNumber { return num.intValue }
        if let text = value as? String, let int = Int(text) { return int }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(normalized) { return true }
            if ["false", "0", "no"].contains(normalized) { return false }
        }
        return false
    }

    private static func graphQLErrorMessage(from value: Any) -> String? {
        if let message = value as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any],
           let message = dict["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }
}

private func nonEmpty(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
