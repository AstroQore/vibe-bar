import Foundation

/// What a session did, by local day: which tools it called, which skills it
/// used, and — for Codex, whose ledger rows carry no session id — how large
/// its prompts were and when it was active.
///
/// Derived data, like the structure sidecar: every field can be recomputed
/// from the session file, and nothing here quotes a message. Names are the
/// harness's own (`exec`, `Bash`, `mcp__github__list_prs`) and skill names
/// are directory names.
public struct SessionActivityTally: Codable, Sendable, Hashable {
    public struct Day: Codable, Sendable, Hashable {
        public var tools: [String: Int]
        public var skills: [String: Int]

        public init(tools: [String: Int] = [:], skills: [String: Int] = [:]) {
            self.tools = tools
            self.skills = skills
        }
    }

    /// Local `yyyy-MM-dd` (the ledger's day key) → that day's counts.
    public var days: [String: Day]
    public var skillLastUsed: [String: Date]
    /// Prompt size (fresh + cached input) of the first request.
    public var firstPromptTokens: Int?
    public var maxPromptTokens: Int?
    /// Requests whose usage the file recorded.
    public var requests: Int
    /// The window the harness reported for its model, when it reports one.
    public var contextWindow: Int?
    /// Distinct five-minute slots with any timestamped record.
    public var activeSlots: Int
    /// Days with any timestamped record, sorted.
    public var activeDays: [String]
    public var firstEventAt: Date?
    public var lastEventAt: Date?

    public init(
        days: [String: Day] = [:],
        skillLastUsed: [String: Date] = [:],
        firstPromptTokens: Int? = nil,
        maxPromptTokens: Int? = nil,
        requests: Int = 0,
        contextWindow: Int? = nil,
        activeSlots: Int = 0,
        activeDays: [String] = [],
        firstEventAt: Date? = nil,
        lastEventAt: Date? = nil
    ) {
        self.days = days
        self.skillLastUsed = skillLastUsed
        self.firstPromptTokens = firstPromptTokens
        self.maxPromptTokens = maxPromptTokens
        self.requests = requests
        self.contextWindow = contextWindow
        self.activeSlots = activeSlots
        self.activeDays = activeDays
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
    }

    public var totalToolCalls: Int {
        days.values.reduce(0) { $0 + $1.tools.values.reduce(0, +) }
    }
}

/// One streaming pass over a Codex or Claude JSONL file that fills a
/// `SessionActivityTally` without decoding JSON.
///
/// Every check is a byte search on the line (`memmem`), anchored to keys
/// both harnesses write in a fixed shape, so a multi-gigabyte rollout costs
/// one read and no object graph. What counts:
///
/// - **Tool calls.** Codex `response_item` payloads of type `function_call`,
///   `custom_tool_call`, `local_shell_call`, `web_search_call`,
///   `image_generation_call`, `tool_search_call`; Claude `tool_use` content
///   blocks. One per call, by the name the harness wrote.
/// - **Skills.** Claude: a `Skill` tool call (`input.skill`) and the
///   `Base directory for this skill:` line the harness injects when one
///   loads — the same invocation seen twice, so a session counts the larger
///   of the two — plus a tool call that reads a `skills/<name>/SKILL.md`.
///   Codex: a `<skill>` block injected into a user message, plus a tool call
///   that reads a `SKILL.md`. Paths listed in instructions (Codex prints
///   every installed skill's path into its developer message) are not tool
///   calls and do not count.
/// - **Prompt size (Codex).** `token_count.info.last_token_usage.input_tokens`
///   (Codex input includes the cached part), once per change of
///   `total_token_usage.total_tokens`, and `model_context_window`.
public enum SessionActivityScanner {
    /// Bump when a change alters what an already-scanned file should say.
    ///
    /// v2: Codex lines with sorted keys (`type` after the payload's fields)
    /// are read; v1 named their tool calls `tool` or missed them.
    public static let version = 2

