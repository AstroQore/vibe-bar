import Foundation

/// Type-to-filter matching for a picker: every word the user typed has to
/// appear somewhere in the entry's keys.
///
/// Case- and diacritic-insensitive, and tokenized rather than matched as one
/// phrase, so "claude code" and "code claude" both find Claude Code, and
/// "anthropic" finds it through the company name in its keys. An empty
/// query matches everything — a picker with nothing typed shows every row.
public enum FilterQuery {
    public static func matches(_ keys: [String], query: String) -> Bool {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = keys.joined(separator: " ")
        return words.allSatisfy { word in
            haystack.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
