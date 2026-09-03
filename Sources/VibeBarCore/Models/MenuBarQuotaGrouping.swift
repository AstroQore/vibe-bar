import Foundation

/// One rendered menu-bar entry: a single quota field, or a run of adjacent
/// fields that share an L3 quota group and draw as one piece — `Claude
/// 5%/100%` instead of `5 Hours 5% · Weekly 100%`.
///
/// A run never reorders anything: `fields` is a contiguous slice of the
/// user's `selectedFieldIds`, so the arrangement they built in Settings is
/// the arrangement they see.
public struct MenuBarFieldRun: Equatable, Sendable {
    /// The L3 quota-group key every member shares. `nil` for a field that
    /// sits directly under its SubProvider (Grok Bot's single Weekly) and for
    /// every run built with merging turned off — such a run never merges, so
    /// the key would be dead weight on the render path.
    public let groupKey: String?
    /// Members in selection order; never empty.
    public private(set) var fields: [MenuBarFieldOption]

    public init(groupKey: String?, fields: [MenuBarFieldOption]) {
        self.groupKey = groupKey
        self.fields = fields
    }

    public var isMerged: Bool { fields.count > 1 }

    /// The member whose style, tool, and (absent a custom label) naming the
    /// merged piece wears.
    public var primary: MenuBarFieldOption { fields[0] }

    fileprivate mutating func append(_ field: MenuBarFieldOption) {
        fields.append(field)
    }
}

public extension MenuBarFieldCatalog {
    /// Whether a field renders as an L3 *branch* — a named model group under
    /// its SubProvider (Codex Spark, Claude Fable, AntiGravity's two pools) —
    /// rather than as one of the SubProvider's own headline windows.
    ///
    /// Lives in Core because three surfaces need the same grouped/flat answer
    /// without a live bucket in hand: the mini window's layouts, the Settings
    /// naming tree, and the menu bar's group merge.
    static func isBranchStyleField(_ field: MenuBarFieldOption) -> Bool {
        // Antigravity rows are branch-style because its four quota
        // lanes are split across the Gemini and Claude/GPT groups.
        // Gemini USED to be in this carve-out too — that
        // was a leftover from the per-model CLI adapter. After
        // PR #57 the Gemini Web parser emits two flat primary
        // buckets (`five_hour` / `weekly`) with `groupTitle == nil`,
        // so they need to flow through the primary cell path or
        // they never reach the mini window at all.
        if field.tool == .antigravity {
            return true
        }
        // A discovered field is branch-style exactly when its bucket carried
        // an L3 group title when it was recorded.
        if field.isDynamic {
            return field.dynamicGroupTitle != nil
        }
        switch field.bucketId {
        case "gpt_5_3_codex_spark_five_hour",
             "gpt_5_3_codex_spark_weekly",
             "weekly_sonnet",
             "weekly_design",
             "daily_routines",
             "weekly_opus",
             "weekly_fable",
             "weekly_oauth_apps":
            return true
        default:
            return false
        }
    }

    /// Stable key for the L3 quota group a *branch* bucket belongs to.
    /// Both windows of one group ("…_five_hour" / "…_weekly") answer with the
    /// same key, which is what makes them a renamable unit in the mini window
    /// and a mergeable unit in the menu bar.
    static func quotaGroupKey(tool: ToolType, bucketId: String) -> String {
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
        return "\(tool.rawValue).\(bucketGroupStem(bucketId))"
    }

    /// The L3 group a field belongs to on the quota axis, or nil for a bucket
    /// that sits directly under its SubProvider (Grok Bot's single Weekly).
    /// Shared by the settings tree, every mini layout, and the menu bar's
    /// group merge, so a bucket is grouped identically wherever it appears.
    ///
    /// The SubProvider's own headline windows (5 Hours + Weekly) answer with
    /// the `<tool>.all-models` catch-all, which is why merging them yields one
    /// `Claude 5%/100%` piece rather than two.
    static func namingGroupKey(for option: MenuBarFieldOption) -> String? {
        if option.tool == .cursor {
            if option.bucketId == "grok_bot_weekly" { return nil }
            return quotaGroupKey(tool: .cursor, bucketId: option.bucketId)
        }
        if isBranchStyleField(option) {
            return quotaGroupKey(tool: option.tool, bucketId: option.bucketId)
        }
        switch option.tool {
        case .codex: return "codex.all-models"
        case .claude: return "claude.all-models"
        case .gemini: return "gemini.all-models"
        case .grok: return "grok.all-models"
        default: return nil
        }
    }

    /// The catch-all group key under `tool`'s SubProvider — the lane the mini
    /// window labels "All" because a SubProvider header sits above it. The
    /// menu bar has no such header, so a merged run on this key names the
    /// SubProvider instead.
    static func allModelsGroupKey(for tool: ToolType) -> String {
        "\(tool.rawValue).all-models"
    }

    /// Collapse the selected fields into rendered entries.
    ///
    /// One forward pass, no per-bucket dictionaries: this runs inside the
    /// menu bar's 120 ms render throttle on the main thread. With `merging`
    /// off every field becomes its own run and no group key is computed at
    /// all, so the setting costs nothing while it is off.
    static func runs(_ fields: [MenuBarFieldOption], merging: Bool) -> [MenuBarFieldRun] {
        guard merging else {
            return fields.map { MenuBarFieldRun(groupKey: nil, fields: [$0]) }
        }
        var runs: [MenuBarFieldRun] = []
        runs.reserveCapacity(fields.count)
        for field in fields {
            let key = namingGroupKey(for: field)
            if let key, let last = runs.last, last.groupKey == key {
                runs[runs.count - 1].append(field)
            } else {
                runs.append(MenuBarFieldRun(groupKey: key, fields: [field]))
            }
        }
        return runs
    }

    /// The one short name a merged run wears. A merged piece names the
    /// *group*, never one of its windows: "Claude 5%/100%", not
    /// "5 Hours 5%/100%".
    ///
    /// `groupCatalogLabel` is the mini window's group-label table, injected so
    /// Core stays free of the App layer while the two surfaces still answer
    /// with the same words.
    static func mergedGroupLabel(
        for run: MenuBarFieldRun,
        customLabels: [String: String],
        groupCatalogLabel: (String) -> String?
    ) -> String {
        // The user renamed a member for the menu bar; the earliest such name
        // wins, so the piece is called whatever the leftmost window is called.
        for field in run.fields {
            if let custom = trimmedNonEmpty(customLabels[field.id]) { return custom }
        }
        let primary = run.primary
        let subProvider = primary.tool.quotaSubProviderName(bucketID: primary.bucketId)
        guard let key = run.groupKey else { return subProvider }
        if key == allModelsGroupKey(for: primary.tool) { return subProvider }
        if let catalog = trimmedNonEmpty(groupCatalogLabel(key)) { return catalog }
        if let dynamic = trimmedNonEmpty(primary.dynamicGroupTitle) { return dynamic }
        return subProvider
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