    public static func supports(_ provider: SessionProvider) -> Bool {
        provider == .codex || provider == .claude || provider == .claudeCowork
    }

    public static func scan(
        fileURL: URL,
        provider: SessionProvider,
        calendar: Calendar = UsageDashboardCalendar.local,
        isCancelled: () -> Bool = { false }
    ) -> SessionActivityTally? {
        guard supports(provider) else { return nil }
        var state = ScanState(isCodex: provider == .codex, calendar: calendar)
        let outcome = SessionStructureLineReader.forEachLine(
            in: fileURL,
            maxLineBytes: 1 * 1024 * 1024,
            headBytes: 64 * 1024,
            isCancelled: isCancelled
        ) { line in
            line.data.withUnsafeBytes { raw in
                state.consume(Bytes(raw))
            }
            return true
        }
        guard outcome.completed || outcome.bytesRead > 0, !isCancelled() else { return nil }
        return state.finish()
    }

    // MARK: - Byte helpers

    /// A read-only view of one line.
    struct Bytes {
        let base: UnsafePointer<UInt8>?
        let count: Int

        init(_ raw: UnsafeRawBufferPointer) {
            base = raw.bindMemory(to: UInt8.self).baseAddress
            count = raw.count
        }

        init(base: UnsafePointer<UInt8>?, count: Int) {
            self.base = base
            self.count = count
        }

        /// Offset of the first `needle` at or after `from`, searching at most
        /// `within` bytes.
        func find(_ needle: StaticNeedle, from: Int = 0, within: Int? = nil) -> Int? {
            guard let base, from >= 0, from < count else { return nil }
            let end = within.map { min(count, from + $0) } ?? count
            let length = end - from
            guard length >= needle.bytes.count else { return nil }
            return needle.bytes.withUnsafeBufferPointer { pattern -> Int? in
                guard let hit = memmem(base + from, length, pattern.baseAddress, pattern.count) else { return nil }
                return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
        }

        func contains(_ needle: StaticNeedle, within: Int? = nil) -> Bool {
            find(needle, within: within) != nil
        }

        /// The bytes from `start` up to (not including) the first byte in
        /// `stops`, at most `limit` long, as a string.
        func string(from start: Int, until stops: Set<UInt8>, limit: Int = 128) -> String? {
            guard let base, start >= 0, start < count else { return nil }
            var end = start
            let cap = min(count, start + limit)
            while end < cap, !stops.contains(base[end]) { end += 1 }
            guard end > start, end < cap || end == count else { return nil }
            return String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
        }

        /// `"key":"value"` → value, for a key found at or after `from`.
        func quotedValue(after key: StaticNeedle, from: Int = 0, within: Int? = nil, limit: Int = 160) -> String? {
            guard let at = find(key, from: from, within: within) else { return nil }
            return string(from: at + key.bytes.count, until: [0x22, 0x5C], limit: limit)
        }

        /// Whether `byte` occurs in `range`.
        func containsByte(_ byte: UInt8, in range: Range<Int>) -> Bool {
            guard let base, range.lowerBound >= 0, range.upperBound <= count, !range.isEmpty else { return false }
            return memchr(base + range.lowerBound, Int32(byte), range.count) != nil
        }

        /// A `"name":"…"` that starts within `within` bytes after `start`
        /// with no `}` in between (so it belongs to the same object).
        func nameAfter(_ start: Int, within: Int) -> String? {
            guard let hit = find(Needle.name, from: start, within: within),
                  !containsByte(0x7D, in: start..<hit)
            else { return nil }
            return string(from: hit + Needle.name.bytes.count, until: [0x22, 0x5C], limit: 160)
        }

        /// The last `"name":"…"` that starts within `within` bytes before
        /// `end` (and not before `floor`) with no brace between it and `end`.
        func nameBefore(_ end: Int, notBefore floor: Int, within: Int) -> String? {
            let lower = max(floor, end - within)
            guard lower < end else { return nil }
            var cursor = lower
            var last: Int?
            while let hit = find(Needle.name, from: cursor, within: end - cursor) {
                last = hit
                cursor = hit + 1
            }
            guard let last else { return nil }
            let valueStart = last + Needle.name.bytes.count
            guard let value = string(from: valueStart, until: [0x22, 0x5C], limit: 160) else { return nil }
            let after = valueStart + value.utf8.count
            guard after <= end, !containsByte(0x7B, in: after..<end), !containsByte(0x7D, in: after..<end) else { return nil }
            return value
        }

        /// `"key":123` → 123, for a key found at or after `from`.
        func intValue(after key: StaticNeedle, from: Int = 0, within: Int? = nil) -> Int? {
            guard let base, let at = find(key, from: from, within: within) else { return nil }
            var index = at + key.bytes.count
            while index < count, base[index] == 0x20 { index += 1 }
            var value = 0
            var digits = 0
            while index < count, base[index] >= 0x30, base[index] <= 0x39, digits < 15 {
                value = value * 10 + Int(base[index] - 0x30)
                digits += 1
                index += 1
            }
            return digits > 0 ? value : nil
        }
    }

