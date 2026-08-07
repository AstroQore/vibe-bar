import Foundation

/// One row of a skills.sh search response, after validation.
public struct SkillsShSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(repo.descriptor)#\(name)" }
    public let name: String
    /// Install count as reported by the index; absent when the field is
    /// missing or not a number.
    public let installs: Int?
    public let repo: SkillRepoRef

    public init(name: String, installs: Int?, repo: SkillRepoRef) {
        self.name = name
        self.installs = installs
        self.repo = repo
    }
}

public enum SkillsSearchError: Error, Equatable, Sendable {
    case emptyQuery
    case badRequest
    case notHTTP
    case httpStatus(Int)
    case malformedResponse
}

extension SkillsSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Enter something to search for."
        case .badRequest: return "The search query could not be encoded."
        case .notHTTP: return "skills.sh did not return an HTTP response."
        case let .httpStatus(code): return "skills.sh returned HTTP \(code)."
        case .malformedResponse: return "skills.sh returned an unrecognized response."
        }
    }
}

/// Read-only client for the skills.sh community index.
///
/// One unauthenticated GET, no API key, no account: the index only answers
/// with a name, an install count, and an `owner/repo` source. That last field
/// is the only one that matters — it is what the rest of the feature turns into
/// a download URL — so a row whose `source` does not pass `SkillRepoRef`
/// validation is dropped rather than repaired. Everything else is decoded
/// tolerantly, because this is a third-party index whose schema is not ours:
/// unknown keys are ignored, `id`/`skillId` stand in for a missing `name`, and
/// an install count that arrives as a string is still read as a number.
///
/// The response is size-capped through `HTTPResponseLimit`; the search string
/// itself never reaches the log, only the endpoint's host and path.
public struct SkillsSearchClient: Sendable {
    public static let host = "skills.sh"
    public static let searchPath = "/api/search"
    public static let maxResponseBytes = 4 * 1024 * 1024
    public static let defaultTimeout: TimeInterval = 10
    public static let defaultLimit = 25
    public static let maxLimit = 100

    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = SkillsSearchClient.defaultTimeout) {
        self.session = session
        self.timeout = timeout
    }

    public func search(
        _ query: String,
        limit: Int = SkillsSearchClient.defaultLimit
    ) async throws -> [SkillsShSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillsSearchError.emptyQuery }
        guard let url = Self.searchURL(query: trimmed, limit: limit) else {
            throw SkillsSearchError.badRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeBar/skills", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await HTTPResponseLimit.boundedData(
            from: session,
            for: request,
            maxBytes: Self.maxResponseBytes
        )
        guard let http = response as? HTTPURLResponse else { throw SkillsSearchError.notHTTP }
        guard http.statusCode == 200 else { throw SkillsSearchError.httpStatus(http.statusCode) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw SkillsSearchError.malformedResponse
        }
        return payload.skills.compactMap(\.result)
    }

    static func searchURL(query: String, limit: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = searchPath
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), maxLimit)))
        ]
        return components.url
    }

    // MARK: - Wire shape

    private struct Payload: Decodable {
        let skills: [Row]

        private enum CodingKeys: String, CodingKey { case skills }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            skills = ((try? container.decodeIfPresent([Row].self, forKey: .skills)) ?? nil) ?? []
        }
    }

    /// Decodes to `nil` rather than throwing on any row shape we cannot use, so
    /// one bad entry never costs the user the rest of the results.
    private struct Row: Decodable {
        let result: SkillsShSearchResult?

        private enum CodingKeys: String, CodingKey {
            case id, skillId, name, installs, source
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                result = nil
                return
            }
            let name = Self.string(container, .name)
                ?? Self.string(container, .skillId)
                ?? Self.string(container, .id)
            guard
                let source = Self.string(container, .source),
                let repo = SkillRepoRef(source),
                let name, !name.isEmpty
            else {
                result = nil
                return
            }
            result = SkillsShSearchResult(
                name: name,
                installs: Self.installs(from: container),
                repo: repo
            )
        }

        private static func string(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> String? {
            guard
                let raw = ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { return nil }
            return raw
        }

        private static func installs(from container: KeyedDecodingContainer<CodingKeys>) -> Int? {
            if let value = ((try? container.decodeIfPresent(Int.self, forKey: .installs)) ?? nil) {
                return value
            }
            if let value = ((try? container.decodeIfPresent(Double.self, forKey: .installs)) ?? nil),
               value.isFinite {
                return Int(value)
            }
            return Self.string(container, .installs).flatMap(Int.init)
        }
    }
}
