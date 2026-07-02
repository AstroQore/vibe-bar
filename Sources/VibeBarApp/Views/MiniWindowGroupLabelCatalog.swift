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
        .init(id: "antigravity.claude", title: "ANTIGRAVITY · Claude", defaultLabel: "Claude"),
        .init(id: "antigravity.gemini-pro", title: "ANTIGRAVITY · Gemini Pro", defaultLabel: "G Pro"),
        .init(id: "antigravity.gemini-flash", title: "ANTIGRAVITY · Gemini Flash", defaultLabel: "G Flash"),
        .init(id: "antigravity.gemini-flash-lite", title: "ANTIGRAVITY · Gemini Flash Lite", defaultLabel: "G Lite")
    ]

    static func defaultLabel(for id: String) -> String? {
        all.first { $0.id == id }?.defaultLabel
    }
}