    struct StaticNeedle {
        let bytes: [UInt8]
        init(_ text: String) { bytes = Array(text.utf8) }
    }

    enum Needle {
        static let timestamp = StaticNeedle("\"timestamp\":\"")
        static let responseItem = StaticNeedle("\"type\":\"response_item\"")
        static let eventMessage = StaticNeedle("\"type\":\"event_msg\"")
        static let tokenCount = StaticNeedle("\"type\":\"token_count\"")
        static let functionCall = StaticNeedle("\"type\":\"function_call\"")
        static let customToolCall = StaticNeedle("\"type\":\"custom_tool_call\"")
        static let localShellCall = StaticNeedle("\"type\":\"local_shell_call\"")
        static let webSearchCall = StaticNeedle("\"type\":\"web_search_call\"")
        static let imageGenerationCall = StaticNeedle("\"type\":\"image_generation_call\"")
        static let toolSearchCall = StaticNeedle("\"type\":\"tool_search_call\"")
        static let message = StaticNeedle("\"type\":\"message\"")
        static let roleUser = StaticNeedle("\"role\":\"user\"")
        static let name = StaticNeedle("\"name\":\"")
        static let lastUsage = StaticNeedle("\"last_token_usage\":")
        static let totalUsage = StaticNeedle("\"total_token_usage\":")
        static let inputTokens = StaticNeedle("\"input_tokens\":")
        static let totalTokens = StaticNeedle("\"total_tokens\":")
        static let contextWindow = StaticNeedle("\"model_context_window\":")
        static let skillBlock = StaticNeedle("<skill>")
        static let skillNameTag = StaticNeedle("<name>")
        static let skillPathTag = StaticNeedle("<path>")
        static let skillsDirectory = StaticNeedle("/skills/")
        static let skillFile = StaticNeedle("/SKILL.md")
        static let toolUse = StaticNeedle("\"type\":\"tool_use\"")
        static let skillInput = StaticNeedle("\"skill\":\"")
        static let baseDirectory = StaticNeedle("Base directory for this skill: ")
    }

    private static let nameStops: Set<UInt8> = [0x22, 0x5C, 0x3C, 0x2F, 0x20, 0x0A]

    // MARK: - State

    struct ScanState {
        let isCodex: Bool
        let calendar: Calendar
        private let dayFormatter: DateFormatter

        private var days: [String: SessionActivityTally.Day] = [:]
        private var skillLastUsed: [String: Date] = [:]
        private var lastDate: Date?
        private var firstEventAt: Date?
        private var slots: Set<Int64> = []
        private var activeDays: Set<String> = []
        private var dayCache: (slot: Int64, key: String)?

