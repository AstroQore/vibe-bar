import SwiftUI
import VibeBarCore

struct MiniQuotaWindowView: View {
    let onClose: () -> Void
    let onToggleDisplayMode: () -> Void

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    /// Observe the QuotaService directly so the mini window re-renders the
    /// instant a quota refresh lands. Without this the view only redraws on
    /// a settings change or the inner TimelineView's 30 s tick, which made
    /// timer- or button-driven refreshes feel laggy compared to the popover.
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let contentByTool = miniContentByTool
        // Mini window only surfaces dedicated-card providers — misc
        // cards live on the Misc tab inside the Overview popover, not
        // in this floating panel.
        let visibleTools = ToolType.dedicatedCardProviders.filter { tool in
            contentByTool[tool]?.isEmpty == false
        }
        let displayMode = settingsStore.settings.miniWindow.displayMode

        ZStack(alignment: .topTrailing) {
            MiniWindowProviderLayout(
                displayMode: displayMode,
                visibleTools: visibleTools,
                contentByTool: contentByTool,
                selectedFieldIds: miniSelectedFieldIds
            )
            .padding(.horizontal, displayMode == .compact ? 8 : 14)
            .padding(.top, displayMode == .compact ? 16 : 22)
            .padding(.bottom, displayMode == .compact ? 9 : 14)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggleDisplayMode)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
        .frame(
            minWidth: displayMode == .compact ? 156 : 240,
            // Three tiers now: company header, SubProvider label, quota
            // groups. `MiniQuotaWindowController.stableContentSize` reserves
            // the same extra label row — keep the two in step.
            minHeight: displayMode == .compact ? 146 : 181,
            alignment: .center
        )
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: Theme.miniCornerRadius)
        )
        // The panel is borderless and non-activating, so it never becomes
        // key — but the close button would still draw a system focus ring
        // after a click without this.
        .vibeBarControlFocus()
    }

    /// The field ids selected for the current display mode. Also the input to
    /// `MenuBarFieldCatalog.subProviderGroups`, which decides the company →
    /// SubProvider skeleton the layout renders into.
    private var miniSelectedFieldIds: Set<String> {
        let mini = settingsStore.settings.miniWindow
        return Set(mini.fieldIds(for: mini.displayMode))
    }

    private var miniContentByTool: [ToolType: MiniToolContent] {
        let mini = settingsStore.settings.miniWindow
        let selected = mini.fieldIds(for: mini.displayMode)
        let selectedFieldIds = Set(selected)
        var contentByTool: [ToolType: MiniToolContent] = [:]
        for tool in ToolType.dedicatedCardProviders {
            var cells: [MiniCell] = []
            for fieldId in selected {
                guard
                    let field = MenuBarFieldCatalog.field(id: fieldId),
                    field.tool == tool
                else { continue }
                guard let liveBucket = environment.quota(for: tool)?.bucket(id: field.bucketId) else {
                    continue
                }
                if Self.hasQuotaGroup(liveBucket, tool: tool, bucketId: field.bucketId)
                    || isBranchField(field) {
                    continue
                }
                cells.append(
                    MiniCell(
                        tool: tool,
                        field: field,
                        bucket: liveBucket,
                        customLabel: settingsStore.settings.miniWindow.customLabels[field.id]
                    )
                )
            }
            let selectedBucketIds = Set(cells.map { $0.field.bucketId })
            let branchCells = branchCells(
                for: tool,
                selectedFieldIds: selectedFieldIds,
                excluding: selectedBucketIds
            )
            let content = MiniToolContent(primaryCells: cells, branchCells: branchCells)
            if !content.isEmpty { contentByTool[tool] = content }
        }
        return contentByTool
    }

    /// A live `groupTitle` marks an L3 quota group — unless it merely repeats
    /// the bucket's own SubProvider name (Cursor's `grok_bot_weekly` carries
    /// "Grok Bot"), in which case the SubProvider row already says it and the
    /// bucket is a flat primary cell: SpaceXAI → Grok Bot → Weekly, not
    /// SpaceXAI → Grok Bot → Grok Bot → Weekly.
    static func hasQuotaGroup(_ bucket: QuotaBucket?, tool: ToolType, bucketId: String) -> Bool {
        guard let group = bucket?.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !group.isEmpty
        else { return false }
        return group.caseInsensitiveCompare(tool.quotaSubProviderName(bucketID: bucketId)) != .orderedSame
    }

    private func isBranchField(_ field: MenuBarFieldOption) -> Bool {
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

    private func branchCells(
        for tool: ToolType,
        selectedFieldIds: Set<String>,
        excluding selectedBucketIds: Set<String>
    ) -> [MiniBranchCell] {
        guard let quota = environment.quota(for: tool) else { return [] }
        return quota.buckets.compactMap { bucket in
            let fieldId = MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucket.id)
            guard
                selectedFieldIds.contains(fieldId),
                let field = MenuBarFieldCatalog.field(id: fieldId),
                !selectedBucketIds.contains(bucket.id),
                Self.hasQuotaGroup(bucket, tool: tool, bucketId: bucket.id)
            else { return nil }
            return MiniBranchCell(
                tool: tool,
                field: field,
                bucket: bucket,
                customLabel: settingsStore.settings.miniWindow.customLabels[field.id]
            )
        }
    }
}

/// One L2 SubProvider inside a company column — its name, the tool whose
/// adapter produced the buckets, and the primary + branch cells that belong to
/// it. This is the middle tier of the mini window's company → SubProvider →
/// quota-group layout, and it is **not** one per `ToolType`: Cursor's adapter
/// yields both "Cursor" and "Grok Bot" (see `ToolType.quotaSubProviderName`).
private struct MiniL2Member: Identifiable {
    let tool: ToolType
    let subProviderName: String
    let content: MiniToolContent

    var id: String { "\(tool.rawValue)/\(subProviderName)" }
}

