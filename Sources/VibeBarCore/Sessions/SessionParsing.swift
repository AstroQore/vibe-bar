import Foundation

/// Provider-agnostic parsing primitives shared by the session adapters.
///
/// Every helper is total: bad input yields `nil` or an empty string
/// rather than throwing, because a single corrupt line in a rollout
/// must never sink the session list.
enum SessionParsing {
    // MARK: - JSON

    static func json(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Scalars

    static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// ISO-8601 with a tolerance for sub-millisecond precision. Grok
    /// writes microseconds (`...:28.436699Z`), which the strict
    /// fractional-seconds parser rejects, so the fraction is clamped to
    /// three digits before the retry.
    static func parseISO(_ raw: String) -> Date? {
        if let date = isoWithFraction.date(from: raw) { return date }
        if let date = isoStandard.date(from: raw) { return date }
        guard let clamped = clampingFractionalSeconds(raw) else { return nil }
        return isoWithFraction.date(from: clamped) ?? isoStandard.date(from: clamped)
    }

    private static func clampingFractionalSeconds(_ raw: String) -> String? {
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        var digitsEnd = raw.index(after: dot)
        var digits = 0
        while digitsEnd < raw.endIndex, raw[digitsEnd].isNumber {
            digits += 1
            digitsEnd = raw.index(after: digitsEnd)
        }
        guard digits > 3 else { return nil }
        let keep = raw.index(dot, offsetBy: 4)
        return String(raw[raw.startIndex..<keep]) + String(raw[digitsEnd...])
    }

    /// Dates arrive as ISO strings or as epoch numbers in seconds or
    /// milliseconds depending on the CLI and its vintage.
    static func date(_ value: Any?) -> Date? {
        if let raw = value as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let date = parseISO(trimmed) { return date }
            if let epoch = Double(trimmed) { return date(fromEpoch: epoch) }
            return nil
        }
        if let number = value as? NSNumber {
            return date(fromEpoch: number.doubleValue)
        }
        return nil
    }

    private static func date(fromEpoch value: Double) -> Date? {
        guard value > 0 else { return nil }
        // Anything past ~2001 in seconds is below 1e12; larger values
        // are milliseconds.
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    static func firstDate(_ values: Any?...) -> Date? {
        for value in values {
            if let date = date(value) { return date }
        }
        return nil
    }

    static func firstString(_ values: Any?...) -> String? {
        for value in values {
            if let string = string(value) { return string }
        }
        return nil
    }

    // MARK: - Content extraction

    private static let maxContentDepth = 8

    /// Flatten a message `content` value into display text.
    ///
    /// - a plain string is itself;
    /// - an array joins its blocks with newlines, rendering `tool_use`
    ///   as `[Tool: name]` and recursing into `tool_result` content;
    /// - an object falls back to its `text` (then `input_text` /
    ///   `output_text` / nested `content`).
    static func extractText(_ value: Any?) -> String {
        extractText(value, depth: 0)
    }

    private static func extractText(_ value: Any?, depth: Int) -> String {
        guard depth < maxContentDepth, let value else { return "" }
        if let text = value as? String { return text }
        if let array = value as? [Any] {
            var parts: [String] = []
            for item in array {
                let part = extractBlock(item, depth: depth + 1)
                if !part.isEmpty { parts.append(part) }
            }
            return parts.joined(separator: "\n")
        }
        if let dict = value as? [String: Any] {
            return extractBlock(dict, depth: depth + 1)
        }
        return ""
    }

    private static func extractBlock(_ item: Any, depth: Int) -> String {
        if let text = item as? String { return text }
        guard depth < maxContentDepth, let dict = item as? [String: Any] else { return "" }
        switch dict["type"] as? String {
        case "tool_use":
            let name = (dict["name"] as? String) ?? "tool"
            return "[Tool: \(name)]"
        case "tool_result":
            return extractText(dict["content"], depth: depth + 1)
        default:
            if let text = dict["text"] as? String { return text }
            if let text = dict["input_text"] as? String { return text }
            if let text = dict["output_text"] as? String { return text }
            if let nested = dict["content"] { return extractText(nested, depth: depth + 1) }
            return ""
        }
    }

    /// First of several candidate fields that flattens to real text.
    /// Providers disagree on whether a turn's payload lives under
    /// `content`, `text`, or `message`.
    static func firstNonEmptyText(_ values: Any?...) -> String {
        for value in values {
            let text = extractText(value)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// True when every block in a content array is a `tool_result`.
    /// Claude Code files those under the `user` role even though they
    /// are transcript-wise tool output.
    static func isAllToolResults(_ value: Any?) -> Bool {
        guard let array = value as? [Any], !array.isEmpty else { return false }
        for item in array {
            guard let dict = item as? [String: Any],
                  dict["type"] as? String == "tool_result"
            else { return false }
        }
        return true
    }

    // MARK: - Display strings

    static func singleLine(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Collapse to one line and clip — the shape both `title` (80) and
    /// `summary` (160) want.
    static func display(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let line = singleLine(text)
        guard !line.isEmpty else { return nil }
        return truncate(line, limit: limit)
    }

    static let titleLimit = 80
    static let summaryLimit = 160

    // MARK: - Filesystem

    /// Recursive file sweep that never follows symlinks. A link inside
    /// `~/.claude` could resolve anywhere, and a deletable list must
    /// not contain paths the provider never wrote.
    static func collectFiles(under root: URL, matching predicate: (URL) -> Bool) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator where predicate(url) {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == false { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    static func fileSize(_ url: URL) -> Int64 {
        max(0, JSONLHeadTail.fileSize(url))
    }

    /// Total bytes under a directory. Used where the deletion unit is a
    /// directory (Grok) rather than a single file.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}