        // Skill evidence, kept apart until the end so one invocation seen
        // twice (Claude's tool call and its base-directory line) counts once.
        private var skillPrimary: [String: [Date?]] = [:]
        private var skillEcho: [String: [Date?]] = [:]
        private var skillReads: [String: [Date?]] = [:]

        private var firstPrompt: Int?
        private var maxPrompt: Int?
        private var requests = 0
        private var lastTotal: Int?
        private var contextWindow: Int?

        init(isCodex: Bool, calendar: Calendar) {
            self.isCodex = isCodex
            self.calendar = calendar
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            dayFormatter = formatter
        }

        mutating func consume(_ line: Bytes) {
            guard line.count > 2 else { return }
            let date = timestamp(in: line)
            if let date {
                lastDate = date
                if firstEventAt == nil || date < firstEventAt! { firstEventAt = date }
                let slot = Int64(date.timeIntervalSince1970) / UsageLedgerDashboardFacts.sessionActivitySlotSeconds
                if slots.insert(slot).inserted {
                    activeDays.insert(dayKey(date))
                }
            }
            if isCodex {
                consumeCodex(line, date: date ?? lastDate)
            } else {
                consumeClaude(line, date: date ?? lastDate)
            }
        }

        // MARK: Codex

        private mutating func consumeCodex(_ line: Bytes, date: Date?) {
            // Codex writes the line's `type` and then the payload's `type`
            // first, both inside the first few hundred bytes. A rollout
            // re-serialized with sorted keys puts every `type` after the
            // fields it describes, so a line whose head names neither kind of
            // record is searched whole — the same markers, just unbounded.
            let head = 320
            let scope: Int? = line.contains(Needle.responseItem, within: head) || line.contains(Needle.eventMessage, within: head)
                ? head : nil
            if line.contains(Needle.tokenCount, within: scope) {
                consumeTokenCount(line)
                return
            }
            guard line.contains(Needle.responseItem, within: scope) else { return }
            let call = line.find(Needle.functionCall, within: scope).map { ($0, Needle.functionCall) }
                ?? line.find(Needle.customToolCall, within: scope).map { ($0, Needle.customToolCall) }
            if let (at, marker) = call {
                // The name sits in the same object as the `type`: after it in
                // Codex's own order (`type`, `id`, `name`), before it when the
                // keys are sorted (`arguments`, `call_id`, `id`, `name`,
                // `type`) — the Claude path's rule, no brace in between.
                let name = line.nameAfter(at + marker.bytes.count, within: 2_048)
                    ?? line.nameBefore(at, notBefore: 0, within: 4_096)
                    ?? "tool"
                addTool(name, date: date)
                recordSkillReads(in: line, date: date)
            } else if line.contains(Needle.localShellCall, within: scope) {
                addTool("local_shell", date: date)
                recordSkillReads(in: line, date: date)
            } else if line.contains(Needle.webSearchCall, within: scope) {
                addTool("web_search", date: date)
            } else if line.contains(Needle.imageGenerationCall, within: scope) {
                addTool("image_generation", date: date)
            } else if line.contains(Needle.toolSearchCall, within: scope) {
                addTool("tool_search", date: date)
            } else if line.contains(Needle.message, within: scope), line.contains(Needle.roleUser) {
                // `role` follows `type` in Codex's own order; sorted keys put
                // it after the content, so the whole line is searched. Inside
                // a string it would be escaped.
                recordInjectedSkills(in: line, date: date)
            }
        }

        private mutating func consumeTokenCount(_ line: Bytes) {
            if let window = line.intValue(after: Needle.contextWindow), window > 0 {
                contextWindow = window
            }
            guard let lastAt = line.find(Needle.lastUsage),
                  let input = line.intValue(after: Needle.inputTokens, from: lastAt, within: 200)
            else { return }
            let total = line.find(Needle.totalUsage).flatMap {
                line.intValue(after: Needle.totalTokens, from: $0, within: 400)
            }
            // `token_count` repeats on rate-limit updates with the same
            // totals; a request is a change of the running total.
            if let total {
                guard total != lastTotal else { return }
                lastTotal = total
            }
            guard input > 0 else { return }
            requests += 1
            if firstPrompt == nil { firstPrompt = input }
            maxPrompt = max(maxPrompt ?? 0, input)
        }

