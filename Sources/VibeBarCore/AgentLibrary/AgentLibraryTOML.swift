import Foundation

/// A narrow, preserving editor for MCP tables. Unrelated text is never
/// regenerated. Unsupported expressions remain opaque and cannot be changed.
struct AgentLibraryTOML {
    struct Assignment {
        let key: String
        let value: AgentLibraryValue
        let range: Range<Int>
        let comment: String
    }
    struct Table {
        let path: [String]
        let range: Range<Int>
        let assignments: [String: Assignment]
    }
    let lines: [String]
    let tables: [Table]
    let entries: [String: [String: AgentLibraryValue]]

    init(_ data: Data?) throws {
        guard let text = String(data: data ?? Data(), encoding: .utf8) else { throw AgentLibraryError.invalidDocument }
        let lines = text.components(separatedBy: "\n")
        var headers: [(Int, [String])] = []
        var multiline: String?
        for (index, line) in lines.enumerated() {
            if let active = multiline {
                if Self.markerCount(active, in: line) % 2 == 1 { multiline = nil }
                continue
            }
            let content = Self.withoutComment(line).trimmingCharacters(in: .whitespaces)
            for marker in ["\"\"\"", "'''"] where Self.markerCount(marker, in: content) % 2 == 1 {
                multiline = marker
            }
            if content.hasPrefix("[") {
                guard content.hasSuffix("]") else { throw AgentLibraryError.unsupportedTOML }
                let isArray = content.hasPrefix("[[")
                let body = String(content.dropFirst(isArray ? 2 : 1).dropLast(isArray ? 2 : 1))
                let path = try Self.keys(body)
                if isArray && path.first == "mcp_servers" { throw AgentLibraryError.unsupportedTOML }
                headers.append((index, path))
            } else if headers.isEmpty, content.hasPrefix("mcp_servers"), content.contains("=") {
                throw AgentLibraryError.unsupportedTOML
            }
        }
        guard multiline == nil else { throw AgentLibraryError.unsupportedTOML }
        var tables: [Table] = []
        var entries: [String: [String: AgentLibraryValue]] = [:]
        for (position, header) in headers.enumerated() {
            let end = position + 1 < headers.count ? headers[position + 1].0 : lines.count
            guard header.1.first == "mcp_servers" else { continue }
            if header.1.count == 1 {
                if lines[(header.0 + 1)..<end].contains(where: { !Self.withoutComment($0).trimmingCharacters(in: .whitespaces).isEmpty }) {
                    throw AgentLibraryError.unsupportedTOML
                }
                continue
            }
            let name = header.1[1]
            let range = header.0..<end
            let assignments = try Self.assignments(lines, in: (header.0 + 1)..<end)
            if tables.contains(where: { $0.path == header.1 }) { throw AgentLibraryError.ambiguousDefinition }
            tables.append(.init(path: header.1, range: range, assignments: assignments))
            var fields = entries[name] ?? [:]
            if header.1.count == 2 {
                for (key, assignment) in assignments {
                    guard fields[key] == nil else { throw AgentLibraryError.ambiguousDefinition }
                    fields[key] = assignment.value
                }
            } else {
                let key = header.1.dropFirst(2).joined(separator: ".")
                guard fields[key] == nil else { throw AgentLibraryError.ambiguousDefinition }
                fields[key] = .object(assignments.mapValues(\.value))
            }
            entries[name] = fields
        }
        self.lines = lines; self.tables = tables; self.entries = entries
    }

