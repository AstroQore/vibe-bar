import Foundation

/// Decoded usage snapshot from grok.com's billing endpoint. The wire
/// format is a gRPC-web `connect-es` response carrying a protobuf
/// payload. We don't depend on a generated proto stub — instead a
/// best-effort scanner pulls the weekly used-percent (`fixed32` field)
/// and the next reset timestamp (`varint` seconds since epoch) out of
/// the bytes.
public struct GrokWebBillingSnapshot: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Posts to `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
/// with the bearer token from `~/.grok/auth.json` and parses the
/// gRPC-web protobuf response.
///
/// Mirror of Codex Bar's implementation; the wire format is owned by
/// xAI and may change without notice. If the proto layout shifts, the
/// scanner falls back to "parse failure" instead of crashing.
public enum GrokWebBillingFetcher {
    public static let defaultEndpoint =
        URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetch(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> GrokWebBillingSnapshot {
        try await Self.fetch(
            authorizationHeader: "Bearer \(credentials.accessToken)",
            cookieHeader: nil,
            session: session,
            endpoint: endpoint,
            now: now
        )
    }

    /// Cookie-authenticated overload. Used when `~/.grok/auth.json` is
    /// absent and the user has imported grok.com cookies from a
    /// signed-in browser session. xAI's billing endpoint accepts
    /// either Bearer or Cookie auth — Codex Bar exercises both paths
    /// in parallel; Vibe Bar picks one based on which credential the
    /// adapter found.
    public static func fetch(
        cookieHeader: String,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> GrokWebBillingSnapshot {
        try await Self.fetch(
            authorizationHeader: nil,
            cookieHeader: cookieHeader,
            session: session,
            endpoint: endpoint,
            now: now
        )
    }

    private static func fetch(
        authorizationHeader: String?,
        cookieHeader: String?,
        session: URLSession,
        endpoint: URL,
        now: @Sendable () -> Date
    ) async throws -> GrokWebBillingSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        // URLSession.shared shares the system HTTP cookie jar — that
        // can quietly inject stale grok.com cookies on every request,
        // which conflicts with the bearer header and trips xAI's auth
        // gate. We pass the cookie header ourselves (or nothing) and
        // tell URLSession to stay out of it.
        request.httpShouldHandleCookies = false
        // Empty gRPC-web message frame: 1-byte flags + 4-byte big-endian
        // length (zero). Matches what xAI's web UI sends.
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapURLError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Grok: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("Grok returned HTTP \(http.statusCode).")
        }

        try validateGRPCStatus(headers: http.allHeaderFields)
        try validateGRPCTrailers(data)
        return try Self.parseGRPCWebResponse(data, now: now())
    }

    // MARK: - gRPC-web framing

    /// Walks the gRPC-web length-prefixed frames and returns the data
    /// frames (flag bit 0x80 unset). Trailers (flag bit 0x80 set) are
    /// inspected separately by `grpcWebTrailerFields`.
    static func dataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    static func grpcWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0,
               let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    private static func grpcStatusFields(from headers: [AnyHashable: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedKey.hasPrefix("grpc-") else { continue }
            fields[normalizedKey] = String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .removingPercentEncoding ?? ""
        }
        return fields
    }

    private static func validateGRPCStatus(headers: [AnyHashable: Any]) throws {
        try validateStatus(fields: grpcStatusFields(from: headers))
    }

    private static func validateGRPCTrailers(_ data: Data) throws {
        try validateStatus(fields: grpcWebTrailerFields(from: data))
    }

    private static func validateStatus(fields: [String: String]) throws {
        guard let rawStatus = fields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else { return }
        if status == 16 {
            throw QuotaError.needsLogin
        }
        let message = fields["grpc-message"] ?? "status \(status)"
        throw QuotaError.network("Grok RPC failed: \(message)")
    }

    // MARK: - Protobuf scanner

    static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) throws -> GrokWebBillingSnapshot {
        let payloads = dataFrames(from: data)
        guard !payloads.isEmpty else {
            throw QuotaError.parseFailure("Grok billing response had no data frames.")
        }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(Self.scanProtobuf(payload, depth: 0))
        }

        // The smallest "field number 1" fixed32 in the payload is the
        // weekly used-percent. Picking the shallowest path keeps us
        // pointed at the top-level usage object instead of a nested
        // sub-bucket that happens to share field=1.
        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path.last == 1
                    && field.value.isFinite
                    && field.value >= 0
                    && field.value <= 100
            }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count
                    ? lhs.order < rhs.order
                    : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        // Reset timestamps are varint seconds since epoch. Prefer the
        // `[1, 5, 1]` path (billing cycle end) when present, otherwise
        // fall back to the earliest future timestamp.
        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset = futureResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min() ?? futureResetFields
            .map(\.date)
            .min()

        // Accounts at exactly 0% omit the default-valued percent fixed32.
        // xAI's older payloads carried allotments under field 6; current
        // payloads repeat the weekly reset under `[1, 8, 3, 1]`. Require one
        // of those known billing markers plus a future reset so an unrelated
        // reset-only protobuf is not mistaken for zero usage.
        let hasLegacyAllotmentMarker = scan.varintFields.contains {
            $0.path.starts(with: [1, 6])
        }
        let hasWeeklyWindowMarker = scan.varintFields.contains { field in
            guard field.path == [1, 8, 3, 1], let reset else { return false }
            return reset == Date(timeIntervalSince1970: TimeInterval(field.value))
        }
        let noUsageYet = parsedPercent == nil
            && scan.fixed32Fields.isEmpty
            && reset != nil
            && (hasLegacyAllotmentMarker || hasWeeklyWindowMarker)
        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            throw QuotaError.parseFailure("Grok billing protobuf had no usage field.")
        }
        return GrokWebBillingSnapshot(usedPercent: percent, resetsAt: reset)
    }

    private struct ProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }

        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: ProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: ProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = readVarint(bytes, index: &index) {
                    scan.varintFields.append(ProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = scanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder
                    )
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(ProtobufScan.Fixed32Field(
                    path: fieldPath,
                    value: Float(bitPattern: bitPattern),
                    order: nextOrder
                ))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }

        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
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
}
