import Foundation

public enum QuotaError: Error, Equatable, Hashable, Sendable {
    case noCredential
    case needsLogin
    case network(String)
    case rateLimited
    case parseFailure(String)
    case notImplemented
    case unknown(String)

    public var userFacingMessage: String {
        switch self {
        case .noCredential:    return "No account found"
        case .needsLogin:      return "Needs re-login"
        case .network(let m):  return "Network error\(m.isEmpty ? "" : ": \(m)")"
        case .rateLimited:     return "Rate limited, try later"
        case .parseFailure:    return "Response format changed"
        case .notImplemented:  return "Not yet supported"
        case .unknown(let m):  return "Error\(m.isEmpty ? "" : ": \(m)")"
        }
    }

    public var isCredentialState: Bool {
        switch self {
        case .noCredential, .needsLogin:
            return true
        case .network, .rateLimited, .parseFailure, .notImplemented, .unknown:
            return false
        }
    }
}
