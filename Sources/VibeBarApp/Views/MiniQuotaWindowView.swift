import SwiftUI
import VibeBarCore

/// Label resolution for one mini window: the window's own overrides win,
/// the shared names second, catalog defaults last (at the call sites).
struct MiniLabelContext {
    let settings: MiniWindowSettings
    let config: MiniWindowConfig?

    func fieldLabel(_ fieldId: String) -> String? {
        settings.resolvedFieldLabel(config: config, fieldId: fieldId)
    }

    func groupLabel(_ key: String) -> String? {
        settings.resolvedGroupLabel(config: config, key: key)
    }
}

struct MiniQuotaWindowView: View {
    /// Which `MiniWindowConfig` this panel renders. Every panel gets its own
    /// hosting view; the config is re-read from settings on each render so
    /// Settings edits apply live.
    let configID: UUID
    let onClose: () -> Void
    let onToggleDisplayMode: () -> Void

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    /// Observe the QuotaService directly so the mini window re-renders the
    /// instant a quota refresh lands. Without this the view only redraws on
    /// a settings change or the panel clock's 30 s tick, which made timer- or
    /// button-driven refreshes feel laggy compared to the popover.
    @EnvironmentObject var quotaService: QuotaService
    /// Present only on the Layout Studio's stage — the field order a drag in
    /// flight is proposing, drawn instead of the saved one.
    @Environment(\.studioMiniOrderOverride) private var orderOverride

    private var config: MiniWindowConfig {
        var config = settingsStore.settings.miniWindow.config(id: configID)
            ?? settingsStore.settings.miniWindow.windows.first
            ?? MiniWindowConfig(name: "Mini", fieldIds: [])
        if let orderOverride, orderOverride.windowID == configID {
            config.fieldIds = orderOverride.fieldIds
        }
        return config
    }

