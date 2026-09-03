import Foundation
import VibeBarCore

struct MiniWindowGroupLabelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let defaultLabel: String
}

enum MiniWindowGroupLabelCatalog {
    static let all: [MiniWindowGroupLabelOption] = [
        .init(id: "codex.all-models", title: "CHATGPT · All Models", defaultLabel: "All"),
        .init(id: "codex.spark", title: "CODEX · Spark", defaultLabel: "Spark"),
        .init(id: "claude.all-models", title: "CLAUDE · All Models", defaultLabel: "All"),
        .init(id: "claude.sonnet", title: "CLAUDE · Sonnet", defaultLabel: "Sonnet"),
        .init(id: "claude.design", title: "CLAUDE · Design", defaultLabel: "Design"),
        .init(id: "claude.routine", title: "CLAUDE · Routine", defaultLabel: "Routine"),
        .init(id: "claude.opus", title: "CLAUDE · Opus", defaultLabel: "Opus"),
        .init(id: "claude.fable", title: "CLAUDE · Fable", defaultLabel: "Fable"),
        .init(id: "claude.oauth", title: "CLAUDE · OAuth", defaultLabel: "OAuth"),
        .init(id: "gemini.all-models", title: "GEMINI WEB · All Models", defaultLabel: "All"),
        .init(id: "gemini.pro", title: "GEMINI · Pro", defaultLabel: "Pro"),
        .init(id: "gemini.flash", title: "GEMINI · Flash", defaultLabel: "Flash"),
        .init(id: "gemini.flash-lite", title: "GEMINI · Flash Lite", defaultLabel: "Flash Lite"),
        .init(id: "antigravity.gemini-models", title: "ANTIGRAVITY · Gemini Models", defaultLabel: "Gemini"),
        .init(id: "antigravity.claude-gpt-models", title: "ANTIGRAVITY · Claude + GPT Models", defaultLabel: "Claude + GPT"),
        // Stable persisted key (custom labels are stored under it); the
        // wording is the L3 group name from AGENTS.md § 7.1.
        .init(id: "grok.all-models", title: "GROK · Weekly Credits", defaultLabel: "All"),
        .init(id: "cursor.models", title: "CURSOR · Cursor Models", defaultLabel: "Cursor"),
        .init(id: "cursor.other-models", title: "CURSOR · Other Models", defaultLabel: "Other")
    ]

    static func defaultLabel(for id: String) -> String? {
        all.first { $0.id == id }?.defaultLabel
    }

    /// The L3 group a field belongs to on the quota axis, or nil for a bucket
    /// that sits directly under its SubProvider (Grok Bot's single Weekly).
    /// Shared by the settings tree, every mini layout, and the menu bar's
    /// group merge, so a bucket is grouped identically wherever it appears —
    /// the rules themselves live in `VibeBarCore` because the menu bar's merge
    /// has to be testable without AppKit.
    static func namingGroupKey(for option: MenuBarFieldOption) -> String? {
        MenuBarFieldCatalog.namingGroupKey(for: option)
    }

    static func groupKey(tool: ToolType, bucketId: String) -> String {
        MenuBarFieldCatalog.quotaGroupKey(tool: tool, bucketId: bucketId)
    }

    static func subProviderKey(tool: ToolType, name: String) -> String {
        "subprovider:\(tool.rawValue)/\(name)"
    }

    static var subProviderOptions: [MiniWindowGroupLabelOption] {
        MenuBarFieldCatalog.subProviderGroups(
            for: ToolType.dedicatedCardProviders,
            selectedFieldIds: Set(MenuBarFieldCatalog.allFields.map(\.id))
        ).flatMap { company in
            company.subProviders.map { subProvider in
                MiniWindowGroupLabelOption(
                    id: subProviderKey(tool: subProvider.tool, name: subProvider.name),
                    title: "\(company.company.uppercased()) · \(subProvider.name)",
                    defaultLabel: subProvider.name
                )
            }
        }
    }

    static func options(liveQuotas: [ToolType: AccountQuota]) -> [MiniWindowGroupLabelOption] {
        var result = all
        var ids = Set(result.map(\.id))
        for tool in ToolType.dedicatedCardProviders {
            for bucket in liveQuotas[tool]?.buckets ?? [] {
                guard let rawGroup = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawGroup.isEmpty,
                      rawGroup.caseInsensitiveCompare(tool.quotaSubProviderName(bucketID: bucket.id)) != .orderedSame
                else { continue }
                let id = groupKey(tool: tool, bucketId: bucket.id)
                guard ids.insert(id).inserted else { continue }
                result.append(MiniWindowGroupLabelOption(
                    id: id,
                    title: "\(tool.quotaSubProviderName(bucketID: bucket.id).uppercased()) · \(rawGroup)",
                    defaultLabel: rawGroup
                ))
            }
        }
        return result
    }
}