/// Tools sharing the same L1 enterprise/brand (e.g. Gemini Web + AntiGravity)
/// collapse into one super-column with a single company header and one
/// labelled section per SubProvider. The mini window renders one super-column
/// per `MiniCompanyGroup`, not one per `ToolType`.
private struct MiniCompanyGroup: Identifiable {
    let companyName: String
    let accentTool: ToolType
    let members: [MiniL2Member]

    var id: String { companyName }
    var isMultiSubProvider: Bool { members.count > 1 }
}

/// Fills `MenuBarFieldCatalog.subProviderGroups`' company → SubProvider
/// skeleton with the live cells built above. The skeleton owns the ordering
/// (catalog order inside a tool, `visibleTools` order across tools, companies
/// folded by `vendorName`); this only attaches content and drops whatever the
/// live quota had nothing for.
private func miniProductGroups(
    visibleTools: [ToolType],
    contentByTool: [ToolType: MiniToolContent],
    selectedFieldIds: Set<String>
) -> [MiniCompanyGroup] {
    let skeleton = MenuBarFieldCatalog.subProviderGroups(
        for: visibleTools,
        selectedFieldIds: selectedFieldIds
    )
    var groups: [MiniCompanyGroup] = []
    for company in skeleton {
        var members: [MiniL2Member] = []
        for subProvider in company.subProviders {
            guard let content = contentByTool[subProvider.tool] else { continue }
            let member = MiniL2Member(
                tool: subProvider.tool,
                subProviderName: subProvider.name,
                content: MiniToolContent(
                    primaryCells: content.primaryCells.filter { $0.subProviderKey == subProvider.id },
                    branchCells: content.branchCells.filter { $0.subProviderKey == subProvider.id }
                )
            )
            if !member.content.isEmpty { members.append(member) }
        }
        guard !members.isEmpty else { continue }
        groups.append(
            MiniCompanyGroup(
                companyName: company.company,
                accentTool: company.accentTool,
                members: members
            )
        )
    }
    return groups
}

private struct MiniWindowProviderLayout: View {
    let displayMode: MiniWindowDisplayMode
    let visibleTools: [ToolType]
    let contentByTool: [ToolType: MiniToolContent]
    let selectedFieldIds: Set<String>

    var body: some View {
        let groups = miniProductGroups(
            visibleTools: visibleTools,
            contentByTool: contentByTool,
            selectedFieldIds: selectedFieldIds
        )
        HStack(alignment: .top, spacing: displayMode == .compact ? 8 : 14) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    MiniProviderDivider(height: displayMode == .compact ? 94 : 131)
                        .padding(.top, 2)
                }
                switch displayMode {
                case .regular:
                    MiniCompanyGroupColumn(group: group)
                case .compact:
                    MiniCompactL2GroupColumn(group: group)
                }
            }
        }
    }
}

private struct MiniToolContent {
    let primaryCells: [MiniCell]
    let branchCells: [MiniBranchCell]

    var isEmpty: Bool {
        primaryCells.isEmpty && branchCells.isEmpty
    }
}

private struct MiniCell: Identifiable {
    let tool: ToolType
    let field: MenuBarFieldOption
    let bucket: QuotaBucket?
    let customLabel: String?

    var id: String { "\(tool.rawValue).\(field.id)" }

    /// L2 SubProvider this bucket bills against. Almost always the tool's own
    /// product name — Grok Bot is the exception that makes this a per-bucket
    /// question rather than a per-tool one.
    var subProviderName: String { tool.quotaSubProviderName(bucketID: field.bucketId) }

    /// Matches `MenuBarSubProviderGroup.id`, so a cell can be routed into the
    /// SubProvider section the catalog says it belongs to.
    var subProviderKey: String { "\(tool.rawValue)/\(subProviderName)" }

    var resolvedLabel: String {
        if let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        // A bucket whose group title is just its SubProvider (Grok Bot) is
        // drawn flat under that SubProvider row, so its cell must name the
        // L3 window ("Weekly"), not repeat "Grok Bot" a third time.
        if let bucket,
           let group = bucket.groupTitle,
           group.caseInsensitiveCompare(subProviderName) == .orderedSame {
            return bucket.title
        }
        if let bucket, field.defaultLabel != bucket.shortLabel {
            return bucket.shortLabel
        }
        return field.defaultLabel
    }
}

private struct MiniBranchCell: Identifiable {
    let tool: ToolType
    let field: MenuBarFieldOption
    let bucket: QuotaBucket
    let customLabel: String?

    var id: String { "\(tool.rawValue).branch.\(bucket.id)" }

    /// See `MiniCell.subProviderName`. Cursor's `grok_bot_weekly` resolves to
    /// "Grok Bot" here, which is what splits it out of the Cursor section.
    var subProviderName: String { tool.quotaSubProviderName(bucketID: field.bucketId) }

    var subProviderKey: String { "\(tool.rawValue)/\(subProviderName)" }

    var title: String {
        if let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return defaultTitle
    }

    private var defaultTitle: String {
        switch bucket.id {
        case "gpt_5_3_codex_spark_five_hour": return "5 Hours"
        case "gpt_5_3_codex_spark_weekly": return "Weekly"
        case let id where tool == .antigravity && ["gemini_five_hour", "claude_gpt_five_hour"].contains(id):
            return "5 Hours"
        case let id where tool == .antigravity && ["gemini_weekly", "claude_gpt_weekly"].contains(id):
            return "Weekly"
        case "weekly_sonnet": return "Weekly"
        case "weekly_design": return "Weekly"
        case "daily_routines": return "Daily"
        case "weekly_opus": return "Weekly"
        case "weekly_fable": return "Weekly"
        case "weekly_oauth_apps": return "Weekly"
        case let id where tool == .cursor && ["models", "other_models"].contains(id):
            return "Monthly"
        case "grok_bot_weekly" where tool == .cursor:
            return "Weekly"
        case let id where tool == .antigravity && id.contains("gpt-oss"):
            return "GPT"
        case let id where tool == .antigravity && id.contains("sonnet"):
            return "Sonnet"
        case let id where tool == .antigravity && id.contains("opus"):
            return "Opus"
        case let id where tool == .antigravity && id.contains("high"):
            return "High"
        case let id where tool == .antigravity && id.contains("medium"):
            return "Med"
        case let id where tool == .antigravity && id.contains("low"):
            return "Low"
        default:
            let group = bucket.groupTitle ?? bucket.shortLabel
            return group
                .replacingOccurrences(of: "GPT-5.3 Codex Spark", with: "Spark")
                .replacingOccurrences(of: "Daily Routines", with: "Routine")
        }
    }

