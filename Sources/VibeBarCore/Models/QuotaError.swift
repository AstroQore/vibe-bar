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
        case .noCredential:    return "No account found"
        case .needsLogin:      return "Needs re-login"
        case .credentialRejected(let m):
            return m.isEmpty ? "Credential rejected" : m
        case .network(let m):  return "Network error\(m.isEmpty ? "" : ": \(m)")"
        case .rateLimited:     return "Rate limited, try later"
        // The adapter's own diagnosis is the whole point of the payload:
        // "no Coding Plan subscription on this account" is actionable in a
        // way "Response format changed" never was. Only a genuinely empty
        // message falls back to the generic line.
        case .parseFailure(let m):
            return m.isEmpty ? "Response format changed" : m
        case .notImplemented:  return "Not yet supported"
        case .unknown(let m):  return "Error\(m.isEmpty ? "" : ": \(m)")"
        }
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
