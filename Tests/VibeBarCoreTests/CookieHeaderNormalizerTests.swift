import XCTest
@testable import VibeBarCore

final class CookieHeaderNormalizerTests: XCTestCase {
    func testNormalizeBareHeader() {
        let raw = "  sessionKey=abc123; HERTZ-SESSION=def456 "
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize(raw),
            "sessionKey=abc123; HERTZ-SESSION=def456"
        )
    }

    func testNormalizeStripsCookiePrefix() {
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize("Cookie: sessionKey=abc"),
            "sessionKey=abc"
        )
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize("cookie: kimi-auth=xyz"),
            "kimi-auth=xyz"
        )
    }

    func testNormalizeStripsWrappingQuotes() {
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize("\"sessionKey=abc; foo=bar\""),
            "sessionKey=abc; foo=bar"
        )
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize("'sessionKey=abc'"),
            "sessionKey=abc"
        )
    }

    func testNormalizeExtractsFromCurlH() {
        let raw = #"curl -X POST -H 'Cookie: sessionKey=abc; foo=bar' https://example.com"#
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize(raw),
            "sessionKey=abc; foo=bar"
        )
    }

    func testNormalizeExtractsFromCurlBigB() {
        let raw = "curl --cookie 'kimi-auth=jwt-payload' https://kimi.com"
        XCTAssertEqual(
            CookieHeaderNormalizer.normalize(raw),
            "kimi-auth=jwt-payload"
        )
    }

    func testNormalizeReturnsNilForEmpty() {
        XCTAssertNil(CookieHeaderNormalizer.normalize(nil))
        XCTAssertNil(CookieHeaderNormalizer.normalize(""))
        XCTAssertNil(CookieHeaderNormalizer.normalize("   "))
    }

    func testPairsParsesNameValuePairs() {
        let pairs = CookieHeaderNormalizer.pairs(from: "a=1; b=two; c=hello world")
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[0].name, "a")
        XCTAssertEqual(pairs[0].value, "1")
        XCTAssertEqual(pairs[1].name, "b")
        XCTAssertEqual(pairs[1].value, "two")
        XCTAssertEqual(pairs[2].name, "c")
        XCTAssertEqual(pairs[2].value, "hello world")
    }

    func testPairsSkipsMalformedEntries() {
        let pairs = CookieHeaderNormalizer.pairs(from: "valid=yes; ; =no-name; bare; trailing=ok")
        let names = pairs.map(\.name)
        XCTAssertEqual(names, ["valid", "trailing"])
    }

    func testFilteredHeaderKeepsOnlyAllowedNames() {
        let raw = "sessionKey=abc; analytics=xyz; csrf=123; HERTZ-SESSION=def"
        let filtered = CookieHeaderNormalizer.filteredHeader(
            from: raw,
            allowedNames: ["sessionKey", "HERTZ-SESSION"]
        )
        XCTAssertNotNil(filtered)
        // Order isn't guaranteed by Set iteration, so check both elements present.
        XCTAssertTrue(filtered!.contains("sessionKey=abc"))
        XCTAssertTrue(filtered!.contains("HERTZ-SESSION=def"))
        XCTAssertFalse(filtered!.contains("analytics=xyz"))
        XCTAssertFalse(filtered!.contains("csrf=123"))
    }

    func testFilteredHeaderReturnsNilWhenNothingMatches() {
        let raw = "analytics=xyz; csrf=123"
        XCTAssertNil(CookieHeaderNormalizer.filteredHeader(
            from: raw,
            allowedNames: ["sessionKey"]
        ))
    }
}
