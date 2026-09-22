import Foundation

/// SuperGrok usage-limit reset tokens.
///
/// `POST https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets`
/// with the `grok login` bearer from `~/.grok/auth.json`, gRPC-Web framing
/// and an empty request message. The reply is
/// `ConsumerGetRemainingResetsResp { repeated ConsumerResetToken tokens = 10; }`,
/// each token carrying `token_id = 10` and the `google.protobuf.Timestamp`s
/// `validity_start = 20` / `validity_end = 30`.
///
/// Only the bearer path is used: the same call with copied browser cookies
/// is answered by Cloudflare with a 403 page. The bearer is not always let
/// through either — Cloudflare can answer this path with a challenge
/// (`cf-mitigated: challenge`, HTTP 403) while the billing RPC on the same
/// host succeeds — which is one more reason every failure here is silent.
///
/// gRPC reports failure in a trailer frame behind HTTP 200, so the status is
/// checked before a count is believed — otherwise a rejected token would read
/// as an authoritative "no resets". `token_id` is the handle that spends a
/// reset; only its SHA-256 leaves the parser.
///
/// Silent on every failure: `nil` means "no answer", never "no tokens".
public enum GrokRemainingResetsFetcher {
    public static let defaultEndpoint =
        URL(string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets")!
    private static let requestTimeoutSeconds: TimeInterval = 8
    /// Grok's tokens reset the weekly allowance, the only window it reports.
    static let clearedBucketIDs = ["weekly"]

    public struct Response: Sendable, Equatable {
        public var httpStatus: Int
        public var grpcStatus: Int?
        public var credits: ResetCredits?
    }

    public static func fetch(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint,
        now: Date = Date()
    ) async -> ResetCredits? {
        guard await RefusalBackoff.shared.allows(now: now) else { return nil }
        let response = await fetchResponse(credentials: credentials, session: session, endpoint: endpoint, now: now)
        if let response, response.httpStatus != 200 || (response.grpcStatus ?? 0) != 0 {
            await RefusalBackoff.shared.refused(at: now)
        }
        return response?.credits
    }

    /// A refused call (a Cloudflare challenge, a rejected key) is not retried
    /// on every Grok refresh: it would cost a 6 KB challenge page each time
    /// for an answer that will not change within minutes.
    actor RefusalBackoff {
        static let shared = RefusalBackoff()
        static let interval: TimeInterval = 6 * 3_600
        private var lastRefusal: Date?

        func allows(now: Date) -> Bool {
            guard let lastRefusal else { return true }
            return now.timeIntervalSince(lastRefusal) >= Self.interval
        }

        func refused(at now: Date) { lastRefusal = now }
    }

    /// The whole outcome, for diagnostics; `fetch` is what the adapter uses.
    public static func fetchResponse(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint,
        now: Date = Date()
    ) async -> Response? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpShouldHandleCookies = false
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        // Marks the bearer as a Grok Build CLI key, as other clients of this
        // RPC send it.
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else {
            return Response(httpStatus: http.statusCode, grpcStatus: nil, credits: nil)
        }
        let status = grpcStatus(headers: http.allHeaderFields, body: data)
        guard status == nil || status == 0 else {
            return Response(httpStatus: 200, grpcStatus: status, credits: nil)
        }
        return Response(httpStatus: 200, grpcStatus: status ?? 0, credits: parse(data, now: now))
    }

    /// The call's gRPC status, from the headers or the trailer frame; `nil`
    /// when neither carries one (success, by the protocol's default).
    static func grpcStatus(headers: [AnyHashable: Any], body: Data) -> Int? {
        for (key, value) in headers where String(describing: key).lowercased() == "grpc-status" {
            if let status = Int(String(describing: value).trimmingCharacters(in: .whitespaces)) { return status }
        }
        return GrokWebBillingFetcher.grpcWebTrailerFields(from: body)["grpc-status"].flatMap { Int($0) }
    }

