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
        // The id is a persisted `groupLabels` key — renaming it would orphan
        // every custom label. The *label* is what changed: "Gemini Chat" was
        // an L2-flavoured name sitting in the L3 slot, and now that the mini
        // window prints "GEMINI WEB" as its own SubProvider row, the group
        // below it has to name a quota group like every other provider's does.
        .init(id: "gemini.chat", title: "GEMINI WEB · All Models", defaultLabel: "All Models"),
        .init(id: "gemini.pro", title: "GEMINI · Pro", defaultLabel: "Pro"),
        .init(id: "gemini.flash", title: "GEMINI · Flash", defaultLabel: "Flash"),
        .init(id: "gemini.flash-lite", title: "GEMINI · Flash Lite", defaultLabel: "Lite"),
        .init(id: "antigravity.gemini-models", title: "ANTIGRAVITY · Gemini Models", defaultLabel: "Gemini"),
        .init(id: "antigravity.claude-gpt-models", title: "ANTIGRAVITY · Claude + GPT Models", defaultLabel: "C+G"),
        .init(id: "grok.all-models", title: "GROK · All Models", defaultLabel: "All Models"),
        .init(id: "cursor.models", title: "CURSOR · Cursor Models", defaultLabel: "Cursor Models"),
        .init(id: "cursor.other-models", title: "CURSOR · Other Models", defaultLabel: "Other Models"),
        .init(id: "cursor.grok-bot", title: "CURSOR · Grok Bot", defaultLabel: "Grok Bot")
    ]

    static func defaultLabel(for id: String) -> String? {
        all.first { $0.id == id }?.defaultLabel
    }
}
