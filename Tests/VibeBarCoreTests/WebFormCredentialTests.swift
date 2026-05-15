import XCTest
@testable import VibeBarCore

final class WebFormCredentialTests: XCTestCase {
    func testHostNormalizationStripsLeadingDot() {
        let credential = WebFormCredential(host: ".qq.com", username: "user", password: "pw")
        XCTAssertEqual(credential.host, "qq.com")
    }

    func testMatchesHostExactAndSuffix() {
        let credential = WebFormCredential(host: "qq.com", username: "u", password: "p")
        XCTAssertTrue(credential.matchesHost("qq.com"))
        XCTAssertTrue(credential.matchesHost("QQ.com"))
        XCTAssertTrue(credential.matchesHost("passport.qq.com"))
        XCTAssertFalse(credential.matchesHost("example.com"))
    }

    func testReverseSuffixAlsoMatches() {
        // Credential stored under the SSO subdomain; later page lives
        // on a sibling subdomain. Suffix match works in both directions
        // so the user can re-use credentials saved before.
        let credential = WebFormCredential(host: "passport.qq.com", username: "u", password: "p")
        XCTAssertTrue(credential.matchesHost("qq.com"))
    }

    func testIsUsableRejectsEmptyFields() {
        XCTAssertFalse(WebFormCredential(host: "", username: "u", password: "p").isUsable)
        XCTAssertFalse(WebFormCredential(host: "h", username: " ", password: "p").isUsable)
        XCTAssertFalse(WebFormCredential(host: "h", username: "u", password: "").isUsable)
        XCTAssertTrue(WebFormCredential(host: "h", username: "u", password: "p").isUsable)
    }

    func testJSONRoundTripPreservesFields() throws {
        let original = WebFormCredential(
            host: "passport.qq.com",
            username: "abc@example.com",
            password: "s3cret",
            savedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebFormCredential.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
