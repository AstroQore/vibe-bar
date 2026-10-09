import Foundation
import os

/// A turn's prompt or final answer, split into the blocks the Sessions page
/// draws.
///
/// Agents answer in Markdown — headings, lists, fenced code, inline code —
/// and a transcript that shows the asterisks is a transcript nobody reads.
/// Foundation's `AttributedString(markdown:)` handles the inline half well
/// but its block output is a run soup that every caller has to regroup, so
/// the block structure is read here line by line (fences, headings, lists,
/// quotes, rules, pipe tables) and only each block's inline text goes
/// through Foundation. The result is plain data: building it happens off
/// the main actor, once per text (`SessionMarkdownCache`), and drawing it is
/// a loop over `blocks`.
///
/// Deliberately small. Nested block quotes, setext headings, HTML and
/// reference links are rendered as the text they are; a table is shown as
/// its aligned source in a monospaced block rather than as a grid.
public struct SessionMarkdownDocument: Sendable, Hashable {
    public enum Block: Sendable, Hashable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        /// `ordinal` is nil for a bullet. `depth` is 0 for a top-level item.
        case listItem(ordinal: Int?, depth: Int, text: AttributedString)
        case quote(AttributedString)
        case code(language: String?, text: String)
        /// A pipe table: the header cells, then each body row's cells, all
        /// inline-parsed. Rows are padded to the header's width.
        case table(header: [AttributedString], rows: [[AttributedString]])
        case rule
    }

    /// What the page draws: runs of prose merged into as few texts as the
    /// blocks allow, with code, tables and rules between them.
    ///
    /// A text view per paragraph and list item made a long answer dozens of
    /// views deep, and the stack layout around them measured each one
    /// several times over; laying out a turn was most of what scrolling a
    /// conversation cost. Consecutive paragraphs, list items and quotes are
    /// therefore one `AttributedString` — bullets and indentation written
    /// into the text — and a heading starts a segment of its own only so it
    /// can be drawn larger.
    public enum Segment: Sendable, Hashable {
        case heading(level: Int, text: AttributedString)
        case prose(AttributedString)
        case code(language: String?, text: String)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case rule
    }

    public var blocks: [Block]
    public var segments: [Segment]
    /// The text the document was read from, for copying.
    public var source: String

    public init(blocks: [Block], source: String) {
        self.blocks = blocks
        self.source = source
        self.segments = Self.segments(from: blocks)
    }

    public var isEmpty: Bool { blocks.isEmpty }

    static func segments(from blocks: [Block]) -> [Segment] {
        var out: [Segment] = []
        var prose = AttributedString()
        var previous: Block?

        func flush() {
            guard !prose.characters.isEmpty else { return }
            out.append(.prose(prose))
            prose = AttributedString()
        }

        func append(_ text: AttributedString, joinedTo last: Block?, isListItem: Bool) {
            if !prose.characters.isEmpty {
                // List items run on one line each; everything else is a
                // paragraph break.
                var listContinues = false
                if case .listItem = last, isListItem { listContinues = true }
                prose.append(AttributedString(listContinues ? "\n" : "\n\n"))
            }
            prose.append(text)
        }

        for block in blocks {
            switch block {
            case let .heading(level, text):
                flush()
                out.append(.heading(level: level, text: text))
            case let .paragraph(text):
                append(text, joinedTo: previous, isListItem: false)
            case let .listItem(ordinal, depth, text):
                let indent = String(repeating: "    ", count: depth)
                let marker = ordinal.map { "\($0). " } ?? "•  "
                var line = AttributedString(indent + marker)
                line.append(text)
                append(line, joinedTo: previous, isListItem: true)
            case let .quote(text):
                var line = AttributedString("▎ ")
                var body = text
                for run in body.runs {
                    body[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.emphasized)
                }
                line.append(body)
                append(line, joinedTo: previous, isListItem: false)
            case let .code(language, text):
                flush()
                out.append(.code(language: language, text: text))
            case let .table(header, rows):
                flush()
                out.append(.table(header: header, rows: rows))
            case .rule:
                flush()
                out.append(.rule)
            }
            previous = block
        }
        flush()
        return out
    }
}

public enum SessionMarkdown {
    /// Read `text` into blocks.
    public static func document(from text: String) -> SessionMarkdownDocument {
        SessionMarkdownDocument(blocks: blocks(from: text), source: text)
    }