        private mutating func recordInjectedSkills(in line: Bytes, date: Date?) {
            var cursor = 0
            var seen: Set<String> = []
            while let at = line.find(Needle.skillBlock, from: cursor) {
                cursor = at + Needle.skillBlock.bytes.count
                var name: String?
                if let tag = line.find(Needle.skillNameTag, from: cursor, within: 48) {
                    name = line.string(from: tag + Needle.skillNameTag.bytes.count, until: SessionActivityScanner.nameStops, limit: 80)
                }
                if name == nil, let tag = line.find(Needle.skillPathTag, from: cursor, within: 600) {
                    name = skillName(inPathAt: tag, line: line, within: 600)
                }
                if let name = SessionActivityScanner.validSkillName(name), seen.insert(name).inserted {
                    skillPrimary[name, default: []].append(date)
                }
            }
        }

        // MARK: Claude

        private mutating func consumeClaude(_ line: Bytes, date: Date?) {
            var cursor = 0
            var previousEnd = 0
            let markerLength = Needle.toolUse.bytes.count
            while let at = line.find(Needle.toolUse, from: cursor) {
                let markerEnd = at + markerLength
                let next = line.find(Needle.toolUse, from: markerEnd) ?? line.count
                // Claude Code writes `type` first and the name after the id;
                // a re-serialized log may sort the keys, which puts the name
                // (and the input) *before* the type. Either way the name is
                // inside the same block, so no brace may sit between them.
                let found = line.nameAfter(markerEnd, within: 200)
                    .map { (name: $0, forward: true) }
                    ?? line.nameBefore(at, notBefore: previousEnd, within: 300).map { (name: $0, forward: false) }
                let name = found?.name ?? "tool"
                addTool(name, date: date)
                let region = (found?.forward ?? true)
                    ? markerEnd..<min(next, markerEnd + 4_096)
                    : max(previousEnd, at - 4_096)..<at
                if name == "Skill",
                   let skill = SessionActivityScanner.validSkillName(
                       line.quotedValue(after: Needle.skillInput, from: region.lowerBound, within: region.count, limit: 120)
                   ) {
                    skillPrimary[skill, default: []].append(date)
                } else if let read = skillFileHit(in: line, from: region.lowerBound, within: region.count)?.name {
                    skillReads[read, default: []].append(date)
                }
                previousEnd = markerEnd
                cursor = markerEnd
            }
            if let at = line.find(Needle.baseDirectory) {
                let start = at + Needle.baseDirectory.bytes.count
                if let path = line.string(from: start, until: [0x22, 0x5C, 0x0A], limit: 1_024),
                   let name = SessionActivityScanner.validSkillName(
                       path.split(separator: "/").last.map(String.init)
                   ) {
                    skillEcho[name, default: []].append(date)
                }
            }
        }

        // MARK: Shared

        private mutating func recordSkillReads(in line: Bytes, date: Date?) {
            var cursor = 0
            var seen: Set<String> = []
            while let found = skillFileHit(in: line, from: cursor, within: nil) {
                cursor = found.next
                if seen.insert(found.name).inserted {
                    skillReads[found.name, default: []].append(date)
                }
            }
        }

