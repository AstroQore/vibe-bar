import Foundation

/// Request timing read from the timestamps a session log already carries.
///
/// A proxy can time a request on the wire; Vibe Bar only has the CLI's own
/// log, which stamps every line when it is written. Three instants come out
/// of it for one model request:
///
/// - **started** — the last transcript line written before the response's
///   first line: the user prompt, a tool result, or the previous response.
///   The request goes out right after it, so this is a slightly early start.
/// - **first block** — the response's first content block (thinking, text,
///   a tool call). Logs write a block when it is *complete*, so the gap from
///   the start is an upper bound on the true time to first token.
/// - **completed** — the response's last block (Claude Code), or its last
///   model item or usage record (Codex; see `CodexRequestTimingTracker` for
///   why not the `token_count`).
///
/// The scanner records the instants on `CostUsageScanCache.ParsedEvent`, the
/// ledger stores the two durations derived here, and every surface that
/// shows a speed computes it with `outputTokensPerSecond` so the request log,
/// the speed card and the MCP DTO cannot disagree.
public enum UsageRequestTiming {
    /// A request whose start lies further back than this is not one request
    /// measured — it is a log that went quiet (a laptop asleep, a prompt left
    /// unanswered) — so the start is dropped rather than averaged in.
    public static let maximumDuration: TimeInterval = 3_600
    /// Below this a tokens-per-second figure is dominated by timestamp
    /// granularity (a one-block reply written 40 ms after its prompt would
    /// read as thousands of tokens a second), so none is reported.
    public static let minimumSpeedDurationMs: Int64 = 500

    /// The three instants after the plausibility gate. `completed` anchors
    /// everything: without it there is nothing to measure. A start that is
    /// not strictly before `completed`, or more than `maximumDuration`
    /// before it, is dropped; a first block outside `start…completed` is
    /// dropped. Each field fails on its own, so a bad first block keeps the
    /// duration and a missing start keeps the observed blocks.
    public static func sanitized(
        start: Date?,
        firstBlock: Date?,
        completed: Date?
    ) -> (start: Date?, firstBlock: Date?, completed: Date?) {
        guard let completed else { return (nil, nil, nil) }
        var start = start
        if let value = start {
            let duration = completed.timeIntervalSince(value)
            if !(duration > 0 && duration <= maximumDuration) { start = nil }
        }
        var firstBlock = firstBlock
        if let value = firstBlock {
            if value > completed || (start.map { value < $0 } ?? false) { firstBlock = nil }
        }
        return (start, firstBlock, completed)
    }

    /// Whole milliseconds from `start` to `end`, rounded.
    public static func milliseconds(from start: Date, to end: Date) -> Int64? {
        let value = (end.timeIntervalSince(start) * 1_000).rounded()
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else { return nil }
        return Int64(value)
    }

    /// Output tokens per second of wall-clock request time, or `nil` when
    /// there is no duration, the duration is under `minimumSpeedDurationMs`,
    /// or the request produced no output to measure.
    public static func outputTokensPerSecond(output: Int64, durationMs: Int64?) -> Double? {
        guard let durationMs, durationMs >= minimumSpeedDurationMs, output > 0 else { return nil }
        return Double(output) / (Double(durationMs) / 1_000)
    }
}

// MARK: - Compact storage

/// The three instants as millisecond offsets from the event's own `date`.
///
/// The scan cache holds hundreds of thousands of events; three full `Date`
/// keys would add ~100 bytes of JSON to each, a 60 % growth for a Codex
/// event. Offsets from a date the event already stores cost ~20 bytes and
/// encode as one small array (`"rt":[-13013,-3259,0]`). `Int32.min` marks a
/// missing instant in memory; the wire form writes `null`.
struct UsageRequestTimingOffsets: Codable, Sendable, Equatable {
    static let missing = Int32.min

    let start: Int32
    let firstBlock: Int32
    let completed: Int32

    init?(start: Date?, firstBlock: Date?, completed: Date?, relativeTo anchor: Date) {
        func offset(_ date: Date?) -> Int32 {
            guard let date,
                  let ms = UsageRequestTiming.milliseconds(from: anchor, to: date),
                  ms > Int64(Int32.min), ms <= Int64(Int32.max)
            else { return Self.missing }
            return Int32(ms)
        }
        self.start = offset(start)
        self.firstBlock = offset(firstBlock)
        self.completed = offset(completed)
        if self.start == Self.missing, self.firstBlock == Self.missing, self.completed == Self.missing {
            return nil
        }
    }

    func date(_ offset: Int32, relativeTo anchor: Date) -> Date? {
        offset == Self.missing ? nil : anchor.addingTimeInterval(Double(offset) / 1_000)
    }