    var groupKey: String {
        MiniWindowGroupLabelCatalog.groupKey(tool: tool, bucketId: bucket.id)
    }

    var defaultGroupTitle: String {
        if let label = MiniWindowGroupLabelCatalog.defaultLabel(for: groupKey) {
            return label
        }
        switch bucket.id {
        case "gpt_5_3_codex_spark_five_hour", "gpt_5_3_codex_spark_weekly":
            return "Spark"
        case "weekly_sonnet":
            return "Sonnet"
        case "weekly_design":
            return "Design"
        case "daily_routines":
            return "Routine"
        case "weekly_opus":
            return "Opus"
        case "weekly_fable":
            return "Fable"
        case "weekly_oauth_apps":
            return "OAuth"
        case "models" where tool == .cursor:
            return "Cursor Models"
        case "other_models" where tool == .cursor:
            return "Other Models"
        case "grok_bot_weekly" where tool == .cursor:
            return "Grok Bot"
        case let id where tool == .antigravity && ["gemini_five_hour", "gemini_weekly"].contains(id):
            return "Gemini"
        case let id where tool == .antigravity && ["claude_gpt_five_hour", "claude_gpt_weekly"].contains(id):
            return "C+G"
        case let id where tool == .gemini && id.contains("flash-lite"):
            return "Lite"
        case let id where tool == .gemini && id.contains("flash"):
            return "Flash"
        case let id where tool == .gemini && id.contains("pro"):
            return "Pro"
        case let id where tool == .antigravity && id.contains("gpt-oss"):
            return "GPT-OSS"
        case let id where tool == .antigravity && id.contains("claude"):
            return "Claude"
        case let id where tool == .antigravity && id.contains("flash-lite"):
            return "G Lite"
        case let id where tool == .antigravity && id.contains("flash"):
            return "G Flash"
        case let id where tool == .antigravity && id.contains("gemini") && id.contains("pro"):
            return "G Pro"
        default:
            return (bucket.groupTitle ?? bucket.shortLabel)
                .replacingOccurrences(of: "GPT-5.3 Codex Spark", with: "Spark")
                .replacingOccurrences(of: "Daily Routines", with: "Routine")
        }
    }
}

/// Brand hue for a provider. The table itself lives in `Theme` so the charts
/// that colour-code providers share exactly these hues.
private func providerAccent(for tool: ToolType) -> Color {
    Theme.providerAccent(for: tool)
}

private func providerTitle(for tool: ToolType) -> String {
    switch tool {
    case .codex:       return "CODEX"
    case .claude:      return "CLAUDE"
    case .alibaba:     return "QWEN"
    case .alibabaTokenPlan: return "QWEN TP"
    case .gemini:      return "GEMINI"
    case .antigravity: return "ANTIGRAVITY"
    case .grok:        return "GROK"
    case .copilot:     return "COPILOT"
    case .zai:         return "Z.AI"
    case .minimax:     return "MINIMAX"
    case .kimi:        return "KIMI"
    case .cursor:      return "CURSOR"
    case .mimo:        return "MIMO"
    case .iflytek:     return "SPARK"
    case .tencentHunyuan:   return "HUNYUAN"
    case .tencentTokenPlan: return "HUNYUAN TP"
    case .volcengine:  return "DOUBAO"
    case .volcengineAgentPlan: return "DOUBAO AP"
    case .baiduQianfan: return "QIANFAN"
    case .openCodeGo:  return "OPENCODE"
    case .kilo:        return "KILO"
    case .kiro:        return "KIRO"
    case .ollama:      return "OLLAMA"
    case .openRouter:  return "OPENROUTER"
    case .warp:        return "WARP"
    }
}

@MainActor
private func miniQuotaForecast(
    tool: ToolType,
    bucket: QuotaBucket,
    environment: AppEnvironment,
    quotaService: QuotaService,
    now: Date
) -> QuotaPaceForecast? {
    guard let accountId = environment.account(for: tool)?.id else { return nil }
    let snapshot = environment.costService.snapshot(for: tool)
    return quotaService.paceForecast(
        accountId: accountId,
        bucket: bucket,
        activityHeatmap: snapshot?.heatmap,
        dailyActivity: snapshot?.dailyHistory ?? [],
        now: now,
        allowsPostResetGrace: true
    )
}

private func miniForecastPlan(_ forecast: QuotaPaceForecast, mode: DisplayMode) -> Double {
    switch mode {
    case .used: forecast.plannedUsedPercent
    case .remaining: 100 - forecast.plannedUsedPercent
    }
}

private func miniForecastLine(_ forecast: QuotaPaceForecast, now: Date, compact: Bool = false) -> String {
    if let runOutAt = forecast.runOutAt,
       let countdown = ResetCountdownFormatter.string(from: runOutAt, now: now) {
        return forecast.verdict == .watch ? "may run out \(countdown)" : "out \(countdown)"
    }
    let left = Int(forecast.projectedRemainingPercent.rounded())
    switch forecast.verdict {
    case .enough: return compact ? "left \(left)%" : "\(left)% left"
    case .surplus: return compact ? "surplus \(left)%" : "surplus · \(left)% left"
    case .watch: return "watch"
    case .atRisk: return "risk"
    case .learning: return compact ? "~\(left)% left" : "learning · \(left)% left"
    }
}

