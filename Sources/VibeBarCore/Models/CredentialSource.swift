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
/// - `oauthCLI` — primary-provider OAuth credentials sourced from
///   provider CLI auth material. For OpenAI this is Codex
///   `auth.json`; for Claude/Gemini this is the provider's local
///   OAuth credential file.
/// - `localProbe` — discovered by probing a locally running process
///   (e.g. AntiGravity language server via `lsof`).
/// - `notConfigured` — placeholder used by `AccountStore` so a misc
///   provider gets a stable account id even when no credential is
///   set. The accompanying `AccountQuota` carries a setup-state
///   `QuotaError`; the card renders as a "Set up" call-to-action.
public enum CredentialSource: String, Codable, Sendable {
    case cliDetected
    case webCookie
    case oauthCLI
    case apiToken
    case browserCookie
    case manualCookie
    case localProbe
    case notConfigured
}