    var body: some View {
        let config = self.config
        let displayMode = config.displayMode

        ZStack(alignment: .topTrailing) {
            Group {
                switch displayMode {
                case .regular, .compact:
                    ringOrBarBody(config: config, displayMode: displayMode)
                case .ledger:
                    MiniLedgerLayout(entries: miniEntries(config: config))
                case .strip:
                    MiniStripLayout(entries: miniEntries(config: config), density: config.stripDensity)
                case .tile:
                    MiniTileLayout(entries: miniEntries(config: config))
                case .focus:
                    MiniFocusLayout(entries: miniEntries(config: config))
                case .rail:
                    MiniRailLayout(entries: miniEntries(config: config))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggleDisplayMode)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.vibeBar)
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: Theme.miniCornerRadius)
        )
        // The panel is borderless and non-activating, so it never becomes
        // key — but the close button would still draw a system focus ring
        // after a click without this.
        .vibeBarControlFocus()
    }

    @ViewBuilder
    private func ringOrBarBody(config: MiniWindowConfig, displayMode: MiniWindowDisplayMode) -> some View {
        let contentByTool = miniContentByTool(config: config)
        MiniWindowProviderLayout(
            displayMode: displayMode,
            orderedFieldIds: visibleOrderedFieldIds(config: config, contentByTool: contentByTool),
            contentByTool: contentByTool,
            registry: quotaService.fieldRegistry,
            labels: MiniLabelContext(settings: settingsStore.settings.miniWindow, config: config)
        )
        .padding(.horizontal, displayMode == .compact ? 8 : 14)
        .padding(.top, displayMode == .compact ? 16 : 22)
        .padding(.bottom, displayMode == .compact ? 9 : 14)
        .frame(
            minWidth: displayMode == .compact ? 156 : 240,
            // Three tiers: company header, SubProvider label, quota groups.
            // `MiniQuotaWindowController.stableContentSize` reserves the same
            // rows — keep the two in step.
            minHeight: displayMode == .compact ? 146 : 181,
            alignment: .center
        )
    }

    /// The config's field order restricted to fields that resolve and have a
    /// live bucket — the input to the ordered company → SubProvider skeleton.
    private func visibleOrderedFieldIds(
        config: MiniWindowConfig,
        contentByTool: [ToolType: MiniToolContent]
    ) -> [String] {
        let visible = Set(
            contentByTool.values.flatMap { content in
                content.primaryCells.map(\.field.id) + content.branchCells.map(\.field.id)
            }
        )
        return config.fieldIds.filter { visible.contains($0) }
    }

    /// The flat, ordered entry list the alternative layouts render from.
    private func miniEntries(config: MiniWindowConfig) -> [MiniEntry] {
        MiniEntry.entries(
            config: config,
            settings: settingsStore.settings.miniWindow,
            registry: quotaService.fieldRegistry,
            quota: { environment.quota(for: $0) }
        )
    }

    private func miniContentByTool(config: MiniWindowConfig) -> [ToolType: MiniToolContent] {
        let selected = config.fieldIds
        let selectedFieldIds = Set(selected)
        let registry = quotaService.fieldRegistry
        let labels = MiniLabelContext(settings: settingsStore.settings.miniWindow, config: config)
        var contentByTool: [ToolType: MiniToolContent] = [:]
        for tool in ToolType.dedicatedCardProviders {
            var cells: [MiniCell] = []
            for fieldId in selected {
                guard
                    let field = MenuBarFieldCatalog.field(id: fieldId, registry: registry),
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
                        customLabel: labels.fieldLabel(field.id)
                    )
                )
            }
            let selectedBucketIds = Set(cells.map { $0.field.bucketId })
            let branchCells = branchCells(
                for: tool,
                orderedFieldIds: selected,
                registry: registry,
                labels: labels,
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
        Self.isBranchStyleField(field)
    }

    /// Static classification shared with the Settings naming tree and the menu
    /// bar's group merge, which need the same grouped/flat answer without a
    /// live bucket in hand. The rules live in `VibeBarCore`.
    static func isBranchStyleField(_ field: MenuBarFieldOption) -> Bool {
        MenuBarFieldCatalog.isBranchStyleField(field)
    }

    /// Branch cells in the config's own field order — the user's arrangement,
    /// not the adapter's bucket order.
    private func branchCells(
        for tool: ToolType,
        orderedFieldIds: [String],
        registry: QuotaFieldRegistry,
        labels: MiniLabelContext,
        excluding selectedBucketIds: Set<String>
    ) -> [MiniBranchCell] {
        guard let quota = environment.quota(for: tool) else { return [] }
        return orderedFieldIds.compactMap { fieldId in
            guard
                let field = MenuBarFieldCatalog.field(id: fieldId, registry: registry),
                field.tool == tool,
                let bucket = quota.bucket(id: field.bucketId),
                !selectedBucketIds.contains(bucket.id),
                Self.hasQuotaGroup(bucket, tool: tool, bucketId: bucket.id)
            else { return nil }
            return MiniBranchCell(
                tool: tool,
                field: field,
                bucket: bucket,
                customLabel: labels.fieldLabel(field.id)
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
    orderedFieldIds: [String],
    contentByTool: [ToolType: MiniToolContent],
    registry: QuotaFieldRegistry
) -> [MiniCompanyGroup] {
    let skeleton = MenuBarFieldCatalog.orderedSubProviderGroups(
        fieldIds: orderedFieldIds,
        registry: registry
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
    let orderedFieldIds: [String]
    let contentByTool: [ToolType: MiniToolContent]
    let registry: QuotaFieldRegistry
    let labels: MiniLabelContext

    var body: some View {
        let groups = miniProductGroups(
            orderedFieldIds: orderedFieldIds,
            contentByTool: contentByTool,
            registry: registry
        )
        // One clock for the whole panel. Every ring / bar cell used to own a
        // `TimelineView(.periodic(from: .now, by: 30))`, so a mini window with
        // a dozen selected buckets ran a dozen timers on a dozen phases and
        // handed `QuotaService.paceForecast` a dozen different `now` values —
        // its memo could not hit once. The cells take the date as plain data
        // now, and hoisting the tick also keeps `miniProductGroups` above out
        // of the per-tick path. Mini windows are visible whenever they exist,
        // so this is an ungated `StableClock`.
        StableClock(interval: 30) { tickDate in
            HStack(alignment: .top, spacing: displayMode == .compact ? 8 : 14) {
                // Positional identity on purpose: an arrangement that
                // interleaves vendors legally produces two columns named
                // "Google AI", and a name-keyed ForEach would render the first
                // column's content twice.
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        MiniProviderDivider(height: displayMode == .compact ? 94 : 131)
                            .padding(.top, 2)
                    }
                    switch displayMode {
                    case .compact:
                        MiniCompactL2GroupColumn(group: group, labels: labels, now: tickDate)
                    default:
                        // Only regular and compact reach this layout; the
                        // alternative modes render their own views.
                        MiniCompanyGroupColumn(group: group, labels: labels, now: tickDate)
                    }
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
            return QuotaGroupLabelLocalizer.displayComposed(bucket.title)
        }
        if let bucket, field.defaultLabel != bucket.shortLabel {
            return QuotaGroupLabelLocalizer.displayComposed(bucket.shortLabel)
        }
        return QuotaGroupLabelLocalizer.displayComposed(field.defaultLabel)
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

    /// The contract label, with the generic window words translated on the
    /// way to the screen; a model-named bucket comes back untouched.
    private var defaultTitle: String {
        QuotaGroupLabelLocalizer.displayComposed(contractTitle)
    }

    private var contractTitle: String {
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
            return "Medium"
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
        QuotaGroupLabelLocalizer.displayComposed(contractGroupTitle)
    }

    private var contractGroupTitle: String {
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
            return "Claude + GPT"
        case let id where tool == .gemini && id.contains("flash-lite"):
            return "Flash Lite"
        case let id where tool == .gemini && id.contains("flash"):
            return "Flash"
        case let id where tool == .gemini && id.contains("pro"):
            return "Pro"
        case let id where tool == .antigravity && id.contains("gpt-oss"):
            return "GPT-OSS"
        case let id where tool == .antigravity && id.contains("claude"):
            return "Claude"
        case let id where tool == .antigravity && id.contains("flash-lite"):
            return "Flash Lite"
        case let id where tool == .antigravity && id.contains("flash"):
            return "Flash"
        case let id where tool == .antigravity && id.contains("gemini") && id.contains("pro"):
            return "Pro"
        default:
            return (bucket.groupTitle ?? bucket.shortLabel)
                .replacingOccurrences(of: "GPT-5.3 Codex Spark", with: "Spark")
                .replacingOccurrences(of: "Daily Routines", with: "Routine")
        }
    }
}

/// Brand hue for a provider. The table itself lives in `Theme` so the charts
/// that colour-code providers share exactly these hues.
func providerAccent(for tool: ToolType) -> Color {
    Theme.providerAccent(for: tool)
}

func providerTitle(for tool: ToolType) -> String {
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
func miniQuotaForecast(
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

func miniForecastPlan(_ forecast: QuotaPaceForecast, mode: DisplayMode) -> Double {
    switch mode {
    case .used: forecast.plannedUsedPercent
    case .remaining: 100 - forecast.plannedUsedPercent
    }
}

func miniForecastLine(_ forecast: QuotaPaceForecast, now: Date, compact: Bool = false) -> String {
    if let runOutAt = forecast.runOutAt,
       let countdown = ResetCountdownFormatter.string(from: runOutAt, now: now) {
        return forecast.verdict == .watch
            ? L10n.Quota.miniForecastMayRunOut(countdown: countdown)
            : L10n.Quota.paceRunsOutShort(countdown: countdown)
    }
    let left = Int(forecast.projectedRemainingPercent.rounded())
    switch forecast.verdict {
    case .enough:
        return compact
            ? L10n.Quota.miniForecastLeftCompact(percent: left)
            : L10n.Quota.miniForecastLeft(percent: left)
    case .surplus:
        return compact
            ? L10n.Quota.miniForecastSurplusCompact(percent: left)
            : L10n.Quota.miniForecastSurplus(percent: left)
    case .watch: return L10n.Quota.forecastVerdictWatch
    case .atRisk: return L10n.Quota.forecastVerdictAtRisk
    case .learning:
        return compact
            ? L10n.Quota.miniForecastLearningCompact(percent: left)
            : L10n.Quota.miniForecastLearning(percent: left)
    }
}

func miniForecastColor(_ forecast: QuotaPaceForecast?) -> Color {
    guard let forecast else { return Color.secondary.opacity(0.5) }
    return QuotaForecastPalette.color(for: forecast.verdict)
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
    labels: MiniLabelContext
) -> [MiniBranchGroup] {
    var groups: [MiniBranchGroup] = []
    var indexByKey: [String: Int] = [:]
    for cell in branchCells {
        let key = cell.groupKey
        let title = miniGroupTitle(for: cell, labels: labels).trimmingCharacters(in: .whitespacesAndNewlines)
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

private func miniGroupTitle(for cell: MiniBranchCell, labels: MiniLabelContext) -> String {
    labels.groupLabel(cell.groupKey) ?? cell.defaultGroupTitle
}

private func miniSubProviderTitle(for member: MiniL2Member, labels: MiniLabelContext) -> String {
    let key = MiniWindowGroupLabelCatalog.subProviderKey(
        tool: member.tool,
        name: member.subProviderName
    )
    return labels.groupLabel(key) ?? member.subProviderName
}

/// Heading for a SubProvider's primary (flat, ungrouped) buckets. Every
/// entry resolves to a quota-group name — the SubProvider itself is printed
/// one tier up by `MiniMemberStack`, so nothing here may name a product.
/// Gemini Web's two anonymous buckets get the same "All Models" heading as
/// the other headline groups: the row is reserved either way, and a blank
/// there read as a rendering bug rather than a design choice.
private func miniPrimaryGroupTitle(
    for tool: ToolType,
    labels: MiniLabelContext
) -> String? {
    let key: String
    switch tool {
    case .codex: key = "codex.all-models"
    case .claude: key = "claude.all-models"
    case .gemini: key = "gemini.all-models"
    case .grok: key = "grok.all-models"
    default: return nil
    }
    return labels.groupLabel(key) ?? MiniWindowGroupLabelCatalog.defaultLabel(for: key)
}

/// Renders one L1 company super-column in the regular (ring) layout: the
/// company header on top, then one `MiniMemberStack` per L2 SubProvider,
/// separated by a thin divider. A company with a single SubProvider
/// (OpenAI → ChatGPT Agentic) still gets the SubProvider label, so the three
/// tiers read the same everywhere.
private struct MiniCompanyGroupColumn: View {
    let group: MiniCompanyGroup
    let labels: MiniLabelContext
    /// Tick from the panel's single clock, passed straight down to the cells.
    let now: Date

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
                    MiniMemberStack(member: member, labels: labels, now: now)
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
            width += MiniMemberStack.width(for: member, labels: labels)
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
    let labels: MiniLabelContext
    let now: Date

    var body: some View {
        VStack(alignment: .center, spacing: MiniRingMetrics.subProviderLabelGap) {
            Text(miniSubProviderTitle(for: member, labels: labels).uppercased())
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(
                    width: Self.width(for: member, labels: labels),
                    height: MiniRingMetrics.subProviderLabelHeight,
                    alignment: .center
                )
            HStack(alignment: .top, spacing: MiniRingMetrics.groupSpacing) {
                if !member.content.primaryCells.isEmpty {
                    MiniPrimaryRingGroup(
                        cells: member.content.primaryCells,
                        title: primaryGroupTitle,
                        now: now
                    )
                }
                ForEach(branchGroups) { group in
                    MiniBranchRingGroup(group: group, now: now)
                }
            }
        }
    }

    private var branchGroups: [MiniBranchGroup] {
        miniBranchGroups(from: member.content.branchCells, labels: labels)
    }

    private var primaryGroupTitle: String? {
        miniPrimaryGroupTitle(for: member.tool, labels: labels)
    }

    static func width(
        for member: MiniL2Member,
        labels: MiniLabelContext
    ) -> CGFloat {
        var width: CGFloat = 0
        var groupCount = 0
        if !member.content.primaryCells.isEmpty {
            width += CGFloat(member.content.primaryCells.count) * MiniRingMetrics.cellWidth
                + CGFloat(max(0, member.content.primaryCells.count - 1)) * MiniRingMetrics.ringSpacing
            groupCount += 1
        }
        let branchGroups = miniBranchGroups(from: member.content.branchCells, labels: labels)
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
    let now: Date

    var body: some View {
        MiniRingGroupShell(title: title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniRingMetrics.ringSpacing) {
                ForEach(cells) { cell in
                    MiniRingCell(cell: cell, now: now)
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
    let now: Date

    var body: some View {
        MiniRingGroupShell(title: group.title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniRingMetrics.ringSpacing) {
                ForEach(group.cells) { cell in
                    MiniBranchRingCell(cell: cell, now: now)
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
    /// Tick from the panel's clock — this cell owns no timer.
    let now: Date

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        content(now: now)
            .frame(width: MiniRingMetrics.cellWidth)
            .surfaceItem(cell.field.id)
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
        .help(miniCellHelp(tool: cell.tool, bucket: cell.bucket))
    }

    private func centerText(percent: Double) -> String {
        if cell.bucket.id == "daily_routines" {
            let label = cell.bucket.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.contains("/") { return label }
            if cell.bucket.title.contains("--") { return "--" }
        }
        return L10n.Common.percent(value: Int(percent.rounded()))
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
            return ResetCountdownFormatter.string(from: target, now: now)
                .map { L10n.Quota.paceRunsOutShort(countdown: $0) } ?? ""
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
    /// Tick from the panel's clock — this cell owns no timer.
    let now: Date

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        content(now: now)
            .frame(width: MiniRingMetrics.cellWidth)
            .surfaceItem(cell.field.id)
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
            return ResetCountdownFormatter.string(from: target, now: now)
                .map { L10n.Quota.paceRunsOutShort(countdown: $0) } ?? ""
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
                Text(L10n.Common.percent(value: Int(percent.rounded())))
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
    let labels: MiniLabelContext
    /// Tick from the panel's single clock, passed straight down to the cells.
    let now: Date

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
                    MiniCompactMemberStack(member: member, labels: labels, now: now)
                }
            }
        }
    }

    private var totalContentWidth: CGFloat {
        var width: CGFloat = 0
        for member in group.members {
            width += MiniCompactMemberStack.width(for: member, labels: labels)
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
    let labels: MiniLabelContext
    let now: Date

    var body: some View {
        VStack(alignment: .center, spacing: MiniCompactMetrics.subProviderLabelGap) {
            Text(miniSubProviderTitle(for: member, labels: labels).uppercased())
                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(
                    width: Self.width(for: member, labels: labels),
                    height: MiniCompactMetrics.subProviderLabelHeight,
                    alignment: .center
                )
            HStack(alignment: .top, spacing: MiniCompactMetrics.groupSpacing) {
                if !member.content.primaryCells.isEmpty {
                    MiniCompactPrimaryGroup(
                        cells: member.content.primaryCells,
                        title: primaryGroupTitle,
                        now: now
                    )
                }
                ForEach(branchGroups) { group in
                    MiniCompactBranchGroup(group: group, now: now)
                }
            }
        }
    }

    private var branchGroups: [MiniBranchGroup] {
        miniBranchGroups(from: member.content.branchCells, labels: labels)
    }

    private var primaryGroupTitle: String? {
        miniPrimaryGroupTitle(for: member.tool, labels: labels)
    }

    static func width(
        for member: MiniL2Member,
        labels: MiniLabelContext
    ) -> CGFloat {
        var width: CGFloat = 0
        var groupCount = 0
        if !member.content.primaryCells.isEmpty {
            width += CGFloat(member.content.primaryCells.count) * MiniCompactMetrics.cellWidth
                + CGFloat(max(0, member.content.primaryCells.count - 1)) * MiniCompactMetrics.ringSpacing
            groupCount += 1
        }
        let branchGroups = miniBranchGroups(from: member.content.branchCells, labels: labels)
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
    let now: Date

    var body: some View {
        MiniCompactGroupShell(title: title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniCompactMetrics.ringSpacing) {
                ForEach(cells) { cell in
                    MiniCompactBarCell(
                        data: MiniCompactCellData(
                            id: cell.id,
                            fieldID: cell.field.id,
                            tool: cell.tool,
                            title: cell.resolvedLabel,
                            bucket: cell.bucket,
                            help: miniCellHelp(tool: cell.tool, label: cell.resolvedLabel)
                        ),
                        now: now
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
    let now: Date

    var body: some View {
        MiniCompactGroupShell(title: group.title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniCompactMetrics.ringSpacing) {
                ForEach(group.cells) { cell in
                    MiniCompactBarCell(
                        data: MiniCompactCellData(
                            id: cell.id,
                            fieldID: cell.field.id,
                            tool: cell.tool,
                            title: cell.title,
                            bucket: cell.bucket,
                            help: miniCellHelp(tool: cell.tool, bucket: cell.bucket)
                        ),
                        now: now
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
    /// The field this cell draws — what the arrangement stores, and what the
    /// Layout Studio picks the cell up by.
    let fieldID: String
    let tool: ToolType
    let title: String
    let bucket: QuotaBucket?
    let help: String
}

private struct MiniCompactBarCell: View {
    let data: MiniCompactCellData
    /// Tick from the panel's clock — this cell owns no timer.
    let now: Date

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        content(now: now)
            .frame(width: MiniCompactMetrics.cellWidth)
            .surfaceItem(data.fieldID)
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
        return L10n.Common.percent(value: Int(percent.rounded()))
    }

    private func resetText(now: Date) -> String {
        guard let bucket = data.bucket else { return "—" }
        return ResetCountdownFormatter.string(from: bucket.resetAt, now: now) ?? "—"
    }

    private func compactPaceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return L10n.Quota.paceOnTrack
        case .slightlyBehind, .behind, .farBehind:
            return pace.stageSummaryCompact
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset {
                return pace.stageSummaryCompact
            }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now)
                .map { L10n.Quota.paceRunsOutShort(countdown: $0) } ?? ""
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

struct RingGauge<CenterLabel: View>: View {
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

/// Provider · label, where the label has already been resolved (and, where it
/// is a generic window word, translated) by the cell that owns it.
private func miniCellHelp(tool: ToolType, label: String) -> String {
    "\(providerTitle(for: tool)) · \(label)"
}

/// Provider · group · bucket, with the generic window words translated and
/// every name left exactly as its owner spells it.
private func miniCellHelp(tool: ToolType, bucket: QuotaBucket) -> String {
    let group = QuotaGroupLabelLocalizer.displayComposed(bucket.groupTitle ?? bucket.shortLabel)
    let title = QuotaGroupLabelLocalizer.displayComposed(bucket.title)
    return "\(providerTitle(for: tool)) · \(group) · \(title)"
}
