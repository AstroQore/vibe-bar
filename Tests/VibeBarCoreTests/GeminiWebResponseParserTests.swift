import XCTest
@testable import VibeBarCore

/// Behavioural tests for `GeminiWebResponseParser`. The 2026-05-23
/// reverse-engineering pass identified `jSf9Qc` as the live quota
/// rpcid on `gemini.google.com`. These tests pin the wire format
/// (chunked JSONP-prefixed envelope wrapping a doubly-encoded inner
/// JSON payload) against fixtures captured from a live PRO session
/// with the numbers scrubbed to synthetic values.
final class GeminiWebResponseParserTests: XCTestCase {
    // MARK: - stripAntiHijackingPrefix

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

    // MARK: - parse: error paths

    func testParseEmptyDataThrowsParseFailure() {
        XCTAssertThrowsError(try GeminiWebResponseParser.parse(data: Data())) { error in
            guard case QuotaError.parseFailure = error else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testParseMissingWrbFrEntryThrowsParseFailure() {
        let payload = Data(")]}'\n[{\"unrelated\":true}]".utf8)
        XCTAssertThrowsError(try GeminiWebResponseParser.parse(data: payload)) { error in
            guard case QuotaError.parseFailure(let message) = error else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("jSf9Qc"), "Message should reference the rpcid: \(message)")
        }
    }

    func testParseMalformedInnerJsonThrowsParseFailure() {
        // wrb.fr entry present, but the inner JSON string is not an array.
        let payload = Data(#")]}'\n[["wrb.fr","jSf9Qc","not-json",null,null,null,"generic"]]"#.utf8)
        XCTAssertThrowsError(try GeminiWebResponseParser.parse(data: payload)) { error in
            guard case QuotaError.parseFailure = error else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    func testParseEmptyBucketsArrayThrowsParseFailure() {
        let inner = #"[2,[],false]"#
        let payload = Self.wireFormat(inner: inner)
        XCTAssertThrowsError(try GeminiWebResponseParser.parse(data: payload)) { error in
            guard case QuotaError.parseFailure = error else {
                XCTFail("Expected parseFailure, got \(error)")
                return
            }
        }
    }

    // MARK: - parse: happy path

    func testParseTwoBucketsEmitsCurrentAndWeeklyInOrder() throws {
        // Synthetic numbers based on a live PRO response. Two buckets:
        // - type=1 (Current/daily): 100 remaining, 25% used,
        //   resets at the reference reset timestamp.
        // - type=2 (Weekly):       4500 remaining, 10% used,
        //   resets 4 days later (epoch +345600 s).
        let inner =
            "[2,[" +
            "[100,0.25,1,[[1779469511,884512000]]]," +
            "[4500,0.1,2,[[1779815111,884621000]]]" +
            "],false]"
        let payload = Self.wireFormat(inner: inner)
        let snapshot = try GeminiWebResponseParser.parse(data: payload, email: "demo@example.com")

        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.email, "demo@example.com")
        XCTAssertEqual(snapshot.buckets.count, 2)

        let current = try XCTUnwrap(snapshot.buckets.first(where: { $0.id == GeminiWebResponseParser.currentUsageBucketId }))
        XCTAssertEqual(current.title, "5 Hours")
        XCTAssertEqual(current.shortLabel, "5 Hours")
        XCTAssertEqual(current.usedPercent, 25.0, accuracy: 0.0001)
        XCTAssertEqual(current.resetAt?.timeIntervalSince1970 ?? 0, 1779469511.884512, accuracy: 0.001)
        // Fixed window lengths let `UsagePace` render reserve/deficit
        // captions for Gemini like it does for Codex/Claude.
        XCTAssertEqual(current.rawWindowSeconds, 18_000)

        let weekly = try XCTUnwrap(snapshot.buckets.first(where: { $0.id == GeminiWebResponseParser.weeklyUsageBucketId }))
        XCTAssertEqual(weekly.title, "Weekly")
        XCTAssertEqual(weekly.shortLabel, "Weekly")
        XCTAssertEqual(weekly.usedPercent, 10.0, accuracy: 0.0001)
        XCTAssertEqual(weekly.resetAt?.timeIntervalSince1970 ?? 0, 1779815111.884621, accuracy: 0.001)
        XCTAssertEqual(weekly.rawWindowSeconds, 604_800)
    }

    func testParseTolerantOfBucketOrderingInResponse() throws {
        // Same buckets but listed weekly-then-current. The parser must
        // canonicalize them because Gemini quota cards render this array
        // directly and otherwise flip after refreshes.
        let inner =
            "[2,[" +
            "[4500,0.1,2,[[1779815111,884621000]]]," +
            "[100,0.25,1,[[1779469511,884512000]]]" +
            "],false]"
        let snapshot = try GeminiWebResponseParser.parse(data: Self.wireFormat(inner: inner))
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.map(\.id), [
            GeminiWebResponseParser.currentUsageBucketId,
            GeminiWebResponseParser.weeklyUsageBucketId
        ])
    }

    func testCurrentUltraPayloadMapsTierSixAndDropsInternalSentinel() throws {
        let inner =
            "[6,[" +
            "[9999,0,4,null,null,[[[2,0]],4]]," +
            "[238022,0.01611225,2,[[1784689500,0]]]," +
            "[8187,0.32,1,[[1784557500,0]]]" +
            "],false]"
        let snapshot = try GeminiWebResponseParser.parse(data: Self.wireFormat(inner: inner))
        XCTAssertEqual(snapshot.planName, "Ultra")
        XCTAssertEqual(snapshot.buckets.map(\.id).sorted(), ["five_hour", "weekly"])
    }

    func testParseClampsUsedPercentToZeroToHundred() throws {
        // Bogus fractions outside 0..1 should clamp to 0..100.
        let inner =
            "[2,[" +
            "[0,-0.5,1,[[1779469511,884512000]]]," +
            "[0,1.5,2,[[1779815111,884621000]]]" +
            "],false]"
        let snapshot = try GeminiWebResponseParser.parse(data: Self.wireFormat(inner: inner))
        let current = try XCTUnwrap(snapshot.buckets.first(where: { $0.id == GeminiWebResponseParser.currentUsageBucketId }))
        XCTAssertEqual(current.usedPercent, 0)
        let weekly = try XCTUnwrap(snapshot.buckets.first(where: { $0.id == GeminiWebResponseParser.weeklyUsageBucketId }))
        XCTAssertEqual(weekly.usedPercent, 100)
    }

    func testParseUnknownBucketTypeFallsBackToBucketN() throws {
        // Hypothetical future bucket type that Google adds before Vibe
        // Bar maps it. Parser keeps the bucket but tags it generically.
        let inner = "[2,[[1,0.05,7,[[1779469511,884512000]]]],false]"
        let snapshot = try GeminiWebResponseParser.parse(data: Self.wireFormat(inner: inner))
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(snapshot.buckets[0].id, "gemini.bucket7")
        XCTAssertEqual(snapshot.buckets[0].title, "Bucket 7")
        XCTAssertEqual(snapshot.buckets[0].shortLabel, "B7")
    }

    func testParseIgnoresMalformedBucketEntriesShorterThanFourFields() throws {
        let inner =
            "[2,[" +
            "[100,0.25]," +                                           // too short, dropped
            "[100,0.25,1,[[1779469511,884512000]]]" +
            "],false]"
        let snapshot = try GeminiWebResponseParser.parse(data: Self.wireFormat(inner: inner))
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(snapshot.buckets[0].id, GeminiWebResponseParser.currentUsageBucketId)
    }

    // MARK: - planLabel

    func testPlanLabelMapping() {
        XCTAssertEqual(GeminiWebResponseParser.planLabel(forTierId: 1), "Free")
        XCTAssertEqual(GeminiWebResponseParser.planLabel(forTierId: 2), "Pro")
        XCTAssertEqual(GeminiWebResponseParser.planLabel(forTierId: 3), "Ultra")
        XCTAssertNil(GeminiWebResponseParser.planLabel(forTierId: 0))
        XCTAssertNil(GeminiWebResponseParser.planLabel(forTierId: 99))
    }

    func testParsePlanTierAppearsOnSnapshot() throws {
        let inner = "[3,[[1,0,1,[[1779469511,884512000]]]],false]"
        let snapshot = try GeminiWebResponseParser.parse(data: Self.wireFormat(inner: inner))
        XCTAssertEqual(snapshot.planName, "Ultra")
    }

    // MARK: - Helpers

    /// Build the exact JSONP-prefixed chunked wire format Google ships:
    /// `)]}'\n\n<len>\n<wrb.fr entry>\n<tail-len>\n<tail-entry>\n`.
    /// The inner is JSON-encoded once (string-escaped) inside the
    /// outer JSON array.
    private static func wireFormat(inner: String) -> Data {
        let escapedInner = inner
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let wrbEntry = #"[["wrb.fr","jSf9Qc","\#(escapedInner)",null,null,null,"generic"],["di",100],["af.httprm",100,"0",0]]"#
        let tail = #"[["e",4,null,null,0]]"#
        let wrbBytes = wrbEntry.utf8.count
        let tailBytes = tail.utf8.count
        let body = ")]}\'\n\n\(wrbBytes)\n\(wrbEntry)\n\(tailBytes)\n\(tail)\n"
        return Data(body.utf8)
    }
}
