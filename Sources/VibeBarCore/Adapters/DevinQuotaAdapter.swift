import Foundation

/// Cognition · Devin quota adapter.
///
/// Two sources, tried in this order:
///
/// 1. **Live**, when a Devin web session has been imported: the signed-in
///    `app.devin.ai` page keeps its session in Chromium localStorage
///    (`auth1_session` → `token`, and the internal organization id under
///    `last-internal-org-for-external-org-v1-<slug>`). With those, the page's
///    own `GET /api/<org>/billing/quota/usage` answers with the current daily
///    and weekly usage. The token goes to `app.devin.ai` and nowhere else.
/// 2. **The CLI's cache**, always available once Devin has run: the `devin`
///    CLI keeps the account's `GetUserStatus` answer on disk at
///    `~/.cache/devin/cli/user_status.<identity>.bin` and refreshes it while
///    Devin runs (the desktop app's local agent runs the CLI too). It is as
///    recent as Devin's last run, and `queriedAt` carries the cache's own
///    timestamp so the card says exactly that.
///
/// A live failure never hides a readable cache: the cache answers, and the
/// live error only surfaces when there is nothing else to show. Nothing is
/// written, and nothing poses as Devin's own client.
public struct DevinQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .devin

    public typealias SessionResolver = @Sendable (AccountIdentity) -> [MiscCookieResolver.Resolution]

    private let session: URLSession
    private let homeDirectory: String
    private let now: @Sendable () -> Date
    private let resolveSessions: SessionResolver

    /// `resolveSessions` is the imported web sessions for an account. The
    /// default reads the Keychain slots; a test passes its own so it never
    /// touches this Mac's saved session or the network behind it.
    public init(
        session: URLSession = .shared,
        homeDirectory: String = RealHomeDirectory.path,
        now: @escaping @Sendable () -> Date = { Date() },
        resolveSessions: @escaping SessionResolver = { account in
            MiscCookieResolver.resolveAll(for: DevinLiveQuota.cookieSpec, account: account)
        }
    ) {
        self.session = session
        self.homeDirectory = homeDirectory
        self.now = now
        self.resolveSessions = resolveSessions
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let cache = Result { try cacheQuota(for: account) }
        let cached = try? cache.get()
        do {
            if let live = try await liveQuota(for: account, plan: cached?.plan) {
                return live
            }
        } catch {
            // The cache is still a true reading; only a provider with nothing
            // else to show reports why the live route failed.
            guard let cached else { throw error }
            return cached
        }
        // No web session: the cache answers, and an unreadable cache says so
        // rather than reading as an account that was never connected.
        return try cache.get()
    }

    private func cacheQuota(for account: AccountIdentity) throws -> AccountQuota {
        guard let cache = DevinUserStatusCache.newest(homeDirectory: homeDirectory) else {
            throw QuotaError.noCredential
        }
        let snapshot = try DevinPlanStatusParser.parse(payload: cache.payload)
        return AccountQuota(
            accountId: account.id,
            tool: .devin,
            buckets: snapshot.buckets,
            plan: snapshot.planName ?? account.plan,
            email: account.email,
            queriedAt: cache.fetchedAt
        )
    }

    /// `nil` when no web session has been imported, so the cache answers
    /// without an error ever being raised for a route the user never set up.
    private func liveQuota(for account: AccountIdentity, plan: String?) async throws -> AccountQuota? {
        let resolutions = resolveSessions(account)
        guard !resolutions.isEmpty else { return nil }
        let queriedAt = now()
        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: DevinLiveQuota.cookieSpec,
            account: account,
            resolutions: resolutions
        ) { resolution in
            try await self.fetchOneSlot(resolution, account: account, plan: plan, queriedAt: queriedAt)
        }
        let aggregated = MiscQuotaAggregator.aggregate(
            tool: .devin, account: account, results: results, queriedAt: queriedAt
        )
        if let error = aggregated.error { throw error }
        return aggregated
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        plan: String?,
        queriedAt: Date
    ) async throws -> AccountQuota {
        guard let request = DevinLiveQuota.makeRequest(cookieHeader: resolution.header) else {
            throw QuotaError.noCredential
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SafeLog.net("Devin usage request failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.unknown("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw QuotaError.needsLogin
        case 429: throw QuotaError.rateLimited
        case 500...599: throw QuotaError.network("server \(http.statusCode)")
        default: throw QuotaError.unknown("HTTP \(http.statusCode)")
        }
        return AccountQuota(
            accountId: account.id,
            tool: .devin,
            buckets: try DevinQuotaUsageParser.parse(data: data),
            plan: plan ?? account.plan,
            email: account.email,
            queriedAt: queriedAt
        )
    }
}

