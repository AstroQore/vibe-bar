import XCTest
@testable import VibeBarCore

final class EmailMaskerTests: XCTestCase {
    func testStandardGmailMasked() {
        XCTAssertEqual(EmailMasker.mask("abcdef@example.com"), "a••••@example.com")
    }

    func testSingleCharLocalPart() {
        XCTAssertEqual(EmailMasker.mask("a@x.io"), "a@x.io")
    }

    func testNilReturnsEmpty() {
        XCTAssertEqual(EmailMasker.mask(nil), "")
    }

    func testEmptyReturnsEmpty() {
        XCTAssertEqual(EmailMasker.mask(""), "")
    }

    func testWhitespaceTrimmed() {
        XCTAssertEqual(EmailMasker.mask("  abcdef@example.com  "), "a••••@example.com")
    }

    func testStringWithoutAtPreservesFirstChar() {
        let masked = EmailMasker.mask("plainusername")
        XCTAssertTrue(masked.hasPrefix("p"))
        XCTAssertEqual(masked.count, "plainusername".count)
    }

    func testTwoCharLocalPart() {
        // We always render at least 4 bullets (or local-1 if shorter), so 2-char local
        // becomes "a" + 4 bullets — that's intentional: hides original length.
        XCTAssertEqual(EmailMasker.mask("ab@example.com"), "a••••@example.com")
    }

    func testMaybeMaskRespectsShowFull() {
        XCTAssertEqual(EmailMasker.maybeMask("abcdef@example.com", showFull: true), "abcdef@example.com")
        XCTAssertEqual(EmailMasker.maybeMask("abcdef@example.com", showFull: false), "a••••@example.com")
    }
}
