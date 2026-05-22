import Foundation
import SQLite3

/// Reads token-usage records out of an AntiGravity IDE conversation
/// database. Each `.db` file under `~/.gemini/antigravity/conversations/`
/// is a tiny SQLite store with one row per model turn in
/// `gen_metadata.data` — a protobuf blob.
///
/// The blob's shape was reverse-engineered against AntiGravity 2025
/// builds with `protoc --decode_raw`; the fields we read live at:
///
///   - `1.4.1` — constant system-prompt token count (1132 today),
///     cached after the first turn
///   - `1.4.2` — non-cached input tokens for this turn
///   - `1.4.3` — output tokens for this turn
///   - `1.4.5` — cumulative cache-read pool size (monotonically
///     non-decreasing within a trajectory)
///   - `1.4.9` — reasoning / "thinking" tokens — billed at output
///     rate by Claude / Gemini, so callers fold into output
///   - `1.4.10` — tool tokens — same as above
///   - `1.4.11` — the upstream request id (string), useful as a
///     dedupe key in the scan cache
///   - `1.9.4.1` / `1.9.4.2` — seconds + nanoseconds of the wall
///     clock when the turn started
///
/// Unknown fields are ignored. Missing fields default to 0 / nil so
/// callers never have to special-case a turn whose blob is short on
/// detail.
public enum AntigravitySessionReader {
    public struct Turn: Sendable, Equatable {
        public let date: Date
        public let inputTokens: Int
        public let outputTokens: Int
        public let cumulativeCacheReadTokens: Int
        public let thoughtsTokens: Int
        public let toolTokens: Int
        public let requestId: String?

        public init(
            date: Date,
            inputTokens: Int,
            outputTokens: Int,
            cumulativeCacheReadTokens: Int,
            thoughtsTokens: Int,
            toolTokens: Int,
            requestId: String?
        ) {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cumulativeCacheReadTokens = cumulativeCacheReadTokens
            self.thoughtsTokens = thoughtsTokens
            self.toolTokens = toolTokens
            self.requestId = requestId
        }
    }

    /// Open the SQLite database in read-only mode, walk the
    /// `gen_metadata` table in row-order, and decode each blob's
    /// turn-usage fields. Errors at any step return an empty array
    /// rather than throwing — a malformed database shouldn't sink
    /// the rest of the scan.
    public static func readGenMetadata(at file: URL) -> [Turn] {
        let path = file.path
        var db: OpaquePointer? = nil
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let uri = "file:\(path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, openFlags, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close_v2(db) }
            return []
        }
        defer { sqlite3_close_v2(db) }

        var statement: OpaquePointer? = nil
        let sql = "SELECT idx, data FROM gen_metadata ORDER BY idx"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if statement != nil { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(statement) }

        var turns: [Turn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0 else { continue }
            let blob = Data(bytes: raw, count: length)
            if let turn = decodeTurn(blob: blob) {
                turns.append(turn)
            }
        }
        return turns
    }

    // MARK: - Blob decoding

    static func decodeTurn(blob: Data) -> Turn? {
        let bytes = [UInt8](blob)
        guard let outer = extractLengthDelimited(bytes: bytes, fieldNumber: 1) else { return nil }

        let usage = extractLengthDelimited(bytes: outer, fieldNumber: 4) ?? []
        let system = extractLengthDelimited(bytes: outer, fieldNumber: 9) ?? []
        let timeBlock = extractLengthDelimited(bytes: system, fieldNumber: 4) ?? []

        let input = Int(extractVarint(bytes: usage, fieldNumber: 2) ?? 0)
        let output = Int(extractVarint(bytes: usage, fieldNumber: 3) ?? 0)
        let cache = Int(extractVarint(bytes: usage, fieldNumber: 5) ?? 0)
        let thoughts = Int(extractVarint(bytes: usage, fieldNumber: 9) ?? 0)
        let tool = Int(extractVarint(bytes: usage, fieldNumber: 10) ?? 0)
        let requestId = extractString(bytes: usage, fieldNumber: 11)

        let date: Date
        if let seconds = extractVarint(bytes: timeBlock, fieldNumber: 1) {
            let nanos = extractVarint(bytes: timeBlock, fieldNumber: 2) ?? 0
            date = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
        } else {
            return nil
        }

        return Turn(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cumulativeCacheReadTokens: cache,
            thoughtsTokens: thoughts,
            toolTokens: tool,
            requestId: requestId
        )
    }

    // MARK: - Protobuf raw scanner
    //
    // Path-based readers. Each `extract…` walks the byte stream
    // looking for the requested field number and returns the
    // *first* value of the matching wire type. AntiGravity's
    // schema doesn't repeat the fields we care about, so first-match
    // is the right semantics.

    static func extractLengthDelimited(bytes: [UInt8], fieldNumber: UInt64) -> [UInt8]? {
        var index = 0
        while let (number, wireType) = readTag(bytes: bytes, index: &index) {
            switch wireType {
            case 0:
                _ = readVarint(bytes: bytes, index: &index)
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
            case 2:
                guard let length = readVarint(bytes: bytes, index: &index) else { return nil }
                let end = index + Int(length)
                guard end <= bytes.count else { return nil }
                if number == fieldNumber {
                    return Array(bytes[index..<end])
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    static func extractVarint(bytes: [UInt8], fieldNumber: UInt64) -> UInt64? {
        var index = 0
        while let (number, wireType) = readTag(bytes: bytes, index: &index) {
            switch wireType {
            case 0:
                let value = readVarint(bytes: bytes, index: &index)
                if number == fieldNumber { return value }
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
            case 2:
                guard let length = readVarint(bytes: bytes, index: &index) else { return nil }
                let end = index + Int(length)
                guard end <= bytes.count else { return nil }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    static func extractString(bytes: [UInt8], fieldNumber: UInt64) -> String? {
        guard let payload = extractLengthDelimited(bytes: bytes, fieldNumber: fieldNumber) else {
            return nil
        }
        return String(bytes: payload, encoding: .utf8)
    }

    private static func readTag(bytes: [UInt8], index: inout Int) -> (UInt64, UInt64)? {
        guard let key = readVarint(bytes: bytes, index: &index), key != 0 else { return nil }
        return (key >> 3, key & 0x07)
    }

    private static func readVarint(bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
