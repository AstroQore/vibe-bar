import Foundation

/// Text helpers shared by the two structure parsers: one-line previews,
/// credential masking for argument/result summaries, injected-block
/// classification, and a fast timestamp reader.
enum SessionStructureText {
    // MARK: - Previews

    /// Collapse whitespace to single spaces and cap at `limit` characters
    /// (the ellipsis counts toward the limit). Walks at most a bounded
    /// prefix of `text`, so a megabyte of tool output costs the same as a
    /// line of it.
    static func preview(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var out = ""
        out.reserveCapacity(min(limit, 256))
        var count = 0
        var pendingSpace = false
        for character in text {
            let isSpace: Bool
            if let ascii = character.asciiValue {
                isSpace = ascii == 0x20 || (ascii >= 0x09 && ascii <= 0x0D)
            } else {
                isSpace = character.isWhitespace
            }
            if isSpace {
                pendingSpace = count > 0
                continue
            }
            let needed = pendingSpace ? 2 : 1
            if count + needed > limit {
                while count > limit - 1, !out.isEmpty {
                    out.removeLast()
                    count -= 1
                }
                while out.last == " " { out.removeLast() }
                return out + "…"
            }
            if pendingSpace {
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += 1
        }
        return out
    }

    /// Cap a multi-line text at `limit` characters without collapsing it.
    static func capped(_ text: String, limit: Int) -> String {
        let head = nativeHead(text, maxUTF16: limit * 2)
        guard head.count > limit else { return head }
        return String(head.prefix(max(0, limit - 1))) + "…"
    }

    /// A one-line, credential-masked summary for a step's arguments or
    /// result. Paths survive (`VisibleSecretRedactor` only masks API-key /
    /// JWT / bearer / assignment shapes); email addresses are masked too.
    /// The text is clipped *before* the regexes run so their cost is bounded.
    static func summary(_ raw: String?, limit: Int = SessionStructure.Step.summaryLimit) -> String? {
        guard let raw else { return nil }
        let clipped = preview(nativeHead(raw, maxUTF16: limit * 4), limit: limit * 2)
        guard !clipped.isEmpty else { return nil }
        var masked = clipped
        if mayContainCredential(clipped) {
            masked = VisibleSecretRedactor.redact(masked) ?? masked
        }
        if clipped.utf8.contains(UInt8(ascii: "@")) {
            masked = ProviderDiagnosticRedactor.maskEmails(in: masked)
        }
        let line = preview(masked, limit: limit)
        return line.isEmpty ? nil : line
    }

    private static let credentialHints: [[UInt8]] = [
        "sk-", "bearer", "authorization", "cookie", "token", "secret", "password",
        "api_key", "api-key", "apikey", "session_key", "session-key", "sessionkey"
    ].map { Array($0.utf8) }

    /// A cheap superset test for what `VisibleSecretRedactor` masks: one of
    /// its keywords, or a dotted three-segment run that could be a JWT. Its
    /// six regexes cost more than the rest of a parse when run on every
    /// summary, and almost no summary needs them.
    static func mayContainCredential(_ text: String) -> Bool {
        // ASCII-lowercased bytes searched with memmem: Foundation's
        // `contains` on String costs more than the regexes it guards.
        var bytes = Array(text.utf8)
        for index in bytes.indices where bytes[index] >= 0x41 && bytes[index] <= 0x5A {
            bytes[index] |= 0x20
        }
        let hit = bytes.withUnsafeBytes { haystack -> Bool in
            guard let base = haystack.baseAddress else { return false }
            return credentialHints.contains { needle in
                needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress, needle.count) != nil }
            }
        }
        if hit { return true }
        var run = 0
        var segments = 0
        for byte in text.utf8 {
            let isTokenByte = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x2D
            if isTokenByte {
                run += 1
            } else if byte == 0x2E, run >= 10 {
                segments += 1
                run = 0
            } else {
                segments = 0
                run = 0
            }
            if segments >= 2, run >= 10 { return true }
        }
        return false
    }

    // MARK: - Injected blocks

    /// Classify one machine-authored block by its leading marker. `nil`
    /// means the text does not look injected at all.
    static func injectedBlock(for text: String) -> SessionStructure.InjectedBlock? {
        let head = text.drop(while: { $0.isWhitespace }).prefix(160)
        let lowered = head.lowercased()
        if lowered.hasPrefix("#"), lowered.contains("agents.md instructions") { return .agentsInstructions }
        if lowered.hasPrefix("<instructions") || lowered.hasPrefix("<user_instructions") { return .agentsInstructions }
        if lowered.hasPrefix("<environment_context") { return .environmentContext }
        if lowered.hasPrefix("<system-reminder") { return .systemReminder }
        if lowered.hasPrefix("<task-notification") { return .taskNotification }
        if lowered.hasPrefix("<local-command-") || lowered.hasPrefix("<command-") || lowered.hasPrefix("<bash-") {
            return .commandOutput
        }
        if lowered.hasPrefix("<skill") { return .skill }
        if lowered.hasPrefix("<"), let name = leadingTagName(lowered), HumanPromptText.isMetaTag(name) {
            return .other
        }
        return nil
    }

    /// The distinct kinds of meta block (by opening tag, plus the AGENTS.md
    /// header form) inside one user text — what was stripped from a prompt.
    /// One message counts each kind once: the AGENTS.md header and the
    /// `<INSTRUCTIONS>` it wraps are one block.
    static func injectedBlocks(in text: String) -> [SessionStructure.InjectedBlock] {
        var seen = Set<SessionStructure.InjectedBlock>()
        return allInjectedBlocks(in: text).filter { seen.insert($0).inserted }
    }

    private static func allInjectedBlocks(in text: String) -> [SessionStructure.InjectedBlock] {
        var found: [SessionStructure.InjectedBlock] = []
        if text.range(of: "AGENTS.md instructions", options: [.caseInsensitive]) != nil {
            found.append(.agentsInstructions)
        }
        var cursor = text.startIndex
        var scanned = 0
        while scanned < 64, let lt = text[cursor...].firstIndex(of: "<") {
            scanned += 1
            let afterLT = text.index(after: lt)
            guard afterLT < text.endIndex, text[afterLT] != "/" else {
                cursor = afterLT
                continue
            }
            let nameEnd = text[afterLT...].firstIndex(where: { $0 == ">" || $0 == " " || $0 == "\n" || $0 == "/" })
                ?? text.endIndex
            let name = text[afterLT..<nameEnd].lowercased()
            cursor = nameEnd
            guard !name.isEmpty, HumanPromptText.isMetaTag(name) else { continue }
            if let block = injectedBlock(for: "<" + name) {
                found.append(block)
            }
            // Skip to the matching close so nested tags are not double counted.
            if let close = text.range(of: "</" + name, options: [.caseInsensitive], range: cursor..<text.endIndex) {
                cursor = close.upperBound
            }
        }
        return found
    }

    private static func leadingTagName(_ lowered: String) -> String? {
        guard lowered.hasPrefix("<") else { return nil }
        let body = lowered.dropFirst()
        let name = body.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - Timestamps

    /// `2026-10-08T12:34:56.789Z` (or `+hh:mm`, or no fraction) without an
    /// `ISO8601DateFormatter` round-trip; falls back to `SessionParsing.date`.
    static func date(_ value: Any?) -> Date? {
        if let raw = value as? String {
            return fastISODate(raw) ?? SessionParsing.date(raw)
        }
        return SessionParsing.date(value)
    }

    static func fastISODate(_ raw: String) -> Date? {
        let utf8 = Array(raw.utf8.prefix(40))
        guard utf8.count >= 20 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= utf8.count else { return nil }
            var value = 0
            for i in start..<(start + count) {
                let byte = utf8[i]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard utf8[4] == 45, utf8[7] == 45, utf8[10] == 84 || utf8[10] == 32,
              utf8[13] == 58, utf8[16] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var index = 19
        var fraction = 0.0
        if index < utf8.count, utf8[index] == 46 {
            index += 1
            var scale = 0.1
            while index < utf8.count, utf8[index] >= 48, utf8[index] <= 57 {
                fraction += Double(utf8[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        guard index < utf8.count else { return nil }
        switch utf8[index] {
        case 90: // Z
            break
        case 43, 45: // + / -
            guard let oh = digits(index + 1, 2) else { return nil }
            var om = 0
            if index + 3 < utf8.count, utf8[index + 3] == 58 {
                om = digits(index + 4, 2) ?? 0
            } else {
                om = digits(index + 3, 2) ?? 0
            }
            offsetSeconds = (oh * 3600 + om * 60) * (utf8[index] == 43 ? 1 : -1)
        default:
            return nil
        }
        var components = tm()
        components.tm_year = Int32(year - 1900)
        components.tm_mon = Int32(month - 1)
        components.tm_mday = Int32(day)
        components.tm_hour = Int32(hour)
        components.tm_min = Int32(minute)
        components.tm_sec = Int32(second)
        let epoch = timegm(&components)
        guard epoch != -1 || (year == 1969) else { return nil }
        return Date(timeIntervalSince1970: Double(epoch - offsetSeconds) + fraction)
    }

    // MARK: - JSON helpers

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            // Bool bridges to NSNumber; a flag is not a count.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.intValue
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func string(_ value: Any?) -> String? { SessionParsing.string(value) }

    /// Text of a Codex / Claude content value (string, block array, object).
    static func text(_ value: Any?) -> String { SessionParsing.extractText(value) }

    /// `{"secs": 1, "nanos": 500000000}` → 1500.
    static func durationMs(fromRust value: Any?) -> Int? {
        guard let dict = value as? [String: Any] else { return nil }
        let secs = int(dict["secs"]) ?? 0
        let nanos = int(dict["nanos"]) ?? 0
        return secs * 1000 + nanos / 1_000_000
    }

    /// Compact JSON for an argument object, keys sorted.
    static func compactJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    static func jsonObject(fromString text: String) -> [String: Any]? {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{",
              let data = text.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension SessionStructureText {
    /// `rollout-2026-02-03T13-58-51-019c2215-0f3c-7f72-89e3-92598c209589`
    /// → the trailing UUID; also accepts a bare UUID stem.
    static func trailingUUID(in stem: String) -> String? {
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return isUUIDShaped(candidate) ? candidate : nil
    }

    static func isUUIDShaped(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

extension SessionStructureText {
    /// How much of a user message the prompt extractor sees. A prompt is
    /// stored capped at 4 000 characters anyway, and `HumanPromptText`
    /// rescans its input once per meta tag, so an unbounded paste (or a
    /// transcript a guardian request quotes) would cost far more than it
    /// could change the answer.
    static let decisionPrefixLimit = 64 * 1024

    static func decisionPrefix(_ text: String) -> String {
        nativeHead(text, maxUTF16: decisionPrefixLimit)
    }

    /// At most `maxUTF16` code units of `text` (never splitting a composed
    /// character), as a *native* Swift string.
    ///
    /// Strings out of `JSONSerialization` are bridged `NSString`s, on which
    /// every Swift `Character` / index operation takes a slow foreign path;
    /// measured on a 32 MiB rollout that was most of the parse. Cutting
    /// through `NSString` (O(1) length, one substring) and making the result
    /// contiguous UTF-8 once keeps every later pass over it fast and bounded.
    static func nativeHead(_ text: String, maxUTF16: Int) -> String {
        let bridged = text as NSString
        var head: String
        if bridged.length <= maxUTF16 {
            head = text
        } else {
            let range = bridged.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: max(0, maxUTF16)))
            head = bridged.substring(with: NSRange(location: 0, length: min(range.length, bridged.length)))
        }
        head.makeContiguousUTF8()
        return head
    }

    /// Length in UTF-16 code units — O(1) on a bridged string, unlike `count`.
    static func length(_ text: String) -> Int { (text as NSString).length }
}