private func miniForecastColor(_ forecast: QuotaPaceForecast?) -> Color {
    guard let forecast else { return Color.secondary.opacity(0.5) }
    switch forecast.verdict {
    case .enough: return Color(red: 0.20, green: 0.70, blue: 0.48)
    case .surplus: return Color(red: 0.20, green: 0.56, blue: 0.88)
    case .watch: return Color(red: 0.96, green: 0.62, blue: 0.20)
    case .atRisk: return Color(red: 0.95, green: 0.32, blue: 0.32)
    case .learning: return .secondary
    }
}

private struct MiniProviderDivider: View {
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(width: 0.75, height: height)
    }
}

private enum MiniRingMetrics {
    static let cellWidth: CGFloat = 62
    static let ringSize: CGFloat = 48
    static let ringLineWidth: CGFloat = 5
    static let ringSpacing: CGFloat = 8
    static let labelHeight: CGFloat = 12
    static let paceHeight: CGFloat = 10
    static let resetHeight: CGFloat = 10
    /// Gap between quota-group columns *inside* one SubProvider. There is no
    /// rule here on purpose: a divider at this depth read as a SubProvider
    /// boundary when it was only separating model groups. Their own titles
    /// plus this gap do the separating.
    static let groupSpacing: CGFloat = 14
    /// Gap on each side of the `MiniGroupDivider` that separates SubProviders.
    static let memberSpacing: CGFloat = 10
    static let subProviderLabelHeight: CGFloat = 12
    static let subProviderLabelGap: CGFloat = 3
}

private struct MiniBranchGroup: Identifiable {
    let id: String
    let title: String
    var cells: [MiniBranchCell]
}

private func miniBranchGroups(
    from branchCells: [MiniBranchCell],
    settings: MiniWindowSettings
) -> [MiniBranchGroup] {
    var groups: [MiniBranchGroup] = []
    var indexByKey: [String: Int] = [:]
    for cell in branchCells {
        let key = cell.groupKey
        let title = miniGroupTitle(for: cell, settings: settings).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }
        if let index = indexByKey[key] {
            groups[index].cells.append(cell)
        } else {
            indexByKey[key] = groups.count
            groups.append(MiniBranchGroup(id: key, title: title, cells: [cell]))
        }
    }
    return groups
}

private func miniGroupTitle(for cell: MiniBranchCell, settings: MiniWindowSettings) -> String {
    let custom = settings.groupLabels[cell.groupKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let custom, !custom.isEmpty {
        return custom
    }
    return cell.defaultGroupTitle
}

private func miniSubProviderTitle(for member: MiniL2Member, settings: MiniWindowSettings) -> String {
    let key = MiniWindowGroupLabelCatalog.subProviderKey(
        tool: member.tool,
        name: member.subProviderName
    )
    let custom = settings.groupLabels[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
    return custom.flatMap { $0.isEmpty ? nil : $0 } ?? member.subProviderName
}

/// Heading for a SubProvider's primary (flat, ungrouped) buckets. Every
/// entry resolves to a quota-group name — the SubProvider itself is printed
/// one tier up by `MiniMemberStack`, so nothing here may name a product.
/// Gemini Web has no L3 group at all (its buckets *are* "5 Hours" and
/// "Weekly", AGENTS.md § 7.1), so it gets no heading rather than an invented
/// one; Grok's single group is "Weekly Credits".
private func miniPrimaryGroupTitle(
    for tool: ToolType,
    settings: MiniWindowSettings
) -> String? {
    let key: String
    switch tool {
    case .codex: key = "codex.all-models"
    case .claude: key = "claude.all-models"
    case .grok: key = "grok.all-models"
    default: return nil
    }
    let custom = settings.groupLabels[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let custom, !custom.isEmpty {
        return custom
    }
    return MiniWindowGroupLabelCatalog.defaultLabel(for: key)
}

/// Renders one L1 company super-column in the regular (ring) layout: the
/// company header on top, then one `MiniMemberStack` per L2 SubProvider,
/// separated by a thin divider. A company with a single SubProvider
/// (OpenAI → ChatGPT Agentic) still gets the SubProvider label, so the three
/// tiers read the same everywhere.
private struct MiniCompanyGroupColumn: View {
    let group: MiniCompanyGroup

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .center, spacing: 7) {
            HStack(spacing: 4) {
                Circle()
                    .fill(providerAccent(for: group.accentTool))
                    .frame(width: 5, height: 5)
                Text(group.companyName.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
                    .tracking(0.2)
            }
            .frame(width: totalContentWidth, alignment: .center)

            HStack(alignment: .top, spacing: MiniRingMetrics.memberSpacing) {
                ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        MiniGroupDivider(height: 112)
                            .padding(.top, 4)
                    }
                    MiniMemberStack(
                        member: member,
                        settings: settingsStore.settings.miniWindow
                    )
                }
            }
        }
    }

    /// Width of the SubProvider row, so the company header centres over the
    /// gauges instead of over the column's leading edge. Every gap has to be
    /// counted exactly: the divider is a layout sibling, so it takes the
    /// stack's spacing on *both* sides plus its own hairline.
    private var totalContentWidth: CGFloat {
        var width: CGFloat = 0
        for member in group.members {
            width += MiniMemberStack.width(
                for: member,
                settings: settingsStore.settings.miniWindow
            )
        }
        if group.members.count > 1 {
            width += CGFloat(group.members.count - 1)
                * (2 * MiniRingMetrics.memberSpacing + MiniGroupDivider.thickness)
        }
        return width
    }
}

/// One L2 SubProvider section: its name, then its L3 quota groups. Primary
/// provider quotas get an explicit group heading — "All Models" for ChatGPT,
/// Claude, Gemini Web, and Grok — so the tier below the SubProvider always
/// names a quota group rather than a product.
private struct MiniMemberStack: View {
    let member: MiniL2Member
    let settings: MiniWindowSettings

