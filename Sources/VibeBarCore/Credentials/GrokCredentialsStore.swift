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

    public init(
        accessToken: String,
        scope: String,
        authMode: String?,
        email: String?,
        firstName: String?,
        lastName: String?,
        teamId: String?,
        subscriptionTier: String?,
        expiresAt: Date?
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
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
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
            expiresAt: parseDate(entry["expires_at"])
        )
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
