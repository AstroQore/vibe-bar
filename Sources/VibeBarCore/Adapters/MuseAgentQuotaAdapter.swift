import Foundation

/// Meta AI · Muse quota adapter — the personal agent at muse.ai and the Muse
/// Mac app, not the Muse Code CLI (`MuseQuotaAdapter`).
///
/// Muse publishes its weekly allowance only to the signed-in web app. The
/// Settings → General → Usage row is filled by a Next.js server action,
/// `fetchSubscriptionAction`, which the page calls as
/// `POST https://muse.ai/` with a `Next-Action: <id>` header and the literal
/// body `[]`, authorised by the muse.ai session cookies. The answer is a React
/// Server Components stream, one `<row>:<json>` line at a time; the row whose
/// JSON carries `subscription` is the one read (`MuseAgentSubscriptionParser`).
///
/// The action id is a hash that changes with every deployment, so it is not
/// compiled in: `MuseAgentActionResolver` finds it in the app's public
/// JavaScript chunks (`MuseAgentActionDiscovery`), keeps it in
/// `~/.vibebar/muse_agent_action.json`, and looks again only when the cache is
/// empty or the server answers "action not found".
///
/// Credentials: the whole muse.ai cookie jar (`hatch_sess` is the session and
/// the one the spec requires), imported from a signed-in browser or pasted
/// through the shared cookie slots, and sent only to `muse.ai`. The chunk
/// downloads are public static files and carry no cookie.
///
/// Nothing is written back to Muse, and nothing poses as Muse's own client
/// beyond the headers a server action needs to be routed.
public struct MuseAgentQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .museAgent

    /// The session cookie. Its presence is what "signed in" means here.
    static let sessionCookieName = "hatch_sess"

    /// Every muse.ai cookie is kept (`requiredNames` is empty): the server
    /// action is answered by the same middleware that serves the page, and
    /// the page sends the whole jar. `hatch_sess` must be in it, in an
    /// import and in a pasted header alike.
    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .museAgent,
        domains: ["muse.ai", "www.muse.ai"],
        requiredNames: [],
        credentialNames: [sessionCookieName],
        requiresEveryCredentialName: true
    )

    public static let origin = URL(string: "https://muse.ai")!
    public static let actionURL = URL(string: "https://muse.ai/")!

    private let transport: any MuseAgentHTTPTransport
    private let resolver: MuseAgentActionResolver
    private let now: @Sendable () -> Date

    public init(
        transport: any MuseAgentHTTPTransport = URLSessionMuseAgentTransport(),
        resolver: MuseAgentActionResolver = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.resolver = resolver
        self.now = now
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let resolutions = MiscCookieResolver.resolveAll(for: Self.cookieSpec, account: account)
        let queriedAt = now()
        // Muse is off until the user imports or pastes a session in
        // Settings → Meta AI. With no slot at all there is nothing to repair,
        // so a scheduled refresh does not go looking in the browsers for a
        // session the user never asked Vibe Bar to use.
        guard !resolutions.isEmpty else {
            return MiscQuotaAggregator.aggregate(tool: .museAgent, account: account, results: [], queriedAt: queriedAt)
        }
        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: Self.cookieSpec,
            account: account,
            resolutions: resolutions
        ) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .museAgent,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        let cookieHeader = resolution.header
        guard Self.cookieSpec.hasRequiredCredential(in: cookieHeader) else {
            throw QuotaError.noCredential
        }
        let snapshot = try await fetchSnapshot(cookieHeader: cookieHeader)
        return AccountQuota(
            accountId: account.id,
            tool: .museAgent,
            buckets: [snapshot.weekly],
            plan: snapshot.planLabel ?? account.plan,
            email: account.email,
            queriedAt: queriedAt
        )
    }

    /// The cached action first; one fresh discovery if there is none or the
    /// server no longer knows it, then one retry with the new id.
    func fetchSnapshot(cookieHeader: String) async throws -> MuseAgentSubscriptionParser.Snapshot {
        var record = await resolver.current()
        if record == nil {
            record = try await resolver.rediscover(invalidating: nil, cookieHeader: cookieHeader, transport: transport)
        }
        guard var record else { throw QuotaError.unknown("Muse action id unavailable") }
        switch try await callAction(record.actionID, cookieHeader: cookieHeader) {
        case let .answered(data):
            return try MuseAgentSubscriptionParser.parse(data: data)
        case .actionNotFound:
            SafeLog.net("Muse subscription action is gone; looking for the new one")
            record = try await resolver.rediscover(
                invalidating: record.actionID,
                cookieHeader: cookieHeader,
                transport: transport
            )
            switch try await callAction(record.actionID, cookieHeader: cookieHeader) {
            case let .answered(data):
                return try MuseAgentSubscriptionParser.parse(data: data)
            case .actionNotFound:
                throw QuotaError.parseFailure(MuseAgentActionDiscovery.changedMessage)
            }
        }
    }

    enum ActionOutcome {
        case answered(Data)
        case actionNotFound
    }

    private func callAction(_ actionID: String, cookieHeader: String) async throws -> ActionOutcome {
        let request = Self.makeActionRequest(actionID: actionID, cookieHeader: cookieHeader)
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch {
            SafeLog.net("Muse subscription request failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }
        return try Self.classify(status: http.statusCode, headers: http, data: data)
    }

    /// Maps one server-action response. `403 {"error":"Forbidden"}` is a
    /// session the server refused; a redirect is the auth middleware sending
    /// a signed-out visitor to `auth.muse.ai`; a 404 carrying
    /// `x-nextjs-action-not-found` is an id from an older deployment.
    static func classify(status: Int, headers: HTTPURLResponse, data: Data) throws -> ActionOutcome {
        switch status {
        case 200..<300:
            return .answered(data)
        case 300..<400, 401, 403:
            throw QuotaError.needsLogin
        case 404:
            if MuseAgentActionDiscovery.isActionNotFound(headers: headers, data: data) {
                return .actionNotFound
            }
            throw QuotaError.unknown("HTTP 404")
        case 429:
            throw QuotaError.rateLimited
        case 500...599:
            throw QuotaError.network("server \(status)")
        default:
            throw QuotaError.unknown("HTTP \(status)")
        }
    }

    static func makeActionRequest(actionID: String, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: actionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.httpBody = Data("[]".utf8)
        request.setValue(actionID, forHTTPHeaderField: "Next-Action")
        request.setValue("text/x-component", forHTTPHeaderField: "Accept")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        return request
    }
}

// MARK: - Transport

/// The one network seam the Muse adapter has, so tests can answer every
/// request without a socket.
public protocol MuseAgentHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`'s default configuration — it follows the macOS system proxy
/// and hands it the host name, which is what makes Meta's hosts reachable on
/// networks whose resolver answers them wrongly. Redirects are *not* followed:
/// a signed-out request is answered with a redirect to `auth.muse.ai`, and
/// that answer is the diagnosis, not a page to fetch with the cookies on.
public struct URLSessionMuseAgentTransport: MuseAgentHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate.shared)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.unknown("no HTTP response")
        }
        return (data, http)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirectDelegate()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

// MARK: - Response parsing

/// Reads the `fetchSubscriptionAction` answer.
///
/// ```text
/// 0:{"a":"$@1","f":"","q":"","i":false}
/// 1:{"success":true,"subscription":{"tier":{"tierId":"…","name":"…","tierCode":"…",
///    "isPaid":false,"rank":0},"usage":{"state":"METERED","percentUsed":1,
///    "resetsAt":1790392306,"quotaStatus":"SUFFICIENT"},…,"topupBalance":0,
///    "topupTotal":0,"topupRowLabel":"Additional tokens","topupRowValueLabel":null,…}}
/// ```
///
/// The row number is not assumed: every line is tried and the first JSON
/// object that carries `subscription` wins. `usage` may be `null` (nothing
/// metered this week) or in a state other than `METERED` (an unmetered
/// tier); both read as 0% with whatever reset the server named, the way an
/// idle Muse Code window does, so the card keeps its place.
public enum MuseAgentSubscriptionParser {
    public struct Snapshot: Sendable, Equatable {
        public let weekly: QuotaBucket
        /// The tier's own name ("Free"), or one derived from its code.
        public let tierName: String?
        public let isPaid: Bool?
        public let topupBalance: Double?
        public let topupTotal: Double?
        public let topupRowLabel: String?
        public let topupRowValueLabel: String?

        /// The plan line: the tier, and — only while the account holds a
        /// top-up — the provider's own "Additional tokens" row beside it.
        /// Vibe Bar has no token-balance widget, and a USD credits row would
        /// be the wrong unit, so the balance rides on the plan line in the
        /// provider's words rather than a control made up for it.
        public var planLabel: String? {
            guard let topupTotal, topupTotal > 0 else { return tierName }
            let label = topupRowLabel ?? "Additional tokens"
            let value = topupRowValueLabel
                ?? "\(Self.integer(topupBalance ?? 0)) / \(Self.integer(topupTotal))"
            return [tierName, "\(label): \(value)"].compactMap { $0 }.joined(separator: " · ")
        }

        /// Locale-free on purpose: this lands in the quota cache, not on a
        /// label (AGENTS.md § 7.2 — a stored value never changes shape with
        /// the user's language).
        private static func integer(_ value: Double) -> String {
            String(Int(value.rounded()))
        }
    }

    public static let weekSeconds = 604_800

    public static func parse(data: Data) throws -> Snapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuotaError.parseFailure("Muse usage response is not text")
        }
        var refusal: [String: Any]?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = jsonObject(inRow: Substring(line)) else { continue }
            if object["subscription"] != nil {
                return try snapshot(from: object)
            }
            if refusal == nil, (object["success"] as? NSNumber).map(isFalse) == true {
                refusal = object
            }
        }
        if refusal != nil {
            throw QuotaError.parseFailure("Muse did not return this account's subscription")
        }
        throw QuotaError.parseFailure("Muse usage response has no subscription row")
    }

    /// `<row id>:<payload>` — the payload is JSON only when it starts with
    /// `{`; module (`I[…]`), text (`T…`) and hint rows are skipped.
    static func jsonObject(inRow line: Substring) -> [String: Any]? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let payload = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard payload.hasPrefix("{"), let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func snapshot(from row: [String: Any]) throws -> Snapshot {
        if let success = row["success"] as? NSNumber, isFalse(success) {
            throw QuotaError.parseFailure("Muse did not return this account's subscription")
        }
        guard let subscription = row["subscription"] as? [String: Any] else {
            throw QuotaError.parseFailure("Muse usage response has no subscription object")
        }
        let tier = subscription["tier"] as? [String: Any]
        let tierName = string(tier?["name"]) ?? tierName(fromCode: string(tier?["tierCode"]))
        let isPaid = (tier?["isPaid"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }

        let rawUsage = subscription["usage"]
        guard rawUsage == nil || rawUsage is NSNull || rawUsage is [String: Any] else {
            throw QuotaError.parseFailure("Muse usage response has a malformed usage object")
        }
        let usage = rawUsage as? [String: Any]
        let resetAt = date(usage?["resetsAt"])
        let usedPercent: Double
        if let usage, (string(usage["state"]) ?? "").uppercased() == "METERED" {
            guard let percent = meteredPercent(usage) else {
                throw QuotaError.parseFailure("Muse usage response has no used percentage")
            }
            usedPercent = percent
        } else {
            usedPercent = 0
        }

        return Snapshot(
            weekly: QuotaBucket(
                id: "weekly",
                title: "Weekly",
                shortLabel: "Weekly",
                usedPercent: usedPercent,
                resetAt: resetAt,
                rawWindowSeconds: weekSeconds
            ),
            tierName: tierName,
            isPaid: isPaid,
            topupBalance: number(subscription["topupBalance"]),
            topupTotal: number(subscription["topupTotal"]),
            topupRowLabel: string(subscription["topupRowLabel"]),
            topupRowValueLabel: string(subscription["topupRowValueLabel"])
        )
    }

    /// `percentUsed` (0–100) when present; otherwise the web app's own
    /// fallback, the share of `total` no longer in `balance`.
    static func meteredPercent(_ usage: [String: Any]) -> Double? {
        if let percent = number(usage["percentUsed"]) {
            return min(100, max(0, percent))
        }
        if let total = number(usage["total"]), total > 0, let balance = number(usage["balance"]) {
            return min(100, max(0, 100 * (total - balance) / total))
        }
        return nil
    }

    /// `HATCH_FREE` → "Free", `HATCH_PLUS_ANNUAL` → "Plus Annual".
    static func tierName(fromCode code: String?) -> String? {
        guard var code = code?.uppercased() else { return nil }
        if code.hasPrefix("HATCH_") { code.removeFirst("HATCH_".count) }
        let words = code.split(separator: "_").map { $0.prefix(1) + $0.dropFirst().lowercased() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func isFalse(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID() && !number.boolValue
    }

    /// A JSON boolean is not a number, even though `NSNumber` holds both.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Unix seconds; milliseconds tolerated.
    private static func date(_ value: Any?) -> Date? {
        guard let raw = number(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
    }
}