        /// The next `/skills/<name>/SKILL.md` at or after `from`.
        private func skillFileHit(in line: Bytes, from: Int, within: Int?) -> (name: String, next: Int)? {
            var cursor = from
            let end = within.map { min(line.count, from + $0) } ?? line.count
            while cursor < end, let at = line.find(Needle.skillsDirectory, from: cursor, within: end - cursor) {
                let nameStart = at + Needle.skillsDirectory.bytes.count
                cursor = nameStart
                guard let name = line.string(from: nameStart, until: SessionActivityScanner.nameStops, limit: 80),
                      line.find(Needle.skillFile, from: nameStart + name.utf8.count, within: Needle.skillFile.bytes.count) != nil,
                      let valid = SessionActivityScanner.validSkillName(name)
                else { continue }
                return (valid, nameStart + name.utf8.count)
            }
            return nil
        }

        private func skillName(inPathAt tag: Int, line: Bytes, within: Int) -> String? {
            skillFileHit(in: line, from: tag, within: within)?.name
        }

        private mutating func addTool(_ rawName: String, date: Date?) {
            let name = rawName.isEmpty ? "tool" : rawName
            let key: String
            if let date { key = dayKey(date) } else { key = "" }
            days[key, default: SessionActivityTally.Day()].tools[name, default: 0] += 1
        }

        private mutating func timestamp(in line: Bytes) -> Date? {
            // Codex writes it first (sorted keys put it after the payload);
            // Claude near the end of the line.
            let at = isCodex
                ? (line.find(Needle.timestamp, within: 64) ?? line.find(Needle.timestamp))
                : line.find(Needle.timestamp)
            guard let at, let raw = line.string(from: at + Needle.timestamp.bytes.count, until: [0x22], limit: 40) else {
                return nil
            }
            return SessionStructureText.fastISODate(raw)
        }

        private mutating func dayKey(_ date: Date) -> String {
            // Most consecutive records share a five-minute slot, and a slot
            // never straddles a local midnight in a whole-hour time zone.
            let slot = Int64(date.timeIntervalSince1970) / UsageLedgerDashboardFacts.sessionActivitySlotSeconds
            if let dayCache, dayCache.slot == slot { return dayCache.key }
            let key = dayFormatter.string(from: date)
            dayCache = (slot, key)
            return key
        }

        mutating func finish() -> SessionActivityTally {
            // Undated tool calls (no timestamp anywhere before them) land on
            // the first dated day, or are dropped if the file had none.
            if let undated = days.removeValue(forKey: ""), let first = firstEventAt {
                let key = dayKey(first)
                for (name, count) in undated.tools {
                    days[key, default: SessionActivityTally.Day()].tools[name, default: 0] += count
                }
            }
            let names = Set(skillPrimary.keys).union(skillEcho.keys).union(skillReads.keys)
            for name in names {
                let primary = skillPrimary[name] ?? []
                let echo = skillEcho[name] ?? []
                // Claude's tool call and its base-directory line are the same
                // invocation; Codex has no echo, so this is just `primary`.
                let invocations = (primary.count >= echo.count ? primary : echo) + (skillReads[name] ?? [])
                for date in invocations {
                    guard let when = date ?? firstEventAt else { continue }
                    let key = dayKey(when)
                    days[key, default: SessionActivityTally.Day()].skills[name, default: 0] += 1
                    if skillLastUsed[name].map({ when > $0 }) ?? true { skillLastUsed[name] = when }
                }
            }
            return SessionActivityTally(
                days: days,
                skillLastUsed: skillLastUsed,
                firstPromptTokens: firstPrompt,
                maxPromptTokens: maxPrompt,
                requests: requests,
                contextWindow: contextWindow,
                activeSlots: slots.count,
                activeDays: activeDays.sorted(),
                firstEventAt: firstEventAt,
                lastEventAt: lastDate
            )
        }
    }

    /// A skill name is a directory name: 1–64 of `[A-Za-z0-9._:-]`, not
    /// starting with a dot. Anything else is a false hit.
    static func validSkillName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(name.utf8.count), !name.hasPrefix(".") else { return nil }
        let allowed = name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x3A
        }
        return allowed ? name : nil
    }
}
