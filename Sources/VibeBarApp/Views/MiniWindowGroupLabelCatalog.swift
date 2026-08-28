import Foundation
import VibeBarCore

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
        .init(id: "gemini.all-models", title: "GEMINI WEB · All Models", defaultLabel: "All Models"),
        .init(id: "gemini.pro", title: "GEMINI · Pro", defaultLabel: "Pro"),
        .init(id: "gemini.flash", title: "GEMINI · Flash", defaultLabel: "Flash"),
        .init(id: "gemini.flash-lite", title: "GEMINI · Flash Lite", defaultLabel: "Lite"),
        .init(id: "antigravity.gemini-models", title: "ANTIGRAVITY · Gemini Models", defaultLabel: "Gemini"),
        .init(id: "antigravity.claude-gpt-models", title: "ANTIGRAVITY · Claude + GPT Models", defaultLabel: "C+G"),
        // Stable persisted key (custom labels are stored under it); the
        // wording is the L3 group name from AGENTS.md § 7.1.
        .init(id: "grok.all-models", title: "GROK · Weekly Credits", defaultLabel: "Weekly Credits"),
        .init(id: "cursor.models", title: "CURSOR · Cursor Models", defaultLabel: "Cursor Models"),
        .init(id: "cursor.other-models", title: "CURSOR · Other Models", defaultLabel: "Other Models")
    ]

    static func defaultLabel(for id: String) -> String? {
        all.first { $0.id == id }?.defaultLabel
    }

    static func groupKey(tool: ToolType, bucketId: String) -> String {
        switch bucketId {
        case "gpt_5_3_codex_spark_five_hour", "gpt_5_3_codex_spark_weekly": return "codex.spark"
        case "weekly_sonnet": return "claude.sonnet"
        case "weekly_design": return "claude.design"
        case "daily_routines": return "claude.routine"
        case "weekly_opus": return "claude.opus"
        case "weekly_fable": return "claude.fable"
        case "weekly_oauth_apps": return "claude.oauth"
        case "models" where tool == .cursor: return "cursor.models"
        case "other_models" where tool == .cursor: return "cursor.other-models"
        default: break
        }
        let id = bucketId.lowercased()
        if tool == .gemini {
            if id.contains("flash-lite") { return "gemini.flash-lite" }
            if id.contains("flash") { return "gemini.flash" }
            if id.contains("pro") { return "gemini.pro" }
        }
        if tool == .antigravity {
            if ["gemini_five_hour", "gemini_weekly"].contains(id) {
                return "antigravity.gemini-models"
            }
            if ["claude_gpt_five_hour", "claude_gpt_weekly"].contains(id) {
                return "antigravity.claude-gpt-models"
            }
            if id.contains("gpt-oss") { return "antigravity.gpt-oss" }
            if id.contains("claude") { return "antigravity.claude" }
            if id.contains("flash-lite") { return "antigravity.gemini-flash-lite" }
            if id.contains("flash") { return "antigravity.gemini-flash" }
            if id.contains("pro") { return "antigravity.gemini-pro" }
        }
        // Discovered buckets: both windows of one runtime quota group
        // ("gpt_reserve_five_hour" / "gpt_reserve_weekly") share one label
        // key, so the group renders — and is renamed — as one unit.
        return "\(tool.rawValue).\(MenuBarFieldCatalog.bucketGroupStem(bucketId))"
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