/// The imported `app.devin.ai` session and the one request it makes.
public enum DevinLiveQuota {
    static let origin = "https://app.devin.ai"
    static let tokenName = "devin-auth1-token"
    static let organizationName = "devin-org-id"

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .devin,
        domains: ["app.devin.ai"],
        requiredNames: [tokenName, organizationName],
        credentialNames: [tokenName, organizationName],
        browserCredentialSource: .chromiumLocalStorageFields([
            ChromiumLocalStorageCredential(
                origin: origin,
                key: "auth1_session",
                syntheticCookieName: tokenName,
                valueFormat: .json(field: "token", minLength: 16, maxLength: 8_192)
            ),
            ChromiumLocalStorageCredential(
                origin: origin,
                key: "last-internal-org-for-external-org-v1-",
                keyMatch: .prefix,
                syntheticCookieName: organizationName,
                valueFormat: .json(field: nil, minLength: 5, maxLength: 96)
            )
        ]),
        requiresEveryCredentialName: true
    )

    /// `GET https://app.devin.ai/api/<org>/billing/quota/usage`, the request
    /// the page's own Usage & Limits view makes. `nil` when either half of the
    /// session is missing or is not shaped like one.
    static func makeRequest(cookieHeader: String) -> URLRequest? {
        let pairs = CookieHeaderNormalizer.pairs(from: cookieHeader)
        func value(_ name: String) -> String? {
            pairs.first { $0.name == name }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let token = value(tokenName), isHeaderSafe(token), token.count >= 16,
              let organization = value(organizationName), isOrganizationID(organization),
              let url = URL(string: "\(origin)/api/\(organization)/billing/quota/usage")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(organization, forHTTPHeaderField: "x-cog-org-id")
        return request
    }

    /// Devin's internal ids are `org-<hex>` (or `org_<id>`); anything else
    /// would be spliced into a URL path, so it is refused.
    static func isOrganizationID(_ raw: String) -> Bool {
        guard raw.hasPrefix("org-") || raw.hasPrefix("org_"), (5...96).contains(raw.count) else { return false }
        return raw.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    private static func isHeaderSafe(_ raw: String) -> Bool {
        !raw.isEmpty && raw.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 32 && scalar.value != 127 && scalar != ";" && scalar != ","
        }
    }
}

/// `{"daily_percentage": 15, "daily_reset_at": "2026-09-18T00:00:00-08:00",
/// "weekly_percentage": 7, "weekly_reset_at": …, "hide_daily_quota": false}` —
/// what the Usage & Limits page draws. The percentages are percent **used**,
/// 0–100, as the live endpoint answered on 2026-09-18; they are read as
/// written, because guessing "a value of one or less is a fraction" would turn
/// 1% used into 100%. A plan without a daily quota says so with
/// `hide_daily_quota`, and its daily window is left out.
public enum DevinQuotaUsageParser {
    public static func parse(data: Data) throws -> [QuotaBucket] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parseFailure("Devin quota usage is not a JSON object")
        }
        let hidesDaily = (root["hide_daily_quota"] as? Bool) ?? false
        var buckets: [QuotaBucket] = []
        if !hidesDaily, let used = percent(root["daily_percentage"]) {
            buckets.append(QuotaBucket(
                id: "daily", title: "Daily", shortLabel: "Daily",
                usedPercent: used, resetAt: date(root["daily_reset_at"]), rawWindowSeconds: 86_400
            ))
        }
        if let used = percent(root["weekly_percentage"]) {
            buckets.append(QuotaBucket(
                id: "weekly", title: "Weekly", shortLabel: "Weekly",
                usedPercent: used, resetAt: date(root["weekly_reset_at"]), rawWindowSeconds: 604_800
            ))
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Devin quota usage has no quota windows")
        }
        return buckets
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0 else { return nil }
        return min(100, raw)
    }

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            return ServiceStatusClient.flexibleDate(from: text)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        // Seconds, or milliseconds when the magnitude says so.
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
    }
}

/// `~/.cache/devin/cli/user_status.<identity digest>.bin`: a small JSON
/// envelope `{version, identity_digest, fetched_at_secs, payload}` whose
/// `payload` is the base64 protobuf `UserStatus`. One file per signed-in
/// identity; the newest fetch is the account in use.
public enum DevinUserStatusCache {
    public struct Entry: Sendable {
        public let fetchedAt: Date
        public let payload: Data
    }

    static let relativeDirectory = ".cache/devin/cli"
    /// A status file is a few hundred kilobytes; anything far larger is not
    /// one.
    static let maxBytes = 8 * 1_048_576

    public static func directory(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
    }