    var body: some View {
        VStack(alignment: .center, spacing: MiniRingMetrics.subProviderLabelGap) {
            Text(miniSubProviderTitle(for: member, settings: settings).uppercased())
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(
                    width: Self.width(for: member, settings: settings),
                    height: MiniRingMetrics.subProviderLabelHeight,
                    alignment: .center
                )
            HStack(alignment: .top, spacing: MiniRingMetrics.groupSpacing) {
                if !member.content.primaryCells.isEmpty {
                    MiniPrimaryRingGroup(
                        cells: member.content.primaryCells,
                        title: primaryGroupTitle
                    )
                }
                ForEach(branchGroups) { group in
                    MiniBranchRingGroup(group: group)
                }
            }
        }
    }

    private var branchGroups: [MiniBranchGroup] {
        miniBranchGroups(from: member.content.branchCells, settings: settings)
    }

    private var primaryGroupTitle: String? {
        miniPrimaryGroupTitle(for: member.tool, settings: settings)
    }

    static func width(
        for member: MiniL2Member,
        settings: MiniWindowSettings
    ) -> CGFloat {
        var width: CGFloat = 0
        var groupCount = 0
        if !member.content.primaryCells.isEmpty {
            width += CGFloat(member.content.primaryCells.count) * MiniRingMetrics.cellWidth
                + CGFloat(max(0, member.content.primaryCells.count - 1)) * MiniRingMetrics.ringSpacing
            groupCount += 1
        }
        let branchGroups = miniBranchGroups(from: member.content.branchCells, settings: settings)
        for group in branchGroups {
            width += CGFloat(group.cells.count) * MiniRingMetrics.cellWidth
                + CGFloat(max(0, group.cells.count - 1)) * MiniRingMetrics.ringSpacing
            groupCount += 1
        }
        if groupCount > 1 {
            width += CGFloat(groupCount - 1) * MiniRingMetrics.groupSpacing
        }
        return width
    }
}

private struct MiniPrimaryRingGroup: View {
    let cells: [MiniCell]
    let title: String?

    var body: some View {
        MiniRingGroupShell(title: title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniRingMetrics.ringSpacing) {
                ForEach(cells) { cell in
                    MiniRingCell(cell: cell)
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(cells.count) * MiniRingMetrics.cellWidth
            + CGFloat(max(0, cells.count - 1)) * MiniRingMetrics.ringSpacing
    }
}

private struct MiniBranchRingGroup: View {
    let group: MiniBranchGroup

    var body: some View {
        MiniRingGroupShell(title: group.title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniRingMetrics.ringSpacing) {
                ForEach(group.cells) { cell in
                    MiniBranchRingCell(cell: cell)
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(group.cells.count) * MiniRingMetrics.cellWidth
            + CGFloat(max(0, group.cells.count - 1)) * MiniRingMetrics.ringSpacing
    }
}

private struct MiniRingGroupShell<Content: View>: View {
    let title: String?
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.58))
                        .tracking(2.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } else {
                    Text(" ")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .hidden()
                }
            }
            .frame(width: width, height: 10, alignment: .center)
            content()
        }
    }
}

private struct MiniBranchRingCell: View {
    let cell: MiniBranchCell

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniRingMetrics.cellWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pace = UsagePace.compute(bucket: cell.bucket, now: now, allowsPostResetGrace: true)
        let forecast = miniQuotaForecast(
            tool: cell.tool,
            bucket: cell.bucket,
            environment: environment,
            quotaService: quotaService,
            now: now
        )
        let percent = cell.bucket.displayPercent(settingsStore.displayMode, tool: cell.tool)
        let color = Theme.barColor(percent: percent, mode: settingsStore.displayMode)
        VStack(spacing: 3) {
            let expected: Double? = forecast.map { miniForecastPlan($0, mode: settingsStore.displayMode) } ?? pace.map { p in
                switch settingsStore.displayMode {
                case .used:      return p.expectedUsedPercent
                case .remaining: return 100 - p.expectedUsedPercent
                }
            }
            RingGauge(
                percent: percent,
                expected: expected,
                color: color,
                markerColor: forecast.map { miniForecastColor($0) } ?? paceColor(pace: pace),
                size: MiniRingMetrics.ringSize,
                lineWidth: MiniRingMetrics.ringLineWidth
            ) {
                Text(centerText(percent: percent))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
            Text(cell.title)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.labelHeight, alignment: .center)
            Text(forecast.map { miniForecastLine($0, now: now) } ?? paceLine(pace: pace, now: now))
                .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(forecast.map { miniForecastColor($0) } ?? paceColor(pace: pace))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: MiniRingMetrics.paceHeight, alignment: .center)
            Text(resetText(now: now))
                .font(.system(size: 8, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.resetHeight, alignment: .center)
        }
        .frame(width: MiniRingMetrics.cellWidth)
        .help("\(providerTitle(for: cell.tool)) · \(cell.bucket.groupTitle ?? cell.bucket.shortLabel) · \(cell.bucket.title)")
    }

    private func centerText(percent: Double) -> String {
        if cell.bucket.id == "daily_routines" {
            let label = cell.bucket.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.contains("/") { return label }
            if cell.bucket.title.contains("--") { return "--" }
        }
        return "\(Int(percent.rounded()))%"
    }

    private func resetText(now: Date) -> String {
        ResetCountdownFormatter.string(from: cell.bucket.resetAt, now: now) ?? "—"
    }

    private func paceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return ""
        case .slightlyBehind, .behind, .farBehind:
            return pace.stageSummary
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset { return pace.stageSummary }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now).map { "out \($0)" } ?? ""
        }
    }

    private func paceColor(pace: UsagePace?) -> Color {
        guard let pace else { return Color.secondary.opacity(0.5) }
        switch pace.stage {
        case .onTrack:           return .secondary
        case .slightlyBehind:    return Color(red: 0.40, green: 0.78, blue: 0.50)
        case .behind:            return Color(red: 0.25, green: 0.72, blue: 0.45)
        case .farBehind:         return Color(red: 0.18, green: 0.62, blue: 0.40)
        case .slightlyAhead:     return Color(red: 0.96, green: 0.78, blue: 0.30)
        case .ahead:             return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .farAhead:          return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }
}

