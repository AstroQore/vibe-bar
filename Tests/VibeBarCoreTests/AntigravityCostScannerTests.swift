import XCTest
import SQLite3
@testable import VibeBarCore

/// AntiGravity IDE sessions ship as one SQLite database per
/// conversation under `~/.gemini/antigravity/conversations/<UUID>.db`.
/// The `gen_metadata.data` BLOB is a protobuf message whose schema
/// was reverse-engineered with `protoc --decode_raw`; this suite
/// exercises both the raw decoder (`AntigravitySessionReader`) and
/// the end-to-end scanner against synthetic databases.
final class AntigravityCostScannerTests: XCTestCase {
    // MARK: - Protobuf encoder helpers (test-only, mirrors xAI / Google wire format)

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        while v > 0x7F {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v & 0x7F))
        return bytes
    }

    private func encodeTag(field: UInt64, wire: UInt64) -> [UInt8] {
        encodeVarint((field << 3) | wire)
    }

    private func encodeVarintField(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        encodeTag(field: field, wire: 0) + encodeVarint(value)
    }

    private func encodeLengthDelimited(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] {
        encodeTag(field: field, wire: 2) + encodeVarint(UInt64(payload.count)) + payload
    }

    private func encodeString(_ field: UInt64, _ value: String) -> [UInt8] {
        encodeLengthDelimited(field, [UInt8](value.utf8))
    }

    /// Build a `gen_metadata.data` blob matching AntiGravity's schema:
    ///   `1` (outer message)
    ///     `4` (usage): per-turn token counts
    ///     `9` (system): wall-clock timestamp under `4`
    private func encodeTurnBlob(
        seconds: UInt64,
        nanos: UInt64 = 0,
        systemPrompt: UInt64 = 1132,
        input: UInt64,
        output: UInt64,
        cumulativeCache: UInt64,
        thoughts: UInt64 = 0,
        tool: UInt64 = 0,
        requestId: String = "test-request"
    ) -> Data {
        var usage: [UInt8] = []
        usage += encodeVarintField(1, systemPrompt)
        usage += encodeVarintField(2, input)
        usage += encodeVarintField(3, output)
        if cumulativeCache > 0 { usage += encodeVarintField(5, cumulativeCache) }
        usage += encodeVarintField(6, 24)
        if thoughts > 0 { usage += encodeVarintField(9, thoughts) }
        if tool > 0 { usage += encodeVarintField(10, tool) }
        usage += encodeString(11, requestId)

        let timeBlock = encodeVarintField(1, seconds) + encodeVarintField(2, nanos)
        let systemBlock = encodeLengthDelimited(4, timeBlock)

        let outer = encodeLengthDelimited(4, usage) + encodeLengthDelimited(9, systemBlock)
        let blob = encodeLengthDelimited(1, outer)
        return Data(blob)
    }

    // MARK: - SQLite synthesis

    private struct TurnSpec {
        let idx: Int
        let blob: Data
    }

    /// Create a minimal AntiGravity-shaped database with just the
    /// columns the scanner reads.
    private func writeAntigravityDB(at url: URL, turns: [TurnSpec]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(db) }
        let create = "CREATE TABLE gen_metadata(idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0)"
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)

        for spec in turns {
            var statement: OpaquePointer?
            let insert = "INSERT INTO gen_metadata(idx, data, size) VALUES (?, ?, ?)"
            XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_int(statement, 1, Int32(spec.idx))
            spec.blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(statement, 2,
                                  raw.baseAddress, Int32(spec.blob.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_int64(statement, 3, sqlite3_int64(spec.blob.count))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarAntigravityScannerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Decoder unit tests

    func testDecoderExtractsAllFields() throws {
        let blob = encodeTurnBlob(
            seconds: 1_779_434_426,
            nanos: 571_722_000,
            systemPrompt: 1132,
            input: 2056,
            output: 245,
            cumulativeCache: 16_284,
            thoughts: 158,
            tool: 87,
            requestId: "req-001"
        )
        let turn = try XCTUnwrap(AntigravitySessionReader.decodeTurn(blob: blob))
        XCTAssertEqual(turn.inputTokens, 2056)
        XCTAssertEqual(turn.outputTokens, 245)
        XCTAssertEqual(turn.cumulativeCacheReadTokens, 16_284)
        XCTAssertEqual(turn.thoughtsTokens, 158)
        XCTAssertEqual(turn.toolTokens, 87)
        XCTAssertEqual(turn.requestId, "req-001")
        XCTAssertEqual(turn.date.timeIntervalSince1970,
                       1_779_434_426 + 571_722_000.0 / 1_000_000_000,
                       accuracy: 1e-6)
    }

    func testDecoderHandlesMissingOptionalFields() throws {
        // First-turn blobs typically omit the cumulative cache field
        // and the optional thoughts / tool fields.
        let blob = encodeTurnBlob(
            seconds: 1_779_434_426,
            input: 16_738,
            output: 780,
            cumulativeCache: 0,
            requestId: "req-first"
        )
        let turn = try XCTUnwrap(AntigravitySessionReader.decodeTurn(blob: blob))
        XCTAssertEqual(turn.inputTokens, 16_738)
        XCTAssertEqual(turn.outputTokens, 780)
        XCTAssertEqual(turn.cumulativeCacheReadTokens, 0)
        XCTAssertEqual(turn.thoughtsTokens, 0)
        XCTAssertEqual(turn.toolTokens, 0)
    }

    func testDecoderRejectsTruncatedBlobs() {
        let truncated = Data([0x0A]) // tag with no length
        XCTAssertNil(AntigravitySessionReader.decodeTurn(blob: truncated))
    }

    // MARK: - End-to-end scanner tests

    func testSingleConversationFlowsThroughScanner() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let convDir = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_779_434_500)
        let dbURL = convDir.appendingPathComponent("synthetic-trajectory.db")
        let base = UInt64(now.addingTimeInterval(-600).timeIntervalSince1970)

        try writeAntigravityDB(at: dbURL, turns: [
            TurnSpec(idx: 0, blob: encodeTurnBlob(
                seconds: base + 0,
                input: 16_738, output: 780,
                cumulativeCache: 0, thoughts: 705, tool: 75
            )),
            TurnSpec(idx: 1, blob: encodeTurnBlob(
                seconds: base + 5,
                input: 2056, output: 245,
                cumulativeCache: 16_284, thoughts: 158, tool: 87
            )),
            TurnSpec(idx: 2, blob: encodeTurnBlob(
                seconds: base + 10,
                input: 9_203, output: 250,
                cumulativeCache: 16_306, thoughts: 175, tool: 75
            ))
        ])

        let snapshot = await CostUsageScanner.scan(
            tool: .antigravity,
            homeDirectory: home.path,
            now: now
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 1)
        // Per-turn token totals fed to aggregator:
        //   idx 0: input 16738, output 780+705+75 = 1560, cache 0
        //   idx 1: input  2056, output 245+158+87 =  490, cache 16284 (15284 creation + 0 read)
        //   idx 2: input  9203, output 250+175+75 =  500, cache 16306 (   22 creation + 16284 read)
        // Total tokens (input+output+cache): 16738+1560 + 2056+490+16284 + 9203+500+16306 = 63137
        XCTAssertEqual(snap.allTimeTokens, 63_137)
        // All turns are within the last 7 days from `now`.
        XCTAssertEqual(snap.last7DaysTokens, 63_137)
        XCTAssertEqual(snap.modelBreakdowns.map(\.modelName), ["antigravity-default"])
        XCTAssertGreaterThan(snap.allTimeCostUSD, 0)
    }

    func testScannerSkipsNonDatabaseFiles() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }
        let convDir = home
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        try Data([0x00, 0x01, 0x02]).write(to: convDir.appendingPathComponent("foo.pb"))
        try Data().write(to: convDir.appendingPathComponent("bar.txt"))

        let snapshot = await CostUsageScanner.scan(
            tool: .antigravity,
            homeDirectory: home.path,
            now: Date()
        )
        let snap = try XCTUnwrap(snapshot)
        XCTAssertEqual(snap.jsonlFilesFound, 0)
        XCTAssertEqual(snap.allTimeTokens, 0)
    }

    func testAntigravityCostUsesSonnetRatesForDefault() throws {
        // `antigravity-default` shadows Claude Sonnet 4.6:
        //   $3 / Mtok input, $0.30 / Mtok cache read, $3.75 / Mtok cache creation, $15 / Mtok output.
        let cost = try XCTUnwrap(CostUsagePricing.antigravityCostUSD(
            model: "antigravity-default",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0
        ))
        XCTAssertEqual(cost, 3.0, accuracy: 1e-9)
    }
}