    public static func exists(homeDirectory: String = RealHomeDirectory.path) -> Bool {
        !candidateFiles(homeDirectory: homeDirectory).isEmpty
    }

    public static func newest(homeDirectory: String = RealHomeDirectory.path) -> Entry? {
        candidateFiles(homeDirectory: homeDirectory)
            .compactMap(read)
            .max { $0.fetchedAt < $1.fetchedAt }
    }

    static func candidateFiles(homeDirectory: String) -> [URL] {
        let directory = directory(homeDirectory: homeDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("user_status.") && $0.hasSuffix(".bin") }
            .map { directory.appendingPathComponent($0) }
    }

    static func read(_ url: URL) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= maxBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return parse(envelope: data)
    }

    static func parse(envelope data: Data) -> Entry? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encoded = root["payload"] as? String,
              let payload = Data(base64Encoded: encoded),
              let seconds = (root["fetched_at_secs"] as? NSNumber)?.doubleValue, seconds > 0
        else { return nil }
        return Entry(fetchedAt: Date(timeIntervalSince1970: seconds), payload: payload)
    }
}

/// Decodes the plan half of Devin's `UserStatus` protobuf. Only numbers and
/// the plan's display name are read; the message also carries the account's
/// identity, which never leaves the parse.
///
/// `UserStatus` field 13 is `PlanStatus`:
/// - `1` `PlanInfo` → `2` plan name ("Pro")
/// - `14` / `15` daily / weekly quota **remaining** percent
/// - `17` / `18` daily / weekly reset, unix seconds
///
/// proto3 does not write zero, so a spent window arrives with its reset but no
/// percent. A window with neither is one the plan does not have (Max, for
/// example, has only the weekly one).
public enum DevinPlanStatusParser {
    public struct Snapshot: Sendable, Equatable {
        public let buckets: [QuotaBucket]
        public let planName: String?
    }

    static let dailyRemainingField = 14
    static let weeklyRemainingField = 15
    static let dailyResetField = 17
    static let weeklyResetField = 18

    public static func parse(payload: Data) throws -> Snapshot {
        guard let status = ProtobufFields(payload),
              let planStatus = status.message(13).flatMap(ProtobufFields.init)
        else { throw QuotaError.parseFailure("Devin plan status is not readable") }

        let planName = planStatus.message(1)
            .flatMap(ProtobufFields.init)?
            .string(2)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var buckets: [QuotaBucket] = []
        if let bucket = window(
            id: "daily", title: "Daily", seconds: 86_400,
            remaining: planStatus.varint(dailyRemainingField),
            reset: planStatus.varint(dailyResetField)
        ) {
            buckets.append(bucket)
        }
        if let bucket = window(
            id: "weekly", title: "Weekly", seconds: 604_800,
            remaining: planStatus.varint(weeklyRemainingField),
            reset: planStatus.varint(weeklyResetField)
        ) {
            buckets.append(bucket)
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Devin plan status has no quota windows")
        }
        return Snapshot(buckets: buckets, planName: planName?.isEmpty == false ? planName : nil)
    }

    private static func window(
        id: String,
        title: String,
        seconds: Int,
        remaining: UInt64?,
        reset: UInt64?
    ) -> QuotaBucket? {
        guard remaining != nil || reset != nil else { return nil }
        let left = min(100, Double(remaining ?? 0))
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: title,
            usedPercent: 100 - left,
            resetAt: reset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            rawWindowSeconds: seconds
        )
    }
}

/// The last occurrence of each top-level field in one protobuf message —
/// enough to read a handful of scalar and nested fields without generated
/// code. Malformed input yields `nil` rather than a partial read.
struct ProtobufFields {
    private var varints: [Int: UInt64] = [:]
    private var bytes: [Int: Data] = [:]

    init?(_ data: Data) {
        let buffer = [UInt8](data)
        var index = 0
        while index < buffer.count {
            guard let key = Self.varint(buffer, &index) else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = Self.varint(buffer, &index) else { return nil }
                varints[field] = value
            case 1:
                guard index + 8 <= buffer.count else { return nil }
                index += 8
            case 2:
                guard let length = Self.varint(buffer, &index), length <= UInt64(buffer.count - index) else {
                    return nil
                }
                let end = index + Int(length)
                bytes[field] = Data(buffer[index..<end])
                index = end
            case 5:
                guard index + 4 <= buffer.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
    }

    func varint(_ field: Int) -> UInt64? { varints[field] }
    func message(_ field: Int) -> Data? { bytes[field] }
    func string(_ field: Int) -> String? { bytes[field].flatMap { String(data: $0, encoding: .utf8) } }

    private static func varint(_ buffer: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < buffer.count, shift < 64 {
            let byte = buffer[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
