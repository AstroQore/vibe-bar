import Foundation

/// Snapshot of the xAI Grok credentials persisted by `grok login` in
/// `~/.grok/auth.json`. The file is a map keyed by scope URL — the OIDC
/// scope (`https://auth.x.ai::<client-id>`, used by SuperGrok) wins over
/// the legacy session scope (`https://accounts.x.ai/sign-in`).
public struct GrokCredentials: Sendable, Equatable {
    public let accessToken: String
    public let scope: String
    public let authMode: String?
    public let email: String?
    public let firstName: String?
    public let lastName: String?
    public let teamId: String?
    public let subscriptionTier: String?
    public let expiresAt: Date?
    /// OIDC refresh token (`refresh_token`). Present on `grok login`
    /// OIDC entries; legacy session / API-key entries carry none.
    public let refreshToken: String?
    /// The public OIDC client the tokens were issued to (`oidc_client_id`).
    public let oidcClientID: String?
    /// The issuer that minted the tokens (`oidc_issuer`).
    public let oidcIssuer: String?

    public init(
        accessToken: String,
        scope: String,
        authMode: String?,
        email: String?,
        firstName: String?,
        lastName: String?,
        teamId: String?,
        subscriptionTier: String?,
        expiresAt: Date?,
        refreshToken: String? = nil,
        oidcClientID: String? = nil,
        oidcIssuer: String? = nil
    ) {
        self.accessToken = accessToken
        self.scope = scope
        self.authMode = authMode
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.teamId = teamId
        self.subscriptionTier = subscriptionTier
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.oidcClientID = oidcClientID
        self.oidcIssuer = oidcIssuer
    }

