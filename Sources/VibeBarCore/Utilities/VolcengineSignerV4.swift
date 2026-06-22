import CryptoKit
import Foundation

/// Volcengine OpenAPI request signer (Signature V4, algorithm label
/// `HMAC-SHA256`).
///
/// The scheme is AWS-SigV4-shaped but with one crucial difference: the
/// signing-key chain seeds directly from the **raw** Secret Access Key —
/// there is no `AWS4` prefix. The credential scope is
/// `<YYYYMMDD>/<region>/<service>/request`, and signed requests carry
/// `X-Date`, `X-Content-Sha256`, and `Authorization` headers.
///
/// We use it to sign the public Ark OpenAPI (host
/// `ark.cn-beijing.volces.com`, service `ark`, region `cn-beijing`) so the
/// Volcengine adapters can read plan usage with a user's AK/SK instead of
/// console cookies. The console BFF (`console.volcengine.com/api/top/...`)
/// and the signed OpenAPI are two front doors to the same backend, so the
/// response schemas match.
///
/// Pinned to Volcengine's official worked example
/// (https://www.volcengine.com/docs/6369/67270) by
/// `VolcengineSignerV4Tests`.
public struct VolcengineSignerV4 {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let region: String
    public let service: String

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.service = service
    }

    public struct Signature {
        public let authorization: String
        public let signature: String
    }

    /// Convenience for the Ark POST case: signs `host;x-content-sha256;x-date`
    /// and returns the headers to set on the request (`Authorization`,
    /// `X-Date`, `X-Content-Sha256`). The caller still sets `Host` (implied
    /// by the URL) and `Content-Type`.
    public func headers(
        method: String = "POST",
        host: String,
        canonicalURI: String = "/",
        query: [(String, String)],
        body: Data,
        date: Date
    ) -> [String: String] {
        let xDate = Self.timestamp(date)
        let payloadHash = Self.sha256Hex(body)
        let result = makeSignature(
            method: method,
            canonicalURI: canonicalURI,
            query: query,
            signedHeaders: [
                ("host", host),
                ("x-content-sha256", payloadHash),
                ("x-date", xDate)
            ],
            payloadHash: payloadHash,
            xDate: xDate
        )
        return [
            "Authorization": result.authorization,
            "X-Date": xDate,
            "X-Content-Sha256": payloadHash
        ]
    }

    /// Core deterministic signer. `signedHeaders` are normalized
    /// (lowercased name, trimmed value) and sorted here, so callers may pass
    /// them in any case/order; `xDate` is the matching `YYYYMMDDTHHMMSSZ`
    /// stamp.
    func makeSignature(
        method: String,
        canonicalURI: String,
        query: [(String, String)],
        signedHeaders: [(String, String)],
        payloadHash: String,
        xDate: String
    ) -> Signature {
        let normalized = signedHeaders
            .map { ($0.0.lowercased(), $0.1.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
        let canonical = Self.canonicalRequest(
            method: method,
            canonicalURI: canonicalURI,
            query: query,
            signedHeaders: normalized,
            payloadHash: payloadHash
        )
        let dateStamp = String(xDate.prefix(8))
        let credentialScope = "\(dateStamp)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            Self.sha256Hex(Data(canonical.utf8))
        ].joined(separator: "\n")
        let key = Self.signingKey(
            secretAccessKey: secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = Self.hexEncode(Self.hmac(stringToSign, key: key))
        let signedHeaderNames = normalized.map { $0.0 }.joined(separator: ";")
        let authorization = "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaderNames), Signature=\(signature)"
        return Signature(authorization: authorization, signature: signature)
    }

    // MARK: - Primitives (pinned by tests against the official vector)

    /// Builds the canonical request string. `signedHeaders` must already be
    /// lowercased + sorted (see `makeSignature`); the query is sorted here.
    static func canonicalRequest(
        method: String,
        canonicalURI: String,
        query: [(String, String)],
        signedHeaders: [(String, String)],
        payloadHash: String
    ) -> String {
        // Built with explicit loops/types rather than chained closures over
        // tuples — the latter blows up Swift's type-checker.
        let encoded: [(String, String)] = query.map { pair in
            (rfc3986(pair.0), rfc3986(pair.1))
        }
        let sortedPairs = encoded.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        var queryComponents: [String] = []
        for pair in sortedPairs {
            queryComponents.append(pair.0 + "=" + pair.1)
        }
        let canonicalQuery = queryComponents.joined(separator: "&")

        var headerLines: [String] = []
        for header in signedHeaders {
            headerLines.append(header.0 + ":" + header.1 + "\n")
        }
        let canonicalHeaders = headerLines.joined()

        var headerNames: [String] = []
        for header in signedHeaders {
            headerNames.append(header.0)
        }
        let signedHeaderNames = headerNames.joined(separator: ";")
        // `canonicalHeaders` already ends in "\n"; joining the parts with
        // "\n" therefore yields the required blank line before the signed
        // header list, matching the AWS-SigV4-shaped layout.
        let parts = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaderNames,
            payloadHash
        ]
        return parts.joined(separator: "\n")
    }

    /// `HMAC(HMAC(HMAC(HMAC(SK, date), region), service), "request")`.
    /// Note: seeds from the raw SK, **not** `"AWS4" + SK`.
    static func signingKey(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> Data {
        let kDate = hmac(dateStamp, key: Data(secretAccessKey.utf8))
        let kRegion = hmac(region, key: kDate)
        let kService = hmac(service, key: kRegion)
        return hmac("request", key: kService)
    }

    static func hmac(_ message: String, key: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(code)
    }

    public static func sha256Hex(_ data: Data) -> String {
        hexEncode(Data(SHA256.hash(data: data)))
    }

    static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// `YYYYMMDDTHHMMSSZ` in UTC. Built from `DateComponents` to avoid
    /// `DateFormatter` locale/timezone pitfalls.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    private static func rfc3986(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
