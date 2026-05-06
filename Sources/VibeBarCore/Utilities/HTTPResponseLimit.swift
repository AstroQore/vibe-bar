import Foundation

/// Defense-in-depth size cap for HTTP responses. Vibe Bar talks to a small
/// set of well-known public endpoints (claude.ai, api.anthropic.com,
/// platform.openai.com, status pages); a misbehaving or compromised one
/// streaming an unbounded payload would otherwise be buffered into memory by
/// `URLSession.data(for:)` and fed straight to the JSON / regex pipeline.
///
/// 4 MB comfortably holds the largest legitimate response we see (Statuspage
/// HTML, typically < 1 MB) while refusing pathological sizes.
public enum HTTPResponseLimit {
    public static let defaultMaxBytes = 4 * 1024 * 1024

    public enum BoundedError: Error, Sendable, Equatable {
        case responseTooLarge(limit: Int)
    }

    public static func boundedData(
        from session: URLSession,
        for request: URLRequest,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        if data.count > maxBytes {
            throw BoundedError.responseTooLarge(limit: maxBytes)
        }
        return (data, response)
    }
}
