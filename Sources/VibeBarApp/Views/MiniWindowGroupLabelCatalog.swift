import Foundation

struct MiniWindowGroupLabelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let defaultLabel: String
}

enum MiniWindowGroupLabelCatalog {
    static let all: [MiniWindowGroupLabelOption] = [
        .init(id: "codex.spark", title: "CODEX · Spark", defaultLabel: "Spark"),
        .init(id: "claude.sonnet", title: "CLAUDE · Sonnet", defaultLabel: "Sonnet"),
        .init(id: "claude.design", title: "CLAUDE · Design", defaultLabel: "Design"),
        .init(id: "claude.routine", title: "CLAUDE · Routine", defaultLabel: "Routine"),
        .init(id: "claude.opus", title: "CLAUDE · Opus", defaultLabel: "Opus"),
        .init(id: "claude.fable", title: "CLAUDE · Fable", defaultLabel: "Fable"),
        .init(id: "claude.oauth", title: "CLAUDE · OAuth", defaultLabel: "OAuth"),
        .init(id: "gemini.pro", title: "GEMINI · Pro", defaultLabel: "Pro"),
        .init(id: "gemini.flash", title: "GEMINI · Flash", defaultLabel: "Flash"),
        .init(id: "gemini.flash-lite", title: "GEMINI · Flash Lite", defaultLabel: "Lite"),
        .init(id: "antigravity.gemini-models", title: "ANTIGRAVITY · Gemini Models", defaultLabel: "Gemini"),
        .init(id: "antigravity.claude-gpt-models", title: "ANTIGRAVITY · Claude + GPT Models", defaultLabel: "C+G")
    ]

    static func defaultLabel(for id: String) -> String? {
        all.first { $0.id == id }?.defaultLabel
    }
}