/// The rule between two L2 SubProviders inside one company column. Quota
/// groups *within* a SubProvider are deliberately undivided.
private struct MiniGroupDivider: View {
    static let thickness: CGFloat = 0.75

    var height: CGFloat = 92

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(width: Self.thickness, height: height)
    }
}

private struct MiniRingCell: View {
    let cell: MiniCell

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniRingMetrics.cellWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pace = cell.bucket.flatMap {
            UsagePace.compute(bucket: $0, now: now, allowsPostResetGrace: true)
        }
        let forecast = cell.bucket.flatMap {
            miniQuotaForecast(
                tool: cell.tool,
                bucket: $0,
                environment: environment,
                quotaService: quotaService,
                now: now
            )
        }
        VStack(spacing: 3) {
            ringGauge(pace: pace, forecast: forecast, now: now)
            Text(cell.resolvedLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.labelHeight, alignment: .center)
            Text(forecast.map { miniForecastLine($0, now: now) } ?? paceLine(pace: pace, now: now))
                .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(forecast.map { miniForecastColor($0) } ?? paceColor(pace: pace))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(height: MiniRingMetrics.paceHeight, alignment: .center)
            Text(resetText(now: now))
                .font(.system(size: 8, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.resetHeight, alignment: .center)
        }
        .frame(width: MiniRingMetrics.cellWidth)
    }

    private func resetText(now: Date) -> String {
        guard let bucket = cell.bucket else { return "—" }
        if let s = ResetCountdownFormatter.string(from: bucket.resetAt, now: now) {
            return s
        }
        return "—"
    }

