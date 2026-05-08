import Foundation

public enum ClaudeOrganizationIDFetcher {
    private static let endpoint = URL(string: "https://claude.ai/api/organizations")!

    public static func fetch(cookieHeader: String, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        configureClaudeWebHeaders(&request, cookieHeader: cookieHeader)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPResponseLimit.boundedData(from: session, for: request)
        } catch {
            SafeLog.net("Claude organization fetch failed: \(SafeLog.sanitize(error.localizedDescription))")
            throw mapURLError(error)
        }

        try validateClaudeWebResponse(response)
        let organizationID = try parse(data: data)
        try? ClaudeWebCookieStore.writeOrganizationID(organizationID)
        return organizationID
    }

    public static func parse(data: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw QuotaError.parseFailure("invalid organizations json")
        }
        guard let id = organizationID(from: json) else {
            throw QuotaError.parseFailure("no Claude organization id")
        }
        return id
    }

    private static func configureClaudeWebHeaders(_ request: inout URLRequest, cookieHeader: String) {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        request.setValue("claude.ai", forHTTPHeaderField: "Origin")
    }

    private static func validateClaudeWebResponse(_ response: URLResponse) throws {
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case .some(200), .none:
            break
        case .some(401), .some(403):
            throw QuotaError.needsLogin
        case .some(429):
            throw QuotaError.rateLimited
        case .some(let code) where code >= 500:
            throw QuotaError.network("server \(code)")
        case .some(let code):
            throw QuotaError.unknown("HTTP \(code)")
        }
    }

    private static func organizationID(from object: Any?) -> String? {
        let candidates = organizationCandidates(from: object)
        return candidates.first(where: \.hasChatCapability)?.id
            ?? candidates.first(where: { !$0.isApiOnly })?.id
            ?? candidates.first?.id
    }

    private struct OrganizationCandidate {
        let id: String
        let capabilities: Set<String>

        var hasChatCapability: Bool {
            capabilities.contains("chat")
        }

        var isApiOnly: Bool {
            !capabilities.isEmpty && capabilities == ["api"]
        }
    }

    private static func organizationCandidates(from object: Any?) -> [OrganizationCandidate] {
        if let dict = object as? [String: Any] {
            var candidates: [OrganizationCandidate] = []
            for key in ["uuid", "id", "organization_uuid", "organizationId"] {
                if let raw = dict[key] as? String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        candidates.append(OrganizationCandidate(
                            id: trimmed,
                            capabilities: capabilities(from: dict["capabilities"])
                        ))
                        break
                    }
                }
            }
            for key in ["organization", "current_organization"] {
                candidates.append(contentsOf: organizationCandidates(from: dict[key]))
            }
            for key in ["organizations", "data", "results"] {
                candidates.append(contentsOf: organizationCandidates(from: dict[key]))
            }
            return candidates
        }
        if let array = object as? [Any] {
            return array.flatMap { organizationCandidates(from: $0) }
        }
        return []
    }

    private static func capabilities(from object: Any?) -> Set<String> {
        guard let values = object as? [Any] else { return [] }
        return Set(values.compactMap { raw in
            guard let string = raw as? String else { return nil }
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }
}
