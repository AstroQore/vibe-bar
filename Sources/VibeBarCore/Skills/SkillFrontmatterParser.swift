import Foundation

/// Minimal YAML frontmatter reader for `SKILL.md`.
///
/// Only the two top-level scalars Vibe Bar displays are recovered — `name` and
/// `description` — in plain, quoted, and folded (`>` / `>-` / `|`) forms.
/// Everything else (nested `metadata:` trees, anchors, flow collections) is
/// skipped rather than parsed, and any shape this does not understand yields
/// `nil` fields instead of an error: a skill with exotic frontmatter still
/// installs, it just falls back to its directory name.
public enum SkillFrontmatterParser {
    public struct Frontmatter: Equatable, Sendable {
        public let name: String?
        public let description: String?

        public init(name: String?, description: String?) {
            self.name = name
            self.description = description
        }

        public static let empty = Frontmatter(name: nil, description: nil)
    }

    public static func parse(contentsOf url: URL) -> Frontmatter {
        guard
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return .empty }
        return parse(text)
    }

    public static func parse(_ raw: String) -> Frontmatter {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        guard let opener = lines.first, opener.trimmingCharacters(in: .whitespaces) == "---" else {
            return .empty
        }
        lines.removeFirst()

        var values: [String: String] = [:]
        var blockKey: String?
        var blockLines: [String] = []
        func flushBlock() {
            if let key = blockKey, values[key] == nil, !blockLines.isEmpty {
                values[key] = blockLines.joined(separator: " ")
            }
            blockKey = nil
            blockLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }
            if trimmed.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                if blockKey != nil { blockLines.append(trimmed) }
                continue
            }
            flushBlock()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description" else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix(">") || value.hasPrefix("|") {
                blockKey = key
            } else if values[key] == nil {
                values[key] = unquoted(value)
            }
        }
        flushBlock()
        return Frontmatter(name: values["name"], description: values["description"])
    }

    private static func unquoted(_ value: String) -> String {
        guard
            value.count >= 2,
            let first = value.first,
            let last = value.last,
            first == last,
            first == "\"" || first == "'"
        else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner
    }
}