    /// Pace caption shown beneath the ring:
    ///   - "X% in reserve"  → behind linear pace (good news, room to spare)
    ///   - "X% in deficit"  → ahead of linear pace, but will still last
    ///   - "out 5h 30m"     → projected to run out before reset
    ///   - empty string     → on pace, or no data yet (avoid noise)
    private func paceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return ""
        case .slightlyBehind, .behind, .farBehind:
            // User has reserve. Always preferred over the "out X" projection
            // because behind-the-line means we'd never run out anyway.
            return pace.stageSummary
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset {
                // Burning faster than linear but will still survive the window.
                return pace.stageSummary
            }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now).map { "out \($0)" } ?? ""
        }
    }

    /// Mini ring caption color. Same logic as the popover row: in reserve is
    /// green (good), in deficit is amber → red (bad), on-pace stays neutral.
    private func paceColor(pace: UsagePace?) -> Color {
        guard let pace else { return Color.secondary.opacity(0.5) }
        switch pace.stage {
        case .onTrack:           return .secondary
        case .slightlyBehind:    return Color(red: 0.40, green: 0.78, blue: 0.50)
        case .behind:            return Color(red: 0.25, green: 0.72, blue: 0.45)
        case .farBehind:         return Color(red: 0.18, green: 0.62, blue: 0.40)
        case .slightlyAhead:     return Color(red: 0.96, green: 0.78, blue: 0.30)
        case .ahead:             return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .farAhead:          return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }

    @ViewBuilder
    private func ringGauge(pace: UsagePace?, forecast: QuotaPaceForecast?, now: Date) -> some View {
        if let bucket = cell.bucket {
            let percent = bucket.displayPercent(settingsStore.displayMode, tool: cell.tool)
            let expected: Double? = forecast.map { miniForecastPlan($0, mode: settingsStore.displayMode) } ?? pace.map { p in
                switch settingsStore.displayMode {
                case .used:      return p.expectedUsedPercent
                case .remaining: return 100 - p.expectedUsedPercent
                }
            }
            let color = Theme.barColor(percent: percent, mode: settingsStore.displayMode)
            RingGauge(
                percent: percent,
                expected: expected,
                color: color,
                markerColor: forecast.map { miniForecastColor($0) } ?? paceColor(pace: pace),
                size: MiniRingMetrics.ringSize,
                lineWidth: MiniRingMetrics.ringLineWidth
            ) {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        } else {
            RingGauge(
                percent: 0,
                expected: nil,
                color: .secondary.opacity(0.4),
                size: MiniRingMetrics.ringSize,
                lineWidth: MiniRingMetrics.ringLineWidth
            ) {
                Text("--")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private enum MiniCompactMetrics {
    static let cellWidth: CGFloat = 40
    static let barHeight: CGFloat = 36
    static let barWidth: CGFloat = 7
    static let ringSpacing: CGFloat = 4
    static let labelHeight: CGFloat = 9
    static let percentHeight: CGFloat = 12
    static let paceHeight: CGFloat = 8
    static let resetHeight: CGFloat = 8
    /// See `MiniRingMetrics.groupSpacing` — no rule between quota groups
    /// inside one SubProvider.
    static let groupSpacing: CGFloat = 9
    static let memberSpacing: CGFloat = 6
    static let subProviderLabelHeight: CGFloat = 10
    static let subProviderLabelGap: CGFloat = 2
}

/// Compact-mode counterpart of `MiniCompanyGroupColumn`. Same three tiers —
/// company header, SubProvider label, quota-group bars — sized for the
/// shorter compact panel.
private struct MiniCompactL2GroupColumn: View {
    let group: MiniCompanyGroup

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(providerAccent(for: group.accentTool))
                    .frame(width: 5, height: 5)
                Text(group.companyName.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
                    .tracking(0.2)
            }
            .frame(width: totalContentWidth, alignment: .center)

            HStack(alignment: .top, spacing: MiniCompactMetrics.memberSpacing) {
                ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        MiniGroupDivider(height: 98)
                            .padding(.top, 3)
                    }
                    MiniCompactMemberStack(
                        member: member,
                        settings: settingsStore.settings.miniWindow
                    )
                }
            }
        }
    }

    private var totalContentWidth: CGFloat {
        var width: CGFloat = 0
        for member in group.members {
            width += MiniCompactMemberStack.width(
                for: member,
                settings: settingsStore.settings.miniWindow
            )
        }
        if group.members.count > 1 {
            width += CGFloat(group.members.count - 1)
                * (2 * MiniCompactMetrics.memberSpacing + MiniGroupDivider.thickness)
        }
        return width
    }
}

private struct MiniCompactMemberStack: View {
    let member: MiniL2Member
    let settings: MiniWindowSettings

    var body: some View {
        VStack(alignment: .center, spacing: MiniCompactMetrics.subProviderLabelGap) {
            Text(miniSubProviderTitle(for: member, settings: settings).uppercased())
                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(
                    width: Self.width(for: member, settings: settings),
                    height: MiniCompactMetrics.subProviderLabelHeight,
                    alignment: .center
                )
            HStack(alignment: .top, spacing: MiniCompactMetrics.groupSpacing) {
                if !member.content.primaryCells.isEmpty {
                    MiniCompactPrimaryGroup(
                        cells: member.content.primaryCells,
                        title: primaryGroupTitle
                    )
                }
                ForEach(branchGroups) { group in
                    MiniCompactBranchGroup(group: group)
                }
            }
        }
    }

    private var branchGroups: [MiniBranchGroup] {
        miniBranchGroups(from: member.content.branchCells, settings: settings)
    }

    private var primaryGroupTitle: String? {
        miniPrimaryGroupTitle(for: member.tool, settings: settings)
    }

    static func width(
        for member: MiniL2Member,
        settings: MiniWindowSettings
    ) -> CGFloat {
        var width: CGFloat = 0
        var groupCount = 0
        if !member.content.primaryCells.isEmpty {
            width += CGFloat(member.content.primaryCells.count) * MiniCompactMetrics.cellWidth
                + CGFloat(max(0, member.content.primaryCells.count - 1)) * MiniCompactMetrics.ringSpacing
            groupCount += 1
        }
        let branchGroups = miniBranchGroups(from: member.content.branchCells, settings: settings)
        for group in branchGroups {
            width += CGFloat(group.cells.count) * MiniCompactMetrics.cellWidth
                + CGFloat(max(0, group.cells.count - 1)) * MiniCompactMetrics.ringSpacing
            groupCount += 1
        }
        if groupCount > 1 {
            width += CGFloat(groupCount - 1) * MiniCompactMetrics.groupSpacing
        }
        return width
    }
}

private struct MiniCompactPrimaryGroup: View {
    let cells: [MiniCell]
    let title: String?

    var body: some View {
        MiniCompactGroupShell(title: title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniCompactMetrics.ringSpacing) {
                ForEach(cells) { cell in
                    MiniCompactBarCell(
                        data: MiniCompactCellData(
                            id: cell.id,
                            tool: cell.tool,
                            title: cell.resolvedLabel,
                            bucket: cell.bucket,
                            help: "\(providerTitle(for: cell.tool)) · \(cell.resolvedLabel)"
                        )
                    )
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(cells.count) * MiniCompactMetrics.cellWidth
            + CGFloat(max(0, cells.count - 1)) * MiniCompactMetrics.ringSpacing
    }
}

private struct MiniCompactBranchGroup: View {
    let group: MiniBranchGroup

    var body: some View {
        MiniCompactGroupShell(title: group.title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniCompactMetrics.ringSpacing) {
                ForEach(group.cells) { cell in
                    MiniCompactBarCell(
                        data: MiniCompactCellData(
                            id: cell.id,
                            tool: cell.tool,
                            title: cell.title,
                            bucket: cell.bucket,
                            help: "\(providerTitle(for: cell.tool)) · \(cell.bucket.groupTitle ?? cell.bucket.shortLabel) · \(cell.bucket.title)"
                        )
                    )
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(group.cells.count) * MiniCompactMetrics.cellWidth
            + CGFloat(max(0, group.cells.count - 1)) * MiniCompactMetrics.ringSpacing
    }
}

private struct MiniCompactGroupShell<Content: View>: View {
    let title: String?
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.56))
                        .tracking(1.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                } else {
                    Text(" ")
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .hidden()
                }
            }
            .frame(width: width, height: 9, alignment: .center)
            content()
        }
    }
}

private struct MiniCompactCellData: Identifiable {
    let id: String
    let tool: ToolType
    let title: String
    let bucket: QuotaBucket?
    let help: String
}

private struct MiniCompactBarCell: View {
    let data: MiniCompactCellData

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniCompactMetrics.cellWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pace = data.bucket.flatMap {
            UsagePace.compute(bucket: $0, now: now, allowsPostResetGrace: true)
        }
        let forecast = data.bucket.flatMap {
            miniQuotaForecast(
                tool: data.tool,
                bucket: $0,
                environment: environment,
                quotaService: quotaService,
                now: now
            )
        }
        let percent = data.bucket?.displayPercent(settingsStore.displayMode, tool: data.tool) ?? 0
        let expected: Double? = forecast.map { miniForecastPlan($0, mode: settingsStore.displayMode) } ?? pace.map { p in
            switch settingsStore.displayMode {
            case .used:      return p.expectedUsedPercent
            case .remaining: return 100 - p.expectedUsedPercent
            }
        }
        let color = data.bucket.map {
            Theme.barColor(
                percent: $0.displayPercent(settingsStore.displayMode, tool: data.tool),
                mode: settingsStore.displayMode
            )
        }
            ?? .secondary.opacity(0.45)