    static func blocks(from text: String) -> [SessionMarkdownDocument.Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [SessionMarkdownDocument.Block] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence), candidate.drop(while: { String($0) == String(fence.first!) }).allSatisfy(\.isWhitespace) {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                out.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                out.append(.heading(level: heading.level, text: inline(heading.text)))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                out.append(.rule)
                index += 1
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var rows: [String] = []
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                out.append(table(rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                out.append(.quote(inline(quoted.joined(separator: "\n"))))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                var text = item.text
                index += 1
                // Lazy continuation: an indented line that does not open a
                // new item belongs to this one.
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty,
                          next.hasPrefix("  ") || next.hasPrefix("\t"),
                          listItem(next) == nil,
                          fenceMarker(nextTrimmed) == nil
                    else { break }
                    text += "\n" + nextTrimmed
                    index += 1
                }
                out.append(.listItem(ordinal: item.ordinal, depth: item.depth, text: inline(text)))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return out
    }

    // MARK: - Block recognizers

    /// The opening run of a code fence — every backtick or tilde of it, so
    /// a block opened with four can hold a three-character fence and close
    /// only on a run at least as long as its own.
    static func fenceMarker(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        return run.count >= 3 ? String(run) : nil
    }

    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for character in trimmed {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration.
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else {
            return false
        }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// `| a | b |` rows → cells. The separator row (`|---|:--:|`) is the
    /// second line and is dropped.
    static func table(_ lines: [String]) -> SessionMarkdownDocument.Block {
        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let header = cells(lines.first ?? "")
        let width = max(1, header.count)
        let body = lines.dropFirst(2).map { row -> [AttributedString] in
            var values = cells(row).prefix(width).map(inline)
            while values.count < width { values.append(AttributedString()) }
            return values
        }
        return .table(header: header.map(inline), rows: Array(body))
    }

    static func listItem(_ line: String) -> (ordinal: Int?, depth: Int, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        guard let first = rest.first else { return nil }
        let depth = min(3, indent / 2)
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            var text = String(after.dropFirst())
            // Task-list boxes read better as the glyphs they mean.
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑ " + text.dropFirst(4) }
            return (nil, depth, text)
        }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let marker = afterDigits.first, marker == "." || marker == ")",
              afterDigits.dropFirst().first == " "
        else { return nil }
        return (Int(digits), depth, String(afterDigits.dropFirst(2)))
    }

    // MARK: - Inline

    /// Emphasis, strong, inline code, strikethrough and links. A link is
    /// kept only for web and mail schemes: this text came out of a session
    /// log, and a click on it should not be able to open an arbitrary
    /// `file:` or custom-scheme URL.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in attributed.runs {
            guard let link = run.link else { continue }
            let scheme = link.scheme?.lowercased()
            if scheme != "http", scheme != "https", scheme != "mailto" {
                attributed[run.range].link = nil
            }
        }
        return attributed
    }
}

/// Parsed documents by source text, so a turn scrolled back into view — or
/// re-presented after an expansion — is never parsed twice.
///
/// Keyed by the text itself: two turns that said the same thing share one
/// entry, and a text that changed is a different key rather than a stale
/// hit. Bounded LRU; safe to use from any thread.
public final class SessionMarkdownCache: Sendable {
    public struct Counters: Sendable, Hashable {
        public var hits = 0
        public var misses = 0
    }

    private struct State {
        var documents: [String: SessionMarkdownDocument] = [:]
        var order: [String] = []
        var counters = Counters()
        var texts: [RichKey: SessionRichText] = [:]
        var textOrder: [RichKey] = []
    }

    private struct RichKey: Hashable {
        var text: String
        var size: CGFloat
    }

    public let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// The document for `text`, parsed on a miss.
    public func document(for text: String) -> SessionMarkdownDocument {
        document(for: text, counted: true)
    }

    /// `counted: false` is the rich-text path asking for the document it
    /// builds from — not a second request for the same Markdown.
    private func document(for text: String, counted: Bool) -> SessionMarkdownDocument {
        if let hit = state.withLock({ state -> SessionMarkdownDocument? in
            guard let found = state.documents[text] else { return nil }
            if counted { state.counters.hits += 1 }
            if let position = state.order.lastIndex(of: text), position != state.order.count - 1 {
                state.order.remove(at: position)
                state.order.append(text)
            }
            return found
        }) {
            return hit
        }
        // Parse outside the lock: two threads racing on one text both parse,
        // which costs a parse; holding the lock across it would cost every
        // other reader a wait.
        let parsed = SessionMarkdown.document(from: text)
        let capacity = self.capacity
        state.withLock { state in
            if counted { state.counters.misses += 1 }
            if state.documents.updateValue(parsed, forKey: text) == nil {
                state.order.append(text)
            }
            while state.order.count > capacity {
                let evicted = state.order.removeFirst()
                state.documents.removeValue(forKey: evicted)
            }
        }
        return parsed
    }

    /// `text` as one attributed string at `size` (`SessionRichText`), built
    /// on a miss from the cached document. Called off the main actor.
    public func richText(for text: String, size: CGFloat) -> SessionRichText {
        let key = RichKey(text: text, size: size)
        if let hit = state.withLock({ state -> SessionRichText? in
            guard let found = state.texts[key] else { return nil }
            if let position = state.textOrder.lastIndex(of: key), position != state.textOrder.count - 1 {
                state.textOrder.remove(at: position)
                state.textOrder.append(key)
            }
            return found
        }) {
            return hit
        }
        let built = SessionRichText.make(document(for: text, counted: false), fontSize: size)
        let capacity = self.capacity
        return state.withLock { state in
            // A racing builder may have stored one first; keep that one so
            // every caller holds the same string.
            if let stored = state.texts[key] { return stored }
            state.texts[key] = built
            state.textOrder.append(key)
            while state.textOrder.count > capacity {
                let evicted = state.textOrder.removeFirst()
                state.texts.removeValue(forKey: evicted)
            }
            return built
        }
    }

    public var counters: Counters { state.withLock { $0.counters } }
    public var count: Int { state.withLock { $0.documents.count } }

    public func removeAll() {
        state.withLock { $0 = State() }
    }
}
