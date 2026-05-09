import XCTest
@testable import VibeBarCore

final class VolcengineAuthSignTests: XCTestCase {
    /// Replays a captured live request: salt and timestamp pinned, the
    /// header value re-derived. The captured `=…mc` shape (the `=`
    /// comes first because base64 padding is reversed to the front,
    /// `mc` is the last two chars of the URL-encoded sign) is the most
    /// reliable invariant we have for the sign algorithm.
    func testHeaderShapeWithFixedSaltAndTimestamp() {
        let salt = "FKWR81jZ7q6mXv8p"
        let now = Date(timeIntervalSince1970: 1_778_271_028.468)
        let header = VolcengineAuthSign.headerValue(now: now, salt: salt)
        // Format: content=<urlencoded>&sign=<urlencoded>
        XCTAssertTrue(header.hasPrefix("content="), "header missing content prefix")
        XCTAssertTrue(header.contains("&sign="), "header missing sign separator")

        // Decode and confirm the content payload echoes the salt + ms.
        let parts = header.components(separatedBy: "&")
        XCTAssertEqual(parts.count, 2)
        let contentPart = parts[0].dropFirst("content=".count)
        let signPart = parts[1].dropFirst("sign=".count)
        let contentDecoded = String(contentPart).removingPercentEncoding!
        XCTAssertTrue(contentDecoded.contains(salt), "content should echo radomSalt")
        XCTAssertTrue(contentDecoded.contains("\"timeStamp\":1778271028468"))

        // sign decodes to (reversed standard base64 of) the signing form.
        let signDecoded = String(signPart).removingPercentEncoding!
        let recovered = String(signDecoded.reversed())
        let formData = Data(base64Encoded: recovered)
        XCTAssertNotNil(formData, "sign should be reverse-base64 of the signing form")
        let form = String(data: formData!, encoding: .utf8) ?? ""
        // The signing form has the timestamp string reversed
        // ("1778271028468" → "8648201728771").
        XCTAssertEqual(form, "radomSalt=\(salt)&timeStamp=8648201728771")
    }

    func testSaltGeneratorProducesRequestedLengthAlphanumeric() {
        for _ in 0..<10 {
            let salt = VolcengineAuthSign.randomSalt(length: 16)
            XCTAssertEqual(salt.count, 16)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            XCTAssertTrue(salt.unicodeScalars.allSatisfy { allowed.contains($0) })
        }
    }

    func testHeaderIsDeterministicForSameInputs() {
        let salt = "AAAAAAAAAAAAAAAA"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VolcengineAuthSign.headerValue(now: now, salt: salt)
        let b = VolcengineAuthSign.headerValue(now: now, salt: salt)
        XCTAssertEqual(a, b)
    }

    func testPercentEncodingExcludesEqualsAndAmpersand() {
        // Critical: the JS `encodeURIComponent` allowed set must not
        // include `=` or `&`, otherwise the `content=...&sign=...`
        // structure would be ambiguous.
        XCTAssertFalse(VolcengineAuthSign.percentEncodingAllowed.contains(Unicode.Scalar("=")))
        XCTAssertFalse(VolcengineAuthSign.percentEncodingAllowed.contains(Unicode.Scalar("&")))
        XCTAssertTrue(VolcengineAuthSign.percentEncodingAllowed.contains(Unicode.Scalar("A")))
        XCTAssertTrue(VolcengineAuthSign.percentEncodingAllowed.contains(Unicode.Scalar("z")))
        XCTAssertTrue(VolcengineAuthSign.percentEncodingAllowed.contains(Unicode.Scalar("9")))
    }
}
