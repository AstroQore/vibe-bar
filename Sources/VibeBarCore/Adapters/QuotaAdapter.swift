import Foundation

/// One adapter per ToolType. The account argument is enough to locate the
/// credential and shape the request; the adapter must not assume anything
/// about UI state.
public protocol QuotaAdapter: Sendable {
    var tool: ToolType { get }
    func fetch(for account: AccountIdentity) async throws -> AccountQuota
}

/// Map common URLError cases into QuotaError.
public func mapURLError(_ error: Error) -> QuotaError {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .network("offline")
        case .timedOut:
            return .network("timeout")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("host unreachable")
        default:
            return .network(urlError.localizedDescription)
        }
    }
    if let q = error as? QuotaError { return q }
    return .unknown(String(describing: type(of: error)))
}
