import XCTest
@testable import VibeBarCore

/// Behavioural tests for the parts of `GeminiWebResponseParser` that
/// are decided independently of the spike outcome. The full per-shape
/// decoding lands once the `gemini.google.com/usage` spike (plan §9)
/// completes; until then we lock in the anti-hijacking prefix logic
/// and the explicit "not implemented yet" parse-failure contract.
final class GeminiWebResponseParserTests: XCTestCase {
    func testStripAntiHijackingPrefixRemovesProperPrefix() {
        let raw = Data(")]}'\n[{\"x\":1}]".utf8)
        let stripped = GeminiWebResponseParser.stripAntiHijackingPrefix(raw)
        XCTAssertEqual(String(data: stripped, encoding: .utf8), "[{\"x\":1}]")
    }

    func testStripAntiHijackingPrefixWithoutTrailingNewlineStillStripsPrefix() {
        let raw = Data(")]}'[1,2,3]".utf8)
        let stripped = GeminiWebResponseParser.stripAntiHijackingPrefix(raw)
        XCTAssertEqual(String(data: stripped, encoding: .utf8), "[1,2,3]")
    }

    func testStripAntiHijackingPrefixIsNoopWhenAbsent() {
        let raw = Data("{\"clean\":true}".utf8)
        let stripped = GeminiWebResponseParser.stripAntiHijackingPrefix(raw)
        XCTAssertEqual(String(data: stripped, encoding: .utf8), "{\"clean\":true}")
    }

    func testParseEmptyDataThrowsParseFailure() {
        XCTAssertThrowsError(try GeminiWebResponseParser.parse(data: Data())) { error in
            guard case QuotaError.parseFailure = error else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testParseUntilSpikeReturnsParseFailureWithSpikeHint() {
        // Until the spike completes the parser is intentionally a
        // parseFailure so the adapter falls through to the OAuth source
        // and the dedicated card surfaces the maintenance hint instead
        // of a misleading "everything is fine" panel.
        let payload = Data(")]}'\n{\"buckets\":[]}".utf8)
        XCTAssertThrowsError(try GeminiWebResponseParser.parse(data: payload)) { error in
            guard case QuotaError.parseFailure(let message) = error else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("spike"), "Message should reference the spike: \(message)")
        }
    }
}
