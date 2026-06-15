import XCTest
@testable import VibeBarCore

/// Exercises the pure response parser behind the AntiGravity cascade
/// usage RPC. The network call itself isn't unit-tested (it needs a live
/// language server), but the JSON → `Turn` mapping is, so the token math
/// and envelope tolerance stay locked in.
final class AntigravityCascadeUsageFetcherTests: XCTestCase {
    private func parse(_ json: String) -> [AntigravityCascadeUsageFetcher.Turn] {
        AntigravityCascadeUsageFetcher.parse(data: Data(json.utf8))
    }

    func testParsesGeneratorMetadataArray() throws {
        let json = """
        {"generatorMetadata":[
          {"chatModel":{"model":"gemini-3-pro",
            "usage":{"model":"gemini-3-pro","inputTokens":"1200","outputTokens":"500",
                     "thinkingOutputTokens":"100","responseOutputTokens":"400","responseId":"r1"},
            "chatStartMetadata":{"createdAt":"2026-06-11T13:53:00Z"}}}
        ]}
        """
        let turns = parse(json)
        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.input, 1200)
        // response (400) + thinking (100), both billed at the output rate.
        XCTAssertEqual(turn.output, 500)
        XCTAssertEqual(turn.model, "gemini-3-pro")
        XCTAssertEqual(turn.responseId, "r1")
        XCTAssertNotNil(turn.date)
    }

    func testFallsBackToOutputTokensWhenNoResponseSplit() {
        let json = """
        {"generatorMetadata":[
          {"chatModel":{"usage":{"model":"gemini-3-flash","inputTokens":"10","outputTokens":"42"}}}
        ]}
        """
        let turns = parse(json)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.input, 10)
        XCTAssertEqual(turns.first?.output, 42)
    }

    func testSkipsZeroTokenTurns() {
        let json = """
        {"generatorMetadata":[
          {"chatModel":{"usage":{"inputTokens":"0","outputTokens":"0"}}},
          {"chatModel":{"usage":{"inputTokens":"5","outputTokens":"0"}}}
        ]}
        """
        let turns = parse(json)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.input, 5)
    }

    func testDedupesByResponseId() {
        let json = """
        {"generatorMetadata":[
          {"chatModel":{"usage":{"inputTokens":"5","outputTokens":"1","responseId":"dup"}}},
          {"chatModel":{"usage":{"inputTokens":"7","outputTokens":"2","responseId":"dup"}}}
        ]}
        """
        let turns = parse(json)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.input, 5)
    }

    func testToleratesWrappedEnvelopeAndNumericTokens() {
        // A wrapper key around the array + numeric (non-string) token
        // values — both shapes the parser must absorb.
        let json = """
        {"response":{"trajectoryGeneratorMetadata":[
          {"chatModel":{"usage":{"model":"gemini-3-pro","inputTokens":3,"outputTokens":9}}}
        ]}}
        """
        let turns = parse(json)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.input, 3)
        XCTAssertEqual(turns.first?.output, 9)
    }

    func testReturnsEmptyForUnrelatedOrInvalidJSON() {
        XCTAssertTrue(parse("{}").isEmpty)
        XCTAssertTrue(parse(#"{"foo":42}"#).isEmpty)
        XCTAssertTrue(parse("not json at all").isEmpty)
    }
}
