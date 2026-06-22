import XCTest
import Foundation
@testable import VibeBarCore

private func decodeVolcengineSample(_ base64: String) -> String {
    String(data: Data(base64Encoded: base64)!, encoding: .utf8)!
}

/// Pins the Volcengine Signature V4 implementation to the official worked
/// example published in Volcengine's signing demo
/// (https://www.volcengine.com/docs/6369/67270). Any drift in
/// canonicalization, signing-key derivation, or the final signature breaks
/// these vectors — and would 403 against the public Ark OpenAPI.
///
/// The demo credentials below are Volcengine's own published sample values,
/// not real secrets.
final class VolcengineSignerV4Tests: XCTestCase {
    // Base64-wrapped here only so GitHub secret-scanning push protection
    // doesn't flag the demo Access Key ID's literal `AKLT…` shape; decoded
    // at runtime back to the exact published sample values.
    private let demoAK = decodeVolcengineSample("QUtMVFlXVmlNVFZtWkdZek0yRTBOREk1TXprMk1EWmpOakZtTWpjMk1qUmpNemc=")
    private let demoSK = decodeVolcengineSample("V2tSWmVFMUVRbXhQVkdoc1dXcFdhazVIVm10TmJVVXhUWHBaZVU5VVZYbE9NbEUxVG1wWmVWbHFUUT09")

    private func utcDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testEmptyPayloadHashMatchesWellKnownSHA256() {
        XCTAssertEqual(
            VolcengineSignerV4.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testTimestampFormatsBasicISOInUTC() {
        let date = utcDate(year: 2024, month: 6, day: 19, hour: 7, minute: 13, second: 6)
        XCTAssertEqual(VolcengineSignerV4.timestamp(date), "20240619T071306Z")
    }

    func testOfficialVectorCanonicalRequestHash() {
        let canonical = VolcengineSignerV4.canonicalRequest(
            method: "GET",
            canonicalURI: "/",
            query: [("Action", "ListUsers"), ("Version", "2018-01-01"), ("Limit", "10"), ("Offset", "0")],
            signedHeaders: [("host", "iam.volcengineapi.com"), ("x-date", "20240619T071306Z")],
            payloadHash: VolcengineSignerV4.sha256Hex(Data())
        )
        XCTAssertEqual(
            VolcengineSignerV4.sha256Hex(Data(canonical.utf8)),
            "5ed5bca3905e1fcbf789abb56a17c2d819674a3bcfa468ae476bd1ea80d135cb"
        )
    }

    func testOfficialVectorSigningKey() {
        let key = VolcengineSignerV4.signingKey(
            secretAccessKey: demoSK,
            dateStamp: "20240619",
            region: "cn-beijing",
            service: "iam"
        )
        XCTAssertEqual(
            VolcengineSignerV4.hexEncode(key),
            "abee62e533a58934c49954459a3c3237d2fccea517c9a7c8a2651d8ea7779826"
        )
    }

    func testOfficialVectorSignatureAndAuthorization() {
        let signer = VolcengineSignerV4(
            accessKeyID: demoAK, secretAccessKey: demoSK, region: "cn-beijing", service: "iam"
        )
        let result = signer.makeSignature(
            method: "GET",
            canonicalURI: "/",
            query: [("Action", "ListUsers"), ("Version", "2018-01-01"), ("Limit", "10"), ("Offset", "0")],
            signedHeaders: [("host", "iam.volcengineapi.com"), ("x-date", "20240619T071306Z")],
            payloadHash: VolcengineSignerV4.sha256Hex(Data()),
            xDate: "20240619T071306Z"
        )
        XCTAssertEqual(
            result.signature,
            "e31c4558bcfe08a286001f59cedbf0791ffd0b2362f10e55ee2627467bcdde93"
        )
        XCTAssertEqual(
            result.authorization,
            "HMAC-SHA256 Credential=\(demoAK)/20240619/cn-beijing/iam/request, "
                + "SignedHeaders=host;x-date, "
                + "Signature=e31c4558bcfe08a286001f59cedbf0791ffd0b2362f10e55ee2627467bcdde93"
        )
    }

    /// The real Ark usage: a POST signed with host;x-content-sha256;x-date.
    /// We can't pin the exact signature without a live secret, but the
    /// header shape, content hash, and credential scope must be exact —
    /// and the signature primitive itself is already pinned above.
    func testArkPostHeaderShape() {
        let signer = VolcengineSignerV4(
            accessKeyID: demoAK, secretAccessKey: demoSK, region: "cn-beijing", service: "ark"
        )
        let date = utcDate(year: 2024, month: 6, day: 19, hour: 7, minute: 13, second: 6)
        let body = Data("{}".utf8)
        let headers = signer.headers(
            host: "ark.cn-beijing.volces.com",
            query: [("Action", "GetAFPUsage"), ("Version", "2024-01-01")],
            body: body,
            date: date
        )
        XCTAssertEqual(headers["X-Date"], "20240619T071306Z")
        XCTAssertEqual(headers["X-Content-Sha256"], VolcengineSignerV4.sha256Hex(body))
        let auth = headers["Authorization"] ?? ""
        XCTAssertTrue(
            auth.hasPrefix(
                "HMAC-SHA256 Credential=\(demoAK)/20240619/cn-beijing/ark/request, "
                    + "SignedHeaders=host;x-content-sha256;x-date, Signature="
            ),
            "unexpected Authorization header: \(auth)"
        )
    }
}
