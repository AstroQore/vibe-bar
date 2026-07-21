import Foundation

struct MiniWindowGroupLabelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let defaultLabel: String
}

enum MiniWindowGroupLabelCatalog {
    static let all: [MiniWindowGroupLabelOption] = [
        .init(id: "codex.all-models", title: "CHATGPT · All Models", defaultLabel: "All Models"),
        .init(id: "codex.spark", title: "CODEX · Spark", defaultLabel: "Spark"),
        .init(id: "claude.all-models", title: "CLAUDE · All Models", defaultLabel: "All Models"),
        .init(id: "claude.sonnet", title: "CLAUDE · Sonnet", defaultLabel: "Sonnet"),
        .init(id: "claude.design", title: "CLAUDE · Design", defaultLabel: "Design"),
        .init(id: "claude.routine", title: "CLAUDE · Routine", defaultLabel: "Routine"),
        .init(id: "claude.opus", title: "CLAUDE · Opus", defaultLabel: "Opus"),
        .init(id: "claude.fable", title: "CLAUDE · Fable", defaultLabel: "Fable"),
        .init(id: "claude.oauth", title: "CLAUDE · OAuth", defaultLabel: "OAuth"),
        .init(id: "gemini.chat", title: "GEMINI · Gemini Chat", defaultLabel: "Gemini Chat"),
        .init(id: "gemini.pro", title: "GEMINI · Pro", defaultLabel: "Pro"),
        .init(id: "gemini.flash", title: "GEMINI · Flash", defaultLabel: "Flash"),
        .init(id: "gemini.flash-lite", title: "GEMINI · Flash Lite", defaultLabel: "Lite"),
        .init(id: "antigravity.gemini-models", title: "ANTIGRAVITY · Gemini Models", defaultLabel: "Gemini"),
        .init(id: "antigravity.claude-gpt-models", title: "ANTIGRAVITY · Claude + GPT Models", defaultLabel: "C+G"),
        .init(id: "grok.all-models", title: "GROK · All Models", defaultLabel: "All Models")
    ]

    static func defaultLabel(for id: String) -> String? {
        all.first { $0.id == id }?.defaultLabel
    }
}