    /// Parses a gRPC-Web response body. `nil` for a failed status in the
    /// trailer, a torn frame, or a message this cannot read.
    public static func parse(_ data: Data, now: Date = Date()) -> ResetCredits? {
        let bytes = [UInt8](data)
        var index = 0
        var tokens: [ResetCreditToken] = []
        while index < bytes.count {
            guard index + 5 <= bytes.count else { return nil }
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24) | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8) | Int(bytes[index + 4])
            let start = index + 5
            guard length >= 0, start + length <= bytes.count else { return nil }
            let frame = Array(bytes[start..<(start + length)])
            if flags & 0x80 != 0 {
                let trailer = GrokWebBillingFetcher.grpcWebTrailerFields(from: Data(bytes[index..<(start + length)]))
                if let status = trailer["grpc-status"], status != "0" { return nil }
            } else if flags == 0 {
                guard let parsed = parseResponseMessage(frame) else { return nil }
                tokens += parsed
            } else {
                return nil
            }
            index = start + length
        }
        let live = tokens.filter { $0.expiresAt.map { $0 > now } ?? true }
        let expirations = live.compactMap(\.expiresAt)
        return ResetCredits(
            availableCount: live.count,
            availableExpirations: expirations.count == live.count ? expirations : nil,
            tokens: tokens,
            inferenceRequiresObservedReset: true)
    }

    private static func parseResponseMessage(_ bytes: [UInt8]) -> [ResetCreditToken]? {
        var tokens: [ResetCreditToken] = []
        var index = 0
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            if key == (10 << 3 | 2) {
                guard let body = readDelimited(bytes, &index), let token = parseToken(body) else { return nil }
                tokens.append(token)
            } else if !skip(bytes, &index, wireType: key & 7) {
                return nil
            }
        }
        return tokens
    }

    private static func parseToken(_ bytes: [UInt8]) -> ResetCreditToken? {
        var rawID: String?
        var validityEnd: Date?
        var index = 0
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            switch key {
            case 10 << 3 | 2:
                guard let body = readDelimited(bytes, &index) else { return nil }
                rawID = String(decoding: body, as: UTF8.self)
            case 30 << 3 | 2:
                guard let body = readDelimited(bytes, &index) else { return nil }
                validityEnd = timestamp(body)
            default:
                guard skip(bytes, &index, wireType: key & 7) else { return nil }
            }
        }
        guard let rawID, !rawID.isEmpty else { return nil }
        return ResetCreditToken(
            id: PrivacyPreservingHash.fileComponent(prefix: "grok-reset", rawValue: rawID),
            remaining: 1, expiresAt: validityEnd, clears: clearedBucketIDs)
    }

    /// `google.protobuf.Timestamp { int64 seconds = 1; int32 nanos = 2; }`.
    private static func timestamp(_ bytes: [UInt8]) -> Date? {
        var index = 0
        var seconds: UInt64?
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            if key == (1 << 3 | 0) {
                seconds = readVarint(bytes, &index)
            } else if !skip(bytes, &index, wireType: key & 7) {
                return nil
            }
        }
        guard let seconds, seconds > 0, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func readDelimited(_ bytes: [UInt8], _ index: inout Int) -> [UInt8]? {
        guard let length = readVarint(bytes, &index), length <= UInt64(bytes.count - index) else { return nil }
        let end = index + Int(length)
        defer { index = end }
        return Array(bytes[index..<end])
    }

    private static func skip(_ bytes: [UInt8], _ index: inout Int, wireType: UInt64) -> Bool {
        switch wireType {
        case 0: return readVarint(bytes, &index) != nil
        case 1: guard index + 8 <= bytes.count else { return false }; index += 8; return true
        case 2: return readDelimited(bytes, &index) != nil
        case 5: guard index + 4 <= bytes.count else { return false }; index += 4; return true
        default: return false
        }
    }
}