        VStack(spacing: 1.5) {
            Text(data.title)
                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: MiniCompactMetrics.labelHeight, alignment: .center)
            MiniVerticalQuotaBar(
                percent: percent,
                expected: expected,
                color: color,
                markerColor: forecast.map { miniForecastColor($0) } ?? compactPaceColor(pace)
            )
            Text(centerText(percent: percent))
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(height: MiniCompactMetrics.percentHeight, alignment: .center)
            Text(forecast.map { miniForecastLine($0, now: now, compact: true) } ?? compactPaceLine(pace: pace, now: now))
                .font(.system(size: 6.8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(forecast.map { miniForecastColor($0) } ?? compactPaceColor(pace))
                .lineLimit(1)
                .minimumScaleFactor(0.48)
                .frame(height: MiniCompactMetrics.paceHeight, alignment: .center)
            Text(resetText(now: now))
                .font(.system(size: 6.8, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: MiniCompactMetrics.resetHeight, alignment: .center)
        }
        .frame(width: MiniCompactMetrics.cellWidth)
        .help(data.help)
    }

    private func centerText(percent: Double) -> String {
        guard let bucket = data.bucket else { return "--" }
        if bucket.id == "daily_routines" {
            let label = bucket.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.contains("/") { return label }
            if bucket.title.contains("--") { return "--" }
        }
        return "\(Int(percent.rounded()))%"
    }

    private func resetText(now: Date) -> String {
        guard let bucket = data.bucket else { return "—" }
        return ResetCountdownFormatter.string(from: bucket.resetAt, now: now) ?? "—"
    }

    private func compactPaceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyBehind, .behind, .farBehind:
            return pace.stageSummary
                .replacingOccurrences(of: " in reserve", with: " reserve")
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset {
                return pace.stageSummary
                    .replacingOccurrences(of: " in deficit", with: " deficit")
            }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now).map { "out \($0)" } ?? ""
        }
    }

    private func compactPaceColor(_ pace: UsagePace?) -> Color {
        guard let pace else { return Color.secondary.opacity(0.5) }
        switch pace.stage {
        case .onTrack:           return .secondary
        case .slightlyBehind:    return Color(red: 0.40, green: 0.78, blue: 0.50)
        case .behind:            return Color(red: 0.25, green: 0.72, blue: 0.45)
        case .farBehind:         return Color(red: 0.18, green: 0.62, blue: 0.40)
        case .slightlyAhead:     return Color(red: 0.96, green: 0.78, blue: 0.30)
        case .ahead:             return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .farAhead:          return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }
}

private struct MiniVerticalQuotaBar: View {
    let percent: Double
    let expected: Double?
    let color: Color
    let markerColor: Color

    private static let wingWidth: CGFloat = 3.4
    private static let wingHeight: CGFloat = 1.4
    private static let wingGap: CGFloat = 1.6

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let clamped = max(0, min(100, percent)) / 100
            let fillHeight = max(2, height * CGFloat(clamped))
            let markerY = expected.map { height * (1 - CGFloat(max(0, min(100, $0)) / 100)) }
            ZStack {
                RoundedRectangle(cornerRadius: MiniCompactMetrics.barWidth / 2, style: .continuous)
                    .fill(Theme.barTrack)
                    .frame(width: MiniCompactMetrics.barWidth, height: height)
                    .position(x: proxy.size.width / 2, y: height / 2)
                RoundedRectangle(cornerRadius: MiniCompactMetrics.barWidth / 2, style: .continuous)
                    .fill(color)
                    .frame(width: MiniCompactMetrics.barWidth, height: fillHeight)
                    .position(x: proxy.size.width / 2, y: height - fillHeight / 2)
                if let markerY {
                    // The original pace marker was a 14×1.1pt capsule cutting
                    // straight across the 7pt bar — visually heavy, almost
                    // double the bar's width. Two small "wings" flanking the
                    // bar at the expected pace level read as a tick gauge
                    // instead of a crossbar, and leave the bar fill itself
                    // uncluttered.
                    let halfBar = MiniCompactMetrics.barWidth / 2
                    let wingCenterOffset = halfBar + Self.wingGap + Self.wingWidth / 2
                    Capsule()
                        .fill(markerColor.opacity(0.85))
                        .frame(width: Self.wingWidth, height: Self.wingHeight)
                        .position(x: proxy.size.width / 2 - wingCenterOffset, y: markerY)
                    Capsule()
                        .fill(markerColor.opacity(0.85))
                        .frame(width: Self.wingWidth, height: Self.wingHeight)
                        .position(x: proxy.size.width / 2 + wingCenterOffset, y: markerY)
                }
            }
        }
        .frame(width: 16, height: MiniCompactMetrics.barHeight)
    }
}

private struct RingGauge<CenterLabel: View>: View {
    let percent: Double
    let expected: Double?
    let color: Color
    var markerColor: Color = .secondary
    var size: CGFloat = 50
    var lineWidth: CGFloat = 5
    @ViewBuilder var center: () -> CenterLabel

    private let arcFraction: Double = 0.78

    var body: some View {
        let clamped = max(0, min(100, percent)) / 100
        let rotation: Angle = .degrees(90 + (1 - arcFraction) * 180)
        ZStack {
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(Theme.barTrack, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
            Circle()
                .trim(from: 0, to: arcFraction * clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
            if let expected, expected > 0 && expected < 100 {
                let expectedFraction = max(0, min(100, expected)) / 100
                let markerCenter = arcFraction * expectedFraction
                let markerSpan = 0.012
                Circle()
                    .trim(
                        from: max(0, markerCenter - markerSpan),
                        to: min(arcFraction, markerCenter + markerSpan)
                    )
                    .stroke(markerColor.opacity(0.20), style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round))
                    .rotationEffect(rotation)
                Circle()
                    .trim(
                        from: max(0, markerCenter - markerSpan),
                        to: min(arcFraction, markerCenter + markerSpan)
                    )
                    .stroke(markerColor, style: StrokeStyle(lineWidth: lineWidth + 1, lineCap: .round))
                    .rotationEffect(rotation)
            }
            center()
        }
        .frame(width: size, height: size)
    }
}