    /// Whole milliseconds between two stored instants, exact: both are
    /// already whole milliseconds from the same anchor.
    func span(from: Int32, to: Int32) -> Int64? {
        guard from != Self.missing, to != Self.missing else { return nil }
        return Int64(to) - Int64(from)
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        func next() throws -> Int32 {
            try container.decodeNil() ? Self.missing : try container.decode(Int32.self)
        }
        start = try next()
        firstBlock = try next()
        completed = try next()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [start, firstBlock, completed] {
            if value == Self.missing { try container.encodeNil() } else { try container.encode(value) }
        }
    }
}

// MARK: - Byte-level line probes

/// Cheap reads of a JSONL line's raw bytes, for the lines the scanners do
/// not otherwise parse. A full `JSONSerialization` pass over every user
/// prompt and tool result only to learn when it was written would multiply
/// the scan's cost; these look at bytes and allocate nothing.
enum JSONLLineProbe {
    static let timestampKey = Array(#""timestamp":""#.utf8)
    static let parentUUIDKey = Array(#""parentUuid":"#.utf8)

    /// Offset of `needle` in `bytes`, searching at most the first `limit`
    /// bytes when given.
    static func firstIndex(of needle: [UInt8], in bytes: UnsafeRawBufferPointer, limit: Int? = nil) -> Int? {
        guard let base = bytes.baseAddress, !needle.isEmpty else { return nil }
        let length = min(bytes.count, limit ?? bytes.count)
        guard length >= needle.count else { return nil }
        return needle.withUnsafeBytes { needleBytes -> Int? in
            guard let found = memmem(base, length, needleBytes.baseAddress, needle.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }

    /// The value of the first `"timestamp":"…"` in the line, parsed. The
    /// first occurrence is the top-level one in both log formats this reads:
    /// Codex writes it as the first key, and in a Claude Code transcript line
    /// only the nested objects *after* it (`toolUseResult`) carry arbitrary
    /// JSON — the message text before it is a string, whose quotes are
    /// escaped and cannot match.
    static func firstTimestamp(in bytes: UnsafeRawBufferPointer, limit: Int? = nil) -> Date? {
        guard let keyAt = firstIndex(of: timestampKey, in: bytes, limit: limit) else { return nil }
        let start = keyAt + timestampKey.count
        var end = start
        // An ISO-8601 instant is at most ~35 bytes; stop looking well past it.
        let ceiling = min(bytes.count, start + 64)
        while end < ceiling, bytes[end] != UInt8(ascii: "\"") { end += 1 }
        guard end < ceiling else { return nil }
        return ISO8601Bytes.parse(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
    }

    /// The string value that directly follows `key` (a pattern ending in
    /// `"`) within the first `limit` bytes, compared without allocating.
    static func value(after key: [UInt8], in bytes: UnsafeRawBufferPointer, from offset: Int = 0, limit: Int) -> UnsafeRawBufferPointer? {
        let window = min(bytes.count, limit)
        guard offset < window else { return nil }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<window])
        guard let found = firstIndex(of: key, in: slice) else { return nil }
        let start = offset + found + key.count
        var end = start
        while end < window, bytes[end] != UInt8(ascii: "\"") { end += 1 }
        guard end < window else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[start..<end])
    }

    static func equals(_ bytes: UnsafeRawBufferPointer, _ literal: [UInt8]) -> Bool {
        guard bytes.count == literal.count else { return false }
        for index in 0..<literal.count where bytes[index] != literal[index] { return false }
        return true
    }

    static func hasSuffix(_ bytes: UnsafeRawBufferPointer, _ literal: [UInt8]) -> Bool {
        guard bytes.count >= literal.count else { return false }
        let offset = bytes.count - literal.count
        for index in 0..<literal.count where bytes[offset + index] != literal[index] { return false }
        return true
    }
}

/// A fast ISO-8601 parser for the instants session logs write:
/// `YYYY-MM-DDTHH:MM:SS`, an optional fraction of any length, then `Z` or a
/// `±HH:MM` / `±HHMM` offset. Anything else falls back to
/// `ISO8601DateFormatter`, so an unusual stamp costs time, never a value.
enum ISO8601Bytes {
    static func parse(_ bytes: UnsafeRawBufferPointer) -> Date? {
        if let value = parseFast(bytes) { return value }
        let text = String(decoding: bytes, as: UTF8.self)
        return fallbackWithFraction.date(from: text) ?? fallbackPlain.date(from: text)
    }

    private static let fallbackWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fallbackPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseFast(_ bytes: UnsafeRawBufferPointer) -> Date? {
        let count = bytes.count
        guard count >= 20 else { return nil }
        func digits(_ at: Int, _ length: Int) -> Int? {
            var value = 0
            for index in at..<(at + length) {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: "t") || bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }
        var index = 19
        var fraction = 0.0
        if index < count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            let fractionStart = index
            while index < count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                fraction += Double(bytes[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
            guard index > fractionStart else { return nil }
        }
        guard index < count else { return nil }
        var offsetSeconds = 0
        switch bytes[index] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            index += 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign = bytes[index] == UInt8(ascii: "-") ? -1 : 1
            index += 1
            guard index + 2 <= count, let hours = digits(index, 2) else { return nil }
            index += 2
            if index < count, bytes[index] == UInt8(ascii: ":") { index += 1 }
            guard index + 2 <= count, let minutes = digits(index, 2) else { return nil }
            index += 2
            offsetSeconds = sign * (hours * 3_600 + minutes * 60)
        default:
            return nil
        }
        guard index == count else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard
    /// Hinnant's `days_from_civil`).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

// MARK: - Claude Code

/// Per-file timing state for a Claude Code transcript.
///
/// One assistant message is written as one line per content block, all
/// sharing `message.id` + `requestId`, each stamped when its block finished.
/// The group's earliest line is the first block, its latest the completion,
/// and the transcript line written just before the group's first line is
/// when the request went out.
///
/// Only conversation lines count as that line — the ones with a
/// `parentUuid` (prompts, tool results, attachments, system notes, other
/// responses). Bookkeeping lines (`queue-operation`, `file-history-*`,
/// `custom-title`, …) are written asynchronously, sometimes while a response
/// is streaming, and would cut a request short.
struct ClaudeRequestTimingTracker {
    struct Group {
        var start: Date?
        var firstBlock: Date
        var lastBlock: Date
    }

    private(set) var groups: [String: Group] = [:]
    private var lastLineDate: Date?
    private var lastLineGroup: String?

    /// A conversation line that is not part of a keyed response.
    mutating func observeConversationLine(at date: Date) {
        lastLineDate = date
        lastLineGroup = nil
    }

    /// One content-block line of the response keyed `key`.
    mutating func observeBlock(key: String, at date: Date) {
        if var group = groups[key] {
            if date < group.firstBlock { group.firstBlock = date }
            if date > group.lastBlock { group.lastBlock = date }
            groups[key] = group
        } else {
            let start = lastLineGroup == key ? nil : lastLineDate
            groups[key] = Group(start: start, firstBlock: date, lastBlock: date)
        }
        lastLineDate = date
        lastLineGroup = key
    }

    /// Feed a line the scanner did not JSON-parse: when it is a conversation
    /// line, its timestamp becomes the candidate start of the next response.
    mutating func observeUnparsedLine(_ line: Data) {
        let date: Date? = line.withUnsafeBytes { bytes in
            // `parentUuid` is the first key Claude Code writes; 512 bytes
            // tolerates a reordering without reading a whole tool result.
            guard JSONLLineProbe.firstIndex(of: JSONLLineProbe.parentUUIDKey, in: bytes, limit: 512) != nil else {
                return nil
            }
            return JSONLLineProbe.firstTimestamp(in: bytes)
        }
        if let date { observeConversationLine(at: date) }
    }

    func timing(for key: String) -> (start: Date?, firstBlock: Date?, completed: Date?) {
        guard let group = groups[key] else { return (nil, nil, nil) }
        return UsageRequestTiming.sanitized(start: group.start, firstBlock: group.firstBlock, completed: group.lastBlock)
    }
}

// MARK: - Codex

/// Per-file timing state for a Codex rollout.
///
/// One model request is: the line that opened it (`task_started`, a user
/// message, a tool call's output, a message from another agent), the items
/// the model produced (reasoning, messages, tool calls), and the
/// `token_usage_record` written when the response finished. The
/// `token_count` that reports the request's usage is *not* its end: when the
/// response called a tool, Codex runs the tool and writes its output first,
/// so the `token_count` lands after the next request's opening line.
/// Timing a request to its `token_count` would count tool execution as
/// generation time and hand the next request no start at all.
///
/// So the tracker keeps the request still being built and the one that just
/// finished: an opening line after the model has answered finishes the
/// current request and starts the next, and a `token_count` reports the
/// open request if the model answered it (no tool followed), otherwise the
/// one that just finished.
struct CodexRequestTimingTracker {
    enum LineKind: Equatable {
        /// `task_started`, a user message, a tool call's output, or a
        /// message another agent delivered.
        case requestStart
        /// An item the model produced.
        case responseItem
        /// `token_usage_record`: the response's usage was recorded, i.e. it
        /// finished streaming.
        case responseEnd
        case other
    }

    private struct Request {
        var start: Date?
        var firstBlock: Date?
        var lastBlock: Date?
    }

    private var current = Request()
    private var finished: Request?

    mutating func observe(_ kind: LineKind, at date: Date) {
        switch kind {
        case .requestStart:
            if current.firstBlock != nil {
                // The model already answered: this input opens the next request.
                finished = current
                current = Request(start: date)
            } else {
                current.start = date
            }
        case .responseItem:
            if current.firstBlock == nil { current.firstBlock = date }
            if current.lastBlock.map({ date > $0 }) ?? true { current.lastBlock = date }
        case .responseEnd:
            if current.firstBlock != nil, current.lastBlock.map({ date > $0 }) ?? true {
                current.lastBlock = date
            }
        case .other:
            break
        }
    }

    /// A `token_count` that recorded new usage: the request it reports.
    mutating func close() -> (start: Date?, firstBlock: Date?, completed: Date?) {
        let reported: Request
        if current.firstBlock != nil {
            reported = current
            current = Request()
        } else if let finished {
            reported = finished
        } else {
            return (nil, nil, nil)
        }
        finished = nil
        return (reported.start, reported.firstBlock, reported.lastBlock)
    }

    private static let responseItemType = Array(#""type":"response_item""#.utf8)
    private static let eventMessageType = Array(#""type":"event_msg""#.utf8)
    private static let usageRecordType = Array(#""type":"token_usage_record""#.utf8)
    private static let payloadType = Array(#""payload":{"type":""#.utf8)
    private static let roleKey = Array(#""role":""#.utf8)
    private static let message = Array("message".utf8)
    private static let user = Array("user".utf8)
    private static let assistant = Array("assistant".utf8)
    private static let taskStarted = Array("task_started".utf8)
    private static let agentMessage = Array("agent_message".utf8)
    private static let outputSuffix = Array("_output".utf8)
    /// Items the model itself produces. A list rather than "anything not an
    /// input": an unknown item type is then late or missing, which keeps the
    /// first-token figure an upper bound instead of making it optimistic.
    private static let modelItemTypes: [[UInt8]] = [
        "reasoning", "function_call", "custom_tool_call", "local_shell_call",
        "web_search_call", "tool_search_call", "image_generation_call"
    ].map { Array($0.utf8) }

    /// Classify a rollout line from its first bytes. Codex writes
    /// `{"timestamp":…,"type":…,"payload":{"type":…,"role":…` with the
    /// tags up front, so 512 bytes always reach them and a multi-megabyte
    /// tool output is never walked.
    static func classify(_ line: Data) -> (kind: LineKind, date: Date?) {
        line.withUnsafeBytes { bytes -> (LineKind, Date?) in
            let window = 512
            let kind: LineKind
            if JSONLLineProbe.firstIndex(of: responseItemType, in: bytes, limit: window) != nil {
                guard let type = JSONLLineProbe.value(after: payloadType, in: bytes, limit: window) else {
                    return (.other, nil)
                }
                if JSONLLineProbe.equals(type, message) {
                    let typeEnd = bytes.baseAddress.map { $0.distance(to: type.baseAddress ?? $0) } ?? 0
                    let role = JSONLLineProbe.value(after: roleKey, in: bytes, from: typeEnd, limit: window)
                    if let role, JSONLLineProbe.equals(role, user) {
                        kind = .requestStart
                    } else if let role, JSONLLineProbe.equals(role, assistant) {
                        kind = .responseItem
                    } else {
                        kind = .other
                    }
                } else if JSONLLineProbe.hasSuffix(type, outputSuffix) || JSONLLineProbe.equals(type, agentMessage) {
                    // A tool's output, or a message another agent addressed
                    // to this one: both arrive before the request they open.
                    kind = .requestStart
                } else if modelItemTypes.contains(where: { JSONLLineProbe.equals(type, $0) }) {
                    kind = .responseItem
                } else {
                    kind = .other
                }
            } else if JSONLLineProbe.firstIndex(of: usageRecordType, in: bytes, limit: window) != nil {
                kind = .responseEnd
            } else if JSONLLineProbe.firstIndex(of: eventMessageType, in: bytes, limit: window) != nil,
                      let type = JSONLLineProbe.value(after: payloadType, in: bytes, limit: window),
                      JSONLLineProbe.equals(type, taskStarted) {
                kind = .requestStart
            } else {
                kind = .other
            }
            guard kind != .other else { return (.other, nil) }
            return (kind, JSONLLineProbe.firstTimestamp(in: bytes, limit: window))
        }
    }
}
