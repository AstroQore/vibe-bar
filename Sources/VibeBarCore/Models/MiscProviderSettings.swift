import Foundation

/// Non-sensitive per-misc-provider configuration that lives in
/// `~/.vibebar/settings.json`. Sensitive values (API keys, cookie
/// headers, OAuth tokens) live in Keychain — see
/// `MiscCredentialStore` and `CookieHeaderCache`.
///
/// The Codable round-trip rejects any field whose name contains a
/// secret-looking key (`apiKey`, `cookie`, `token`, `password`, etc.).
/// A future contributor that accidentally adds such a field will fail
/// the corresponding test until the rejector list is updated and the
/// secret is moved into Keychain.
public struct MiscProviderSettings: Codable, Equatable, Sendable {
    /// What auth modes the adapter is allowed to try, and in which
    /// order.
    public enum SourceMode: String, Codable, CaseIterable, Sendable {
        case auto         // try cached → browser cookie → manual cookie → API/OAuth
        case browserOnly  // only auto-imported browser cookies
        case manualOnly   // only manually pasted cookie / token
        case apiOnly      // only API key / OAuth file / local probe
        case off          // disabled — adapter returns "not configured"

        public var label: String {
            switch self {
            case .auto:        return "Auto"
            case .browserOnly: return "Browser only"
            case .manualOnly:  return "Manual only"
            case .apiOnly:     return "API / OAuth only"
            case .off:         return "Off"
            }
        }
    }

    public var sourceMode: SourceMode
    public var cookieSource: ProviderCookieSource
    /// Optional region override (e.g. "ap-southeast-1", "cn-beijing"
    /// for Alibaba; provider-specific for others).
    public var region: String?
    /// Self-hosted endpoint override (e.g. GitHub Enterprise for
    /// Copilot, Z.ai self-hosted for Z.ai).
    public var enterpriseHost: URL?
    /// Override the browser auto-import order for this provider.
    public var preferredBrowser: BrowserKind?
    /// Force the misc card on (`true`), force off (`false`), or auto
    /// (`nil`) — auto means "active when at least one credential is
    /// configured."
    public var enabledOverride: Bool?

    public static let `default` = MiscProviderSettings(
        sourceMode: .auto,
        cookieSource: .auto,
        region: nil,
        enterpriseHost: nil,
        preferredBrowser: nil,
        enabledOverride: nil
    )

    public init(
        sourceMode: SourceMode = .auto,
        cookieSource: ProviderCookieSource = .auto,
        region: String? = nil,
        enterpriseHost: URL? = nil,
        preferredBrowser: BrowserKind? = nil,
        enabledOverride: Bool? = nil
    ) {
        self.sourceMode = sourceMode
        self.cookieSource = cookieSource
        self.region = region
        self.enterpriseHost = enterpriseHost
        self.preferredBrowser = preferredBrowser
        self.enabledOverride = enabledOverride
    }

    public var automaticSourceSelection: MiscProviderSettings {
        var copy = self
        copy.sourceMode = .auto
        copy.cookieSource = .auto
        copy.preferredBrowser = nil
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case sourceMode, cookieSource, region, enterpriseHost
        case preferredBrowser, enabledOverride
    }

    /// Substrings (case-insensitive) that, if seen as a JSON key inside
    /// a `MiscProviderSettings` payload, are dropped on decode and
    /// flagged for the caller. The intent is "settings.json must never
    /// hold a secret"; even an honest mistake gets stripped on the way
    /// back in.
    ///
    /// Patterns are deliberately specific — substring-matching on
    /// `cookie` alone would also flag the benign `cookieSource` mode
    /// field, so we match compound names that strongly imply secret
    /// payloads (`cookieHeader`, `accessToken`, etc.) instead.
    public static let sensitiveKeyMarkers: [String] = [
        "apikey", "api_key",
        "cookieheader", "cookie_header",
        "manualcookie", "manual_cookie",
        "importedcookie", "imported_cookie",
        "accesstoken", "access_token",
        "refreshtoken", "refresh_token",
        "bearertoken", "bearer_token",
        "personalaccesstoken", "personal_access_token",
        "patkey", "pat_token",
        "sessionkey", "session_key",
        "sessiontoken", "session_token",
        "password", "passwd",
        "clientsecret", "client_secret",
        "subusername", "sub_username",
        "subpassword", "sub_password"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceMode = try c.decodeIfPresent(SourceMode.self, forKey: .sourceMode) ?? .auto
        self.cookieSource = try c.decodeIfPresent(ProviderCookieSource.self, forKey: .cookieSource) ?? .auto
        self.region = try c.decodeIfPresent(String.self, forKey: .region)
        self.enterpriseHost = try c.decodeIfPresent(URL.self, forKey: .enterpriseHost)
        self.preferredBrowser = try c.decodeIfPresent(BrowserKind.self, forKey: .preferredBrowser)
        self.enabledOverride = try c.decodeIfPresent(Bool.self, forKey: .enabledOverride)
        // Note: `MiscProviderSettings.sanitize(rawJSON:)` is the entry
        // point that scrubs a whole-payload dictionary before
        // JSONDecoder runs. The CodingKeys above are the only fields
        // we accept — anything else (including future "tokenCache",
        // "cookieHeader" mistakes) silently disappears here.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceMode, forKey: .sourceMode)
        try c.encode(cookieSource, forKey: .cookieSource)
        try c.encodeIfPresent(region, forKey: .region)
        try c.encodeIfPresent(enterpriseHost, forKey: .enterpriseHost)
        try c.encodeIfPresent(preferredBrowser, forKey: .preferredBrowser)
        try c.encodeIfPresent(enabledOverride, forKey: .enabledOverride)
    }

    public static func current(for tool: ToolType) -> MiscProviderSettings {
        guard tool.isMisc else { return .default }
        let appSettings = (try? VibeBarLocalStore.readJSON(
            AppSettings.self,
            from: VibeBarLocalStore.settingsURL
        )) ?? .default
        return appSettings.miscProvider(tool).automaticSourceSelection
    }

    public var allowsAPIOrOAuthAccess: Bool {
        switch sourceMode {
        case .auto, .manualOnly, .apiOnly:
            return true
        case .browserOnly, .off:
            return false
        }
    }

    public var allowsLocalProbeAccess: Bool {
        switch sourceMode {
        case .auto, .apiOnly:
            return true
        case .browserOnly, .manualOnly, .off:
            return false
        }
    }

    /// Returns `true` if `rawKey` looks like it might be carrying a
    /// secret. Used by `AppSettings`' lossy decoder to strip such keys
    /// from the misc-providers map before they reach `MiscProviderSettings`.
    public static func looksSensitive(_ rawKey: String) -> Bool {
        let lower = rawKey.lowercased()
        return sensitiveKeyMarkers.contains { lower.contains($0) }
    }

    /// Strip any keys that look like secrets from a deserialized
    /// JSON-style dictionary. Returns the cleaned dictionary plus the
    /// list of dropped keys (callers may want to log a warning).
    public static func sanitize(rawJSON dict: [String: Any]) -> (cleaned: [String: Any], dropped: [String]) {
        var cleaned: [String: Any] = [:]
        var dropped: [String] = []
        for (key, value) in dict {
            if looksSensitive(key) {
                dropped.append(key)
            } else {
                cleaned[key] = value
            }
        }
        return (cleaned, dropped)
    }
}
