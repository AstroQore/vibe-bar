import Foundation

/// Where the credential a `QuotaAdapter` will use was sourced from.
///
/// Primary providers (Codex, Claude) use `cliDetected` (CLI keychain /
/// auth.json) and `webCookie` (Claude WKWebView login). Misc providers
/// add the cases they need:
///
/// - `apiToken` — user pasted an API key / PAT in Settings.
/// - `browserCookie` — auto-imported from Chrome / Edge / Brave / Arc /
///   Safari / Firefox via SweetCookieKit.
/// - `manualCookie` — user pasted a `Cookie:` header in Settings.
/// - `oauthCLI` — read from a sibling CLI's OAuth credential file
///   (e.g. `~/.gemini/oauth_creds.json`).
/// - `localProbe` — discovered by probing a locally running process
///   (e.g. AntiGravity language server via `lsof`).
/// - `notConfigured` — placeholder used by `AccountStore` so a misc
///   provider gets a stable account id even when no credential is
///   set. The accompanying `AccountQuota` carries a setup-state
///   `QuotaError`; the card renders as a "Set up" call-to-action.
public enum CredentialSource: String, Codable, Sendable {
    case cliDetected
    case webCookie
    case apiToken
    case browserCookie
    case manualCookie
    case oauthCLI
    case localProbe
    case notConfigured
}