    public var isExpired: Bool {
        isExpired(at: Date())
    }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// True when the bearer is expired or will be within `leeway`
    /// seconds, so a caller should refresh before spending it.
    public func expiresSoon(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    /// True when this entry can be renewed silently through the OIDC
    /// refresh-token grant: it carries a refresh token and a client id,
    /// and its issuer (when recorded) is xAI's own.
    public var canRefresh: Bool {
        guard refreshToken != nil, oidcClientID != nil else { return false }
        guard let oidcIssuer else { return true }
        return GrokCredentialsStore.isTrustedIssuer(oidcIssuer)
    }

    /// The same identity with a freshly minted bearer.
    public func refreshed(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) -> GrokCredentials {
        GrokCredentials(
            accessToken: accessToken,
            scope: scope,
            authMode: authMode,
            email: email,
            firstName: firstName,
            lastName: lastName,
            teamId: teamId,
            subscriptionTier: subscriptionTier,
            expiresAt: expiresAt,
            refreshToken: refreshToken ?? self.refreshToken,
            oidcClientID: oidcClientID,
            oidcIssuer: oidcIssuer
        )
    }

    /// Friendly plan label. SuperGrok is the only tier today; legacy
    /// session logins surface as "session" so the user can tell them
    /// apart in the popover badge.
    public var planLabel: String? {
        if let subscriptionTier,
           let normalized = ProviderPlanDisplay.grokDisplayName(subscriptionTier) {
            return normalized
        }
        switch authMode?.lowercased() {
        case "oidc":    return "SuperGrok"
        case "session": return "Session"
        case nil:       return nil
        default:        return authMode
        }
    }

    public var displayName: String? {
        let parts = [firstName, lastName].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Loader for `~/.grok/auth.json`. Always routes through
/// `RealHomeDirectory` so the credential path stays correct if the
/// sandbox is re-enabled on a future fork.
public enum GrokCredentialsStore {
    /// Top-level OIDC scope used by `grok login` for SuperGrok subscribers.
    public static let oidcScopePrefix = "https://auth.x.ai::"
    /// Legacy session scope used by older `grok login` flows.
    public static let legacySessionScope = "https://accounts.x.ai/sign-in"

    public static func authFileURL(homeDirectory: String = RealHomeDirectory.path) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    public static func hasCredentials(homeDirectory: String = RealHomeDirectory.path) -> Bool {
        FileManager.default.fileExists(atPath: authFileURL(homeDirectory: homeDirectory).path)
    }

    public static func load(homeDirectory: String = RealHomeDirectory.path) throws -> GrokCredentials {
        let url = authFileURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw QuotaError.parseFailure("Could not read \(url.path): \(error.localizedDescription)")
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> GrokCredentials {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QuotaError.parseFailure("auth.json is not JSON: \(error.localizedDescription)")
        }
        guard let root = raw as? [String: Any] else {
            throw QuotaError.parseFailure("auth.json root is not an object.")
        }
        guard let (scope, entry) = selectPreferredEntry(in: root) else {
            throw QuotaError.noCredential
        }
        guard let key = (entry["key"] as? String)?.trimmed, !key.isEmpty else {
            throw QuotaError.noCredential
        }
        return GrokCredentials(
            accessToken: key,
            scope: scope,
            authMode: (entry["auth_mode"] as? String)?.trimmed.nilIfEmpty,
            email: (entry["email"] as? String)?.trimmed.nilIfEmpty,
            firstName: (entry["first_name"] as? String)?.trimmed.nilIfEmpty,
            lastName: (entry["last_name"] as? String)?.trimmed.nilIfEmpty,
            teamId: (entry["team_id"] as? String)?.trimmed.nilIfEmpty,
            subscriptionTier: firstNonEmptyString(
                entry["subscription_tier"],
                entry["plan_name"],
                entry["plan"],
                entry["tier"]
            ),
            expiresAt: parseDate(entry["expires_at"]),
            refreshToken: (entry["refresh_token"] as? String)?.trimmed.nilIfEmpty,
            oidcClientID: (entry["oidc_client_id"] as? String)?.trimmed.nilIfEmpty,
            oidcIssuer: (entry["oidc_issuer"] as? String)?.trimmed.nilIfEmpty
        )
    }

    /// The only issuer Vibe Bar will send a Grok refresh token to.
    public static let trustedIssuer = "https://auth.x.ai"

    static func isTrustedIssuer(_ issuer: String) -> Bool {
        var normalized = issuer.trimmed.lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized == trustedIssuer
    }

    // MARK: - Write-back

    /// Outcome of `writeRefreshed`.
    public enum WriteBackResult: Sendable, Equatable {
        case written
        /// The entry on disk no longer holds the refresh token that was
        /// exchanged — the Grok CLI wrote a newer login in the meantime —
        /// so the file was left alone.
        case superseded
    }

    /// Persists a refreshed bearer into `~/.grok/auth.json`.
    ///
    /// The file is shared with the Grok CLI, and xAI may rotate refresh
    /// tokens, so the new pair has to land where the CLI reads it. Only
    /// the `scope` entry's `key`, `expires_at`, `refresh_token` (when a
    /// new one was issued) and `last_refresh` change; every other field
    /// and every other entry is kept as read. The write is atomic (temp
    /// file in the same directory, then `rename`) and the file ends up
    /// `0600`. When the entry's refresh token is no longer
    /// `previousRefreshToken`, nothing is written.
    @discardableResult
    public static func writeRefreshed(
        _ credentials: GrokCredentials,
        previousRefreshToken: String,
        now: Date = Date(),
        homeDirectory: String = RealHomeDirectory.path
    ) throws -> WriteBackResult {
        let url = authFileURL(homeDirectory: homeDirectory).resolvingSymlinksInPath()
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("auth.json root is not an object.")
        }
        guard var entry = root[credentials.scope] as? [String: Any] else {
            throw QuotaError.parseFailure("auth.json no longer holds the refreshed entry.")
        }
        let onDisk = (entry["refresh_token"] as? String)?.trimmed
        guard onDisk == previousRefreshToken else { return .superseded }

        entry["key"] = credentials.accessToken
        if let expiresAt = credentials.expiresAt {
            entry["expires_at"] = formatDate(expiresAt)
        }
        if let refreshToken = credentials.refreshToken {
            entry["refresh_token"] = refreshToken
        }
        entry["last_refresh"] = formatDate(now)
        root[credentials.scope] = entry

        let output = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try atomicWrite(output, to: url)
        return .written
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".auth.json.vibebar-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temp.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw QuotaError.unknown("Could not stage the refreshed Grok credentials.")
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw QuotaError.unknown("Could not replace auth.json (errno \(code)).")
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    /// Formats a timestamp the way the Grok CLI writes `expires_at`:
    /// UTC, microsecond fraction, `Z` suffix.
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return formatter.string(from: date)
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        values.lazy.compactMap { ($0 as? String)?.trimmed.nilIfEmpty }.first
    }

    private static func selectPreferredEntry(in root: [String: Any]) -> (scope: String, entry: [String: Any])? {
        var oidcCandidate: (String, [String: Any])?
        var legacyCandidate: (String, [String: Any])?
        for (scope, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            if scope.hasPrefix(oidcScopePrefix) {
                oidcCandidate = (scope, entry)
            } else if scope == legacySessionScope || scope.contains("/sign-in") {
                legacyCandidate = (scope, entry)
            }
        }
        return oidcCandidate ?? legacyCandidate
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
