import Foundation

public enum QuotaError: Error, Equatable, Hashable, Sendable {
    case noCredential
    case needsLogin
    /// The key we hold was rejected by the provider (typically HTTP
    /// 401/403 on an API-key, PAT, or AK/SK path).
    ///
    /// Distinct from `.needsLogin`, which means "the browser session
    /// expired — sign in again": on a key provider there is no session to
    /// refresh, only a credential to replace, and telling the user to
    /// re-login sends them to the wrong control entirely. The associated
    /// message names the field and the fix; it is provider copy, never a
    /// credential value.
    case credentialRejected(String)
    case network(String)
    case rateLimited
    case parseFailure(String)
    case notImplemented
    case unknown(String)

    public var userFacingMessage: String {
        switch self {
        case .noCredential:    return L10n.Errors.noCredential
        case .needsLogin:      return L10n.Errors.needsLogin
        case .credentialRejected(let m):
            // The payload is the provider's own copy, so it stays as it
            // arrived: translating it here would mean inventing a Chinese
            // sentence for text this build has never seen.
            return m.isEmpty ? L10n.Errors.credentialRejected : m
        case .network(let m):
            return m.isEmpty
                ? L10n.Errors.network
                : L10n.Errors.networkDetail(reason: m)
        case .rateLimited:     return L10n.Errors.rateLimited
        // The adapter's own diagnosis is the whole point of the payload:
        // "no Coding Plan subscription on this account" is actionable in a
        // way "Response format changed" never was. Only a genuinely empty
        // message falls back to the generic line.
        case .parseFailure(let m):
            return m.isEmpty ? L10n.Errors.parseFailure : m
        case .notImplemented:  return L10n.Errors.notImplemented
        case .unknown(let m):
            return m.isEmpty
                ? L10n.Errors.unknown
                : L10n.Errors.unknownDetail(reason: m)
        }
    }

    /// The same text, safe to hand to `os_log`.
    ///
    /// `userFacingMessage` can carry a payload an adapter lifted verbatim
    /// out of a provider response, and `os_log` lines written at
    /// `.public` are readable outside this process and end up in
    /// sysdiagnose bundles.
    ///
    /// Both redactors run, because neither is sufficient alone:
    /// `SafeLog.sanitize` masks 20+ character token runs but an address
    /// splits at the `@` into two shorter ones, so `EmailMasker` has to go
    /// first. The pair is deliberately aggressive here — it also eats
    /// dotted hostnames, which a log line can afford to lose.
    public var logSafeMessage: String {
        SafeLog.sanitize(ProviderDiagnosticRedactor.maskEmails(in: userFacingMessage))
    }

    /// The projection for the MCP surface, where the reader is an agent
    /// rather than the person whose machine this is.
    ///
    /// Same concern as `logSafeMessage`, different trade-off: an agent
    /// acting on "no Coding Plan subscription — set up the Agent Plan
    /// card" needs the actionable half of the message intact, so this
    /// masks addresses and opaque identifiers without flattening ordinary
    /// hostnames, and caps the length so a provider stack trace cannot
    /// flood the agent's context.
    public var agentFacingMessage: String {
        ProviderDiagnosticRedactor.redact(userFacingMessage)
    }

    /// True when the failure is about *which credential we hold* rather
    /// than about the response. Drives the cached-quota grace period in
    /// `QuotaService` and the silent cookie re-import in
    /// `MiscCookieAutoImporter`.
    public var isCredentialState: Bool {
        switch self {
        case .noCredential, .needsLogin, .credentialRejected:
            return true
        case .network, .rateLimited, .parseFailure, .notImplemented, .unknown:
            return false
        }
    }
}