    func replacing(_ name: String, fields: [String: AgentLibraryValue]?) throws -> Data {
        let selected = tables.filter { $0.path[1] == name }
        if selected.isEmpty {
            guard let fields else { throw AgentLibraryError.notFound }
            var result = lines.joined(separator: "\n")
            if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
            result += "\n[mcp_servers." + Self.quote(name) + "]\n"
            for key in fields.keys.sorted() {
                result += Self.quote(key) + " = " + (try Self.encode(fields[key]!)) + "\n"
            }
            return Data(result.utf8)
        }
        var replacements: [(Range<Int>, [String])] = []
        let nested = Set(selected.filter { $0.path.count > 2 }.map { $0.path.dropFirst(2).joined(separator: ".") })
        for table in selected {
            guard let fields else { replacements.append((table.range, [])); continue }
            let desired: [String: AgentLibraryValue]
            if table.path.count == 2 { desired = fields.filter { !nested.contains($0.key) } }
            else {
                let key = table.path.dropFirst(2).joined(separator: ".")
                guard let value = fields[key] else { replacements.append((table.range, [])); continue }
                guard let object = value.object else { throw AgentLibraryError.unsupportedTOML }
                desired = object
            }
            var edits: [(Range<Int>, [String])] = []
            for (key, assignment) in table.assignments {
                if let value = desired[key] {
                    if value != assignment.value {
                        if case .opaqueTOML = value { throw AgentLibraryError.unsupportedTOML }
                        if case .opaqueTOML = assignment.value { throw AgentLibraryError.unsupportedTOML }
                        edits.append((assignment.range, [Self.quote(key) + " = " + (try Self.encode(value)) + assignment.comment]))
                    }
                } else { edits.append((assignment.range, [])) }
            }
            let newKeys = desired.keys.filter { table.assignments[$0] == nil }.sorted()
            if !newKeys.isEmpty {
                let added = try newKeys.map { Self.quote($0) + " = " + (try Self.encode(desired[$0]!)) }
                edits.append((table.range.upperBound..<table.range.upperBound, added))
            }
            var body = Array(lines[table.range])
            for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
                body.replaceSubrange((range.lowerBound - table.range.lowerBound)..<(range.upperBound - table.range.lowerBound), with: replacement)
            }
            replacements.append((table.range, body))
        }
        // A nested-only table can still acquire root fields without moving
        // or discarding its existing nested content.
        if let fields, !selected.contains(where: { $0.path.count == 2 }) {
            let root = fields.filter { !nested.contains($0.key) }
            let added = ["[mcp_servers." + Self.quote(name) + "]"] +
                (try root.keys.sorted().map { Self.quote($0) + " = " + (try Self.encode(root[$0]!)) })
            replacements.append((lines.count..<lines.count, added))
        }
        var result = lines
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        return Data(result.joined(separator: "\n").utf8)
    }

    static func assignments(_ lines: [String], in range: Range<Int>) throws -> [String: Assignment] {
        var result: [String: Assignment] = [:]
        var index = range.lowerBound
        while index < range.upperBound {
            let line = lines[index]
            let content = withoutComment(line).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { index += 1; continue }
            guard let eq = separator("=", in: content).first else { throw AgentLibraryError.unsupportedTOML }
            let keyParts = try keys(String(content[..<eq]))
            guard keyParts.count == 1 else { throw AgentLibraryError.unsupportedTOML }
            let key = keyParts[0]
            guard result[key] == nil else { throw AgentLibraryError.ambiguousDefinition }
            var expression = String(content[content.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let start = index
            while !balanced(expression) && index + 1 < range.upperBound {
                index += 1
                expression += "\n" + withoutComment(lines[index])
            }
            guard balanced(expression) else { throw AgentLibraryError.unsupportedTOML }
            let value = parse(expression) ?? .opaqueTOML(expression)
            let comment = line.dropFirst(withoutComment(line).count)
            result[key] = .init(key: key, value: value, range: start..<(index + 1),
                                comment: comment.isEmpty ? "" : " " + comment)
            index += 1
        }
        return result
    }
    static func keys(_ value: String) throws -> [String] {
        let pieces = split(value.trimmingCharacters(in: .whitespaces), separator: ".")
        let keys = try pieces.map { piece -> String in
            let p = piece.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("\"") || p.hasPrefix("'") {
                guard let string = parse(p)?.string else { throw AgentLibraryError.unsupportedTOML }
                return string
            }
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw AgentLibraryError.unsupportedTOML
            }
            return p
        }
        return keys
    }
    static func parse(_ value: String) -> AgentLibraryValue? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), !value.hasPrefix("\"\"\""),
           let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { return .string(decoded) }
        if value.hasPrefix("'"), value.hasSuffix("'"), !value.hasPrefix("'''") { return .string(String(value.dropFirst().dropLast())) }
        if value == "true" { return .bool(true) }; if value == "false" { return .bool(false) }
        let numeric = value.replacingOccurrences(of: "_", with: "")
        if let number = Int64(numeric) { return .integer(number) }
        if let number = UInt64(numeric) { return .unsignedInteger(number) }
        if let number = Double(numeric), number.isFinite { return .number(number) }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let pieces = split(String(value.dropFirst().dropLast()), separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let values = pieces.compactMap(parse)
            return values.count == pieces.count ? .array(values) : nil
        }
        if value.hasPrefix("{"), value.hasSuffix("}") {
            let pieces = split(String(value.dropFirst().dropLast()), separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var object: [String: AgentLibraryValue] = [:]
            for piece in pieces {
                guard let eq = separator("=", in: piece).first,
                      let keys = try? keys(String(piece[..<eq])), keys.count == 1,
                      object[keys[0]] == nil, let v = parse(String(piece[piece.index(after: eq)...])) else { return nil }
                object[keys[0]] = v
            }
            return .object(object)
        }
        return nil
    }
    static func encode(_ value: AgentLibraryValue) throws -> String {
        switch value {
        case .string(let value): return quote(value)
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .number(let value): guard value.isFinite else { throw AgentLibraryError.invalidDefinition }; return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let values): return "[" + (try values.map(encode)).joined(separator: ", ") + "]"
        case .object(let values): return "{" + (try values.keys.sorted().map { quote($0) + " = " + (try encode(values[$0]!)) }).joined(separator: ", ") + "}"
        case .null, .opaqueTOML: throw AgentLibraryError.unsupportedTOML
        }
    }
    static func quote(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
    static func withoutComment(_ value: String) -> String {
        guard let index = separator("#", in: value).first else { return value }
        return String(value[..<index])
    }
    static func balanced(_ value: String) -> Bool {
        var quote: Character?
        var escaped = false
        var depth = 0
        for c in value {
            if let q = quote {
                if c == q && !escaped { quote = nil }
                if q == "\"" { escaped = c == "\\" && !escaped }
            } else if c == "\"" || c == "'" { quote = c; escaped = false }
            else if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
        }
        return quote == nil && depth == 0
    }
    static func separator(_ delimiter: Character, in value: String) -> [String.Index] {
        var result: [String.Index] = []
        var quote: Character?
        var escaped = false
        var depth = 0
        for index in value.indices {
            let c = value[index]
            if let q = quote {
                if c == q && !escaped { quote = nil }
                if q == "\"" { escaped = c == "\\" && !escaped }
            } else if c == "\"" || c == "'" { quote = c; escaped = false }
            else if c == delimiter && (delimiter == "#" || depth == 0) { result.append(index) }
            else if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
        }
        return result
    }
    static func split(_ value: String, separator delimiter: Character) -> [String] {
        var start = value.startIndex
        var parts: [String] = []
        for index in separator(delimiter, in: value) {
            parts.append(String(value[start..<index])); start = value.index(after: index)
        }
        parts.append(String(value[start...]))
        return parts
    }
    static func markerCount(_ marker: String, in value: String) -> Int {
        var count = 0
        var cursor = value.startIndex
        while let range = value.range(of: marker, range: cursor..<value.endIndex) {
            var slashes = 0
            var index = range.lowerBound
            while index > value.startIndex {
                index = value.index(before: index)
                guard value[index] == "\\" else { break }
                slashes += 1
            }
            if marker == "'''" || slashes % 2 == 0 { count += 1 }
            cursor = range.upperBound
        }
        return count
    }
}
