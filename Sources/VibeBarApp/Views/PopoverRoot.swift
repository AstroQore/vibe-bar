import SwiftUI
import AppKit
import VibeBarCore

/// Top-level content for Vibe Bar's single tabbed popover workspace.
struct PopoverRoot: View {
    let width: CGFloat
    let onContentHeightChange: (CGFloat) -> Void
    let onToggleMiniWindow: () -> Void

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService
    @State private var overviewPage: OverviewPage = .overview
    @State private var autoRefreshedPageKeys: Set<String> = []

    var body: some View {
        let shellDensity = shellDensity
        let contentDensity = activeDensity
        VStack(alignment: .leading, spacing: shellDensity.interSectionSpacing) {
            HeaderView(
                title: headerTitle,
                subtitle: headerSubtitle,
                plan: nil,
                lastUpdated: latestUpdated,
                isRefreshing: isRefreshing,
                titleFontSize: shellDensity.titleFontSize + 2,
                subtitleFontSize: shellDensity.subtitleFontSize,
                accessory: AnyView(OverviewPageSwitch(selection: $overviewPage, density: shellDensity)),
                onRefresh: { environment.refreshAll() },
                onToggleMiniWindow: onToggleMiniWindow,
                onShowSettings: { environment.showSettingsWindow() }
            )
            .frame(height: shellDensity.headerHeight, alignment: .center)
            Divider().opacity(0.3)
            ScrollView(.vertical, showsIndicators: false) {
                content(density: contentDensity)
                    .padding(.bottom, 4)
            }
            .frame(maxHeight: maxScrollHeight)
        }
        .padding(.horizontal, shellDensity.popoverPaddingH)
        .padding(.vertical, shellDensity.popoverPaddingV)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .readHeight(onContentHeightChange)
        .onAppear(perform: refreshVisibleProvidersIfNeeded)
        .onChange(of: overviewPage) { _, _ in
            refreshVisibleProvidersIfNeeded()
        }
    }

    /// The tabbed popover is one shared shell. Provider pages may use their
    /// own content metrics, but the title band and outer margins must never
    /// shift when the selected tab changes.
    private var shellDensity: Theme.Density {
        Theme.overviewDensity(for: settingsStore.settings.popoverDensity)
    }

    private var activeDensity: Theme.Density {
        let profile = settingsStore.settings.popoverDensity
        switch overviewPage {
        case .overview, .misc:
            return Theme.overviewDensity(for: profile)
        case .openAI, .claude, .googleAI, .grok:
            return Theme.detailDensity(for: profile)
        }
    }

    private var maxScrollHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, visible - 150)
    }

    @ViewBuilder
    private func content(density: Theme.Density) -> some View {
        switch overviewPage {
        case .overview:
            OverviewWaterfall(density: density)
        case .claude:
            ProviderDetailView(tool: .claude, density: density)
        case .openAI:
            ProviderDetailView(tool: .codex, density: density)
        case .googleAI:
            GeminiTabPage(density: density)
        case .grok:
            GrokPage(density: density)
        case .misc:
            MiscProvidersPage(density: density)
        }
    }

    private var headerTitle: String {
        switch overviewPage {
        case .overview: return "Overview"
        case .openAI: return "ChatGPT"
        case .claude: return "Claude"
        case .googleAI: return "Gemini"
        case .grok: return "Grok"
        case .misc: return "Misc Providers"
        }
    }

    private var headerSubtitle: String? {
        switch overviewPage {
        case .overview: return "All providers · quota & cost"
        case .openAI: return ToolType.codex.subtitle
        case .claude: return ToolType.claude.subtitle
        case .googleAI: return "Gemini Web + AntiGravity · quota & status"
        case .grok: return "xAI · monthly credits, cost & status"
        case .misc: return "Usage-only · sign in or paste a key"
        }
    }

    private var visibleTools: [ToolType] {
        // Header timestamps and refresh state aggregate the providers
        // visible in the current popover. The Misc subpage owns its
        // usage-only integrations; the Google AI subpage aggregates the
        // partial-primary pair; the Grok subpage shows just `.grok`.
        if overviewPage == .misc {
            return settingsStore.settings.visibleMiscProviderList
        }
        if overviewPage == .googleAI {
            return ToolType.googleAIPair
        }
        if overviewPage == .grok {
            return [.grok]
        }
        switch overviewPage {
        case .overview:
            return ToolType.dedicatedCardProviders.filter {
                settingsStore.settings.isCoreProviderVisible($0)
            }
        case .openAI: return [.codex]
        case .claude: return [.claude]
        case .googleAI: return ToolType.googleAIPair
        case .grok: return [.grok]
        case .misc: return settingsStore.settings.visibleMiscProviderList
        }
    }

    private var latestUpdated: Date? {
        visibleAccounts
            .compactMap { quotaService.lastUpdatedByAccount[$0.id] }
            .max()
    }

    private var isRefreshing: Bool {
        let ids = visibleAccounts.map(\.id)
        return ids.contains { quotaService.inFlightAccountIds.contains($0) }
    }

    private var visibleAccounts: [AccountIdentity] {
        if overviewPage == .misc {
            return settingsStore.settings.visibleMiscProviderInstances
                .compactMap { environment.account(for: $0) }
        }
        return visibleTools.compactMap { environment.account(for: $0) }
    }

    private var autoRefreshKey: String {
        overviewPage.rawValue
    }

    private func refreshVisibleProvidersIfNeeded() {
        let key = autoRefreshKey
        guard !autoRefreshedPageKeys.contains(key) else { return }
        let accounts = visibleAccounts
        let refreshAge = TimeInterval(max(60, settingsStore.settings.refreshIntervalSeconds))
        let missing = accounts.filter { account in
            quotaService.needsRefresh(accountId: account.id, maxAge: refreshAge)
                && !quotaService.inFlightAccountIds.contains(account.id)
        }
        guard !missing.isEmpty else { return }
        autoRefreshedPageKeys.insert(key)
        Task { @MainActor in
            for account in missing {
                _ = await quotaService.refresh(account)
            }
        }
    }
}

private struct ProviderSectionTitle: View {
    let tool: ToolType
    let title: String
    var subtitle: String?
    let titleFontSize: CGFloat
    let subtitleFontSize: CGFloat
    var iconSize: CGFloat = 17
    var badgeSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolBrandBadge(
                tool: tool,
                iconSize: iconSize,
                containerSize: badgeSize
            )
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: subtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .layoutPriority(1)
    }
}

// MARK: - Overview (per-provider columns + totals header)

private enum OverviewPage: String, CaseIterable, Identifiable {
    case overview
    case openAI
    case claude
    case googleAI
    case grok
    case misc

    var id: String { rawValue }

    /// L2 product-family labels. The tab strip used to mix L1 vendor
    /// names (OpenAI, Google AI) with L2 product names (Claude, Grok);
    /// pinning every tab to L2 means the tab strip reads "ChatGPT ·
    /// Claude · Gemini · Grok" — what the user calls the AI, not how
    /// they're billed. Gemini's tab covers both Gemini Web and the
    /// AntiGravity IDE since both roll up to the Gemini product.
    var label: String {
        switch self {
        case .overview: return "Overview"
        case .openAI:   return "ChatGPT"
        case .claude:   return "Claude"
        case .googleAI: return "Gemini"
        case .grok:     return "Grok"
        case .misc:     return "Misc"
        }
    }

    var coreProvider: ToolType? {
        switch self {
        case .openAI: return .codex
        case .claude: return .claude
        case .googleAI: return .gemini
        case .grok: return .grok
        case .overview, .misc: return nil
        }
    }
}

private struct OverviewPageSwitch: View {
    @Binding var selection: OverviewPage
    let density: Theme.Density

    @EnvironmentObject var settingsStore: SettingsStore

    private var visiblePages: [OverviewPage] {
        OverviewPage.allCases.filter { page in
            guard let provider = page.coreProvider else { return true }
            return settingsStore.settings.isCoreProviderVisible(provider)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(visiblePages) { page in
                let isSelected = selection == page
                BorderlessRowButton(action: {
                    selection = page
                }) {
                    HStack(spacing: 5) {
                        OverviewSwitchIcon(page: page, isSelected: isSelected)
                        Text(page.label)
                            .font(.system(size: max(9.5, density.segmentedFontSize - 1), weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.20))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.34), lineWidth: 0.7)
                                )
                        }
                    }
                }
                .help("Show \(page.label)")
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.075), lineWidth: 0.7)
                )
        )
        .onChange(of: settingsStore.settings.visibleCoreProviders) { _, _ in
            if !visiblePages.contains(selection) {
                selection = .overview
            }
        }
    }
}

private struct OverviewSwitchIcon: View {
    let page: OverviewPage
    let isSelected: Bool

    private static let iconSize: CGFloat = 13

    var body: some View {
        // Every tab uses the same 13pt icon canvas — mixing 14pt for
        // Overview with 13pt for the rest, and ProviderBrandIconView
        // for codex/claude with ToolBrandIconView for gemini/grok,
        // made the row read "高低不齐" (uneven baselines / sizes).
        // One renderer (`ToolBrandIconView` driven off the L2-
        // representative ToolType) keeps every tab visually pinned to
        // the same baseline. Overview and Misc still get SF symbols
        // because they aren't single-provider tabs.
        Group {
            switch page {
            case .overview:
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: Self.iconSize, weight: .semibold))
            case .misc:
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: Self.iconSize, weight: .medium))
            case .openAI:
                ToolBrandIconView(tool: .codex, size: Self.iconSize)
            case .claude:
                ToolBrandIconView(tool: .claude, size: Self.iconSize)
            case .googleAI:
                ToolBrandIconView(tool: .gemini, size: Self.iconSize)
            case .grok:
                ToolBrandIconView(tool: .grok, size: Self.iconSize)
            }
        }
        .opacity(isSelected ? 1 : 0.72)
        .frame(width: 18, height: 16, alignment: .center)
    }
}

/// Overview popover content, top-to-bottom:
///   1. `CombinedTotalsRow` — cost+token grid plus live service status.
///   2. A live-measured `ColumnMasonryLayout` covering everything else. It
///      globally balances the four quota cards first, then places Cost cards
///      from those seeded column heights, and finally fills the shorter side
///      with supporting analytics. Quota rows can grow or shrink after every
///      refresh without leaving a permanently sparse column.
private struct OverviewWaterfall: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var masonrySession = ColumnMasonryLayout.Session()

    var body: some View {
        let snapshots = overviewCostSnapshots
        let combinedHistory = CostSnapshotAggregator.combinedDailyHistory(snapshots)
        let combinedHeatmap = CostSnapshotAggregator.combinedHeatmap(snapshots)
        let combinedModels = CostSnapshotAggregator.combinedModelBreakdowns(snapshots)
        let hasCostData = snapshots.contains { $0.jsonlFilesFound > 0 }
        let combinedCostSnapshot = CostSnapshotAggregator.combinedSnapshot(
            tool: .codex,
            snapshots: snapshots
        )

        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            CombinedTotalsRow(density: density)
            ColumnMasonryLayout(
                columns: 2,
                spacing: density.interSectionSpacing,
                session: masonrySession
            ) {
                if isVisible(.codex) {
                    ProviderQuotaCard(tool: .codex, density: density, compact: false)
                        .overviewMasonryItem(id: "quota-codex", phase: .quota)
                }
                if isVisible(.claude) {
                    ProviderQuotaCard(tool: .claude, density: density, compact: false)
                        .overviewMasonryItem(id: "quota-claude", phase: .quota)
                }
                // Gemini Web and AntiGravity both roll up to the
                // Gemini product, so the Overview surface shows them
                // as a single L2 "Gemini" card with two L3 sub-sections
                // (`GeminiCombinedCard`). Grok stays on its own card.
                if isVisible(.gemini) {
                    GeminiCombinedCard(density: density)
                        .overviewMasonryItem(id: "quota-gemini", phase: .quota)
                }
                if isVisible(.grok) {
                    ProviderQuotaCard(tool: .grok, density: density, compact: false)
                        .overviewMasonryItem(id: "quota-grok", phase: .quota)
                }
                if hasCostData {
                    CostHistoryView(
                        tool: .codex,
                        snapshot: combinedCostSnapshot,
                        density: density,
                        chartHeight: density.overviewCostChartHeight,
                        titleOverride: "All Providers Cost History"
                    )
                    .overviewMasonryItem(id: "cost-all-providers", phase: .cost)
                }
                ForEach(overviewCostProviders, id: \.self) { tool in
                    OverviewCostCard(tool: tool, density: density)
                        .overviewMasonryItem(id: "cost-\(tool.rawValue)", phase: .cost)
                }
                // Google AI (Gemini + AntiGravity) cost, surfaced as the
                // single "Gemini" platform aligned with the other three.
                // AntiGravity is now the only live Google/Gemini usage
                // source (Gemini CLI no longer writes local telemetry);
                // its `.pb`-only cascades are filled via the
                // language-server RPC in CostUsageScanner.scanAntigravity.
                if isVisible(.gemini) {
                    OverviewCostCard(
                        tool: .antigravity,
                        density: density,
                        snapshotOverride: googleAICostSnapshot,
                        titleOverride: "Gemini Cost",
                        emptyMessageOverride: "No Gemini / AntiGravity usage yet — open AntiGravity once so Vibe Bar can sync it.",
                        toolNameOverride: "Gemini",
                        heatmapTitleOverride: "When you use Gemini"
                    )
                    .overviewMasonryItem(id: "cost-gemini", phase: .cost)
                }
                if hasCostData {
                    ModelRankingList(
                        breakdowns: combinedModels,
                        density: density,
                        subtitle: "All providers · all time"
                    )
                    .overviewMasonryItem(id: "analytics-model-ranking", phase: .auxiliary)
                    YearlyContributionHeatmapView(
                        history: combinedHistory,
                        density: density,
                        toolName: "All providers"
                    )
                    .overviewMasonryItem(id: "analytics-year", phase: .auxiliary)
                    UsageActivityView(
                        heatmap: combinedHeatmap,
                        density: density,
                        titleOverride: "When you use everything"
                    )
                    .overviewMasonryItem(id: "analytics-activity", phase: .auxiliary)
                }
            }
        }
    }

    /// Cost providers rendered as their own per-provider
    /// `OverviewCostCard` in the grid. Google AI is rendered separately
    /// (combined Gemini + AntiGravity) via `googleAICostSnapshot`, so it
    /// isn't listed here.
    private var overviewCostProviders: [ToolType] {
        [.codex, .claude, .grok].filter(isVisible)
    }

    private func isVisible(_ tool: ToolType) -> Bool {
        settingsStore.settings.isCoreProviderVisible(tool)
    }

    /// Combined Gemini + AntiGravity cost, surfaced as the single
    /// "Gemini" (Google AI) platform. Gemini CLI no longer writes local
    /// usage, so in practice this is the AntiGravity IDE/CLI data; the
    /// combine keeps any residual Gemini telemetry counted too. Returns
    /// an empty snapshot (no files) when neither has data, which the
    /// card renders as an empty state.
    private var googleAICostSnapshot: CostSnapshot {
        let parts = ToolType.googleAIPair.compactMap { environment.costService.snapshot(for: $0) }
        return CostSnapshotAggregator.combinedSnapshot(tool: .antigravity, snapshots: parts)
    }

    /// Snapshots feeding the "All providers" rollups (model ranking,
    /// heatmaps). Includes the combined Google AI snapshot when it has
    /// data so Gemini / AntiGravity usage shows up there too.
    private var overviewCostSnapshots: [CostSnapshot] {
        var snaps = overviewCostProviders.compactMap { environment.costService.snapshot(for: $0) }
        if isVisible(.gemini) {
            let googleAI = googleAICostSnapshot
            if googleAI.jsonlFilesFound > 0 { snaps.append(googleAI) }
        }
        return snaps
    }
}

private struct GrokPage: View {
    let density: Theme.Density

    var body: some View {
        ProviderDetailView(tool: .grok, density: density)
    }
}

/// Overview popover card that merges Gemini Web + AntiGravity into a
/// single L2 "Gemini" surface, with each tool as an L3 sub-section.
/// Replaces the previous side-by-side ProviderQuotaCard pair so the
/// two surfaces under the Gemini product no longer look like
/// unrelated tools to the user.
///
/// The card itself owns the outer card chrome; the inner
/// `ProviderQuotaCard`s render with `embedded: true` so they
/// contribute only the per-tool header + bucket list, not their
/// own rounded-rectangle background.
private struct GeminiCombinedCard: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let geminiAccounts = environment.accountStore
            .accounts(for: .gemini)
            .sorted { $0.id < $1.id }
        let anyGeminiInFlight = geminiAccounts.contains {
            quotaService.inFlightAccountIds.contains($0.id)
        }
        let antigravityAccount = environment.account(for: .antigravity)
        let antigravityInFlight = antigravityAccount.map {
            quotaService.inFlightAccountIds.contains($0.id)
        } ?? false
        let anyInFlight = anyGeminiInFlight || antigravityInFlight
        let geminiPlanBadge = planBadge(for: .gemini, accountIds: geminiAccounts.map(\.id))
        let antigravityPlanBadge = planBadge(
            for: .antigravity,
            accountIds: antigravityAccount.map { [$0.id] } ?? []
        )

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center, spacing: 8) {
                ProviderSectionTitle(
                    tool: .gemini,
                    title: ToolType.gemini.productName,
                    subtitle: ToolType.gemini.statusProviderName,
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16,
                    badgeSize: 24
                )
                Spacer(minLength: 4)
                if let label = geminiPlanBadge {
                    PlanBadgeView(
                        text: label,
                        fontSize: max(9, density.subtitleFontSize - 1)
                    )
                }
                BorderlessIconButton(
                    systemImage: "arrow.clockwise",
                    help: "Refresh Gemini Web + AntiGravity"
                ) {
                    environment.refresh(.gemini)
                    environment.refresh(.antigravity)
                }
                .disabled(anyInFlight)
                if anyInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            }

            // Gemini Web buckets ride directly under the main L2
            // header — no second sub-header needed because the card
            // title already reads "Gemini · Google" and the Web
            // surface is the primary one. AntiGravity gets its own
            // L3 sub-header below (logo + name + plan badge) so the
            // IDE-side model buckets are visibly separated from the
            // Web quota even though both live in the same card.
            ForEach(geminiAccounts, id: \.id) { account in
                ProviderQuotaCard(
                    tool: .gemini,
                    accountId: account.id,
                    density: density,
                    compact: false,
                    embedded: true
                )
            }
            if geminiAccounts.isEmpty {
                ProviderQuotaCard(
                    tool: .gemini,
                    density: density,
                    compact: false,
                    embedded: true
                )
            }

            HStack(alignment: .center, spacing: 6) {
                ToolBrandIconView(tool: .antigravity, size: 13)
                    .opacity(0.85)
                Text(ToolType.antigravity.toolName)
                    .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let label = antigravityPlanBadge {
                    PlanBadgeView(
                        text: label,
                        fontSize: max(8, density.subtitleFontSize - 2)
                    )
                }
            }
            .padding(.top, 4)

            ProviderQuotaCard(
                tool: .antigravity,
                density: density,
                compact: false,
                embedded: true
            )
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    /// Resolve the plan-badge text for a Gemini-family sub-tool. Looks
    /// at the cached quota first (jSf9Qc returns "Pro" / "Ultra" /
    /// "Free") and falls back to the account-level plan string. nil
    /// when nothing meaningful is set so the caller suppresses the
    /// badge instead of drawing an empty pill.
    private func planBadge(for tool: ToolType, accountIds: [String]) -> String? {
        let quotaPlan = accountIds
            .compactMap { quotaService.cachedQuota(for: $0)?.plan }
            .first
        let accountPlan = accountIds
            .compactMap { id in environment.accountStore.accounts.first(where: { $0.id == id })?.plan }
            .first
        let label = settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: quotaPlan,
            accountPlan: accountPlan
        )
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// The dedicated Gemini sub-page (still routed through `OverviewPage.googleAI`
/// for backwards-compat with the menu-bar settings, but labelled "Gemini" at
/// every user-facing surface). Two-column layout matching the OpenAI / Claude
/// sub-pages: quota + pace + status on the left, a "Cost · Coming soon"
/// placeholder on the right so the page width stays consistent with the
/// other Overview sub-pages while the IDE/CLI cost story is still being
/// validated.
private struct GeminiTabPage: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let geminiAccounts = environment.accountStore
            .accounts(for: .gemini)
            .sorted { $0.id < $1.id }
        let antigravityAccount = environment.account(for: .antigravity)
        let antigravityQuotaSeries: [FillTimelineSeries] = antigravityAccount.map { account in
            (quotaService.cachedQuota(for: account.id)?.buckets ?? []).map {
                FillTimelineSeries(tool: .antigravity, accountId: account.id, bucket: $0)
            }
        } ?? []

        HStack(alignment: .top, spacing: density.interSectionSpacing) {
            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                GeminiCombinedCard(density: density)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    SubscriptionUtilizationView(
                        tool: .gemini,
                        buckets: geminiAccounts.first.flatMap {
                            quotaService.cachedQuota(for: $0.id)?.buckets
                        } ?? [],
                        mode: settingsStore.displayMode,
                        density: density,
                        now: context.date,
                        additionalQuotaSeries: antigravityQuotaSeries
                    )
                }
                ServiceStatusCard(tools: [.gemini], density: density)
            }
            .frame(
                minWidth: geminiLeftColumnMinWidth,
                idealWidth: geminiLeftColumnIdealWidth,
                maxWidth: geminiLeftColumnMaxWidth,
                alignment: .topLeading
            )

            GeminiCostColumn(density: density)
                .frame(minWidth: geminiRightColumnMinWidth, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var geminiLeftColumnMinWidth: CGFloat {
        density.detailLeftColumnRange.lowerBound
    }

    private var geminiLeftColumnIdealWidth: CGFloat {
        min(
            density.detailLeftColumnRange.upperBound,
            max(geminiLeftColumnMinWidth, density.popoverWidth * density.detailLeftColumnFraction)
        )
    }

    private var geminiLeftColumnMaxWidth: CGFloat {
        density.detailLeftColumnRange.upperBound
    }

    private var geminiRightColumnMinWidth: CGFloat {
        density.detailRightColumnMinimum
    }
}

/// Right-column cost panel on the Gemini sub-page: the combined
/// Gemini + AntiGravity cost, presented as one "Gemini" surface so the
/// page matches the OpenAI / Claude sub-page cost columns. AntiGravity
/// is the live Google/Gemini usage source today; the data comes from
/// `CostUsageScanner.scanAntigravity` (offline `.db` + language-server
/// RPC for the encrypted `.pb` cascades).
private struct GeminiCostColumn: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        let parts = ToolType.googleAIPair.compactMap { environment.costService.snapshot(for: $0) }
        let snapshot = CostSnapshotAggregator.combinedSnapshot(tool: .antigravity, snapshots: parts)
        if snapshot.jsonlFilesFound > 0 {
            ProviderCostStack(
                tool: .antigravity,
                snapshot: snapshot,
                density: density,
                titleOverride: "Gemini Cost",
                toolNameOverride: "Gemini",
                heatmapTitleOverride: "When you use Gemini"
            )
        } else {
            GeminiCostEmptyCard(density: density)
        }
    }
}

/// Empty state for the Gemini sub-page cost column. AntiGravity's
/// `.pb`-only cascades are fetched from the running language server, so
/// the first sync needs AntiGravity open; the result is then cached and
/// survives Antigravity quitting.
private struct GeminiCostEmptyCard: View {
    let density: Theme.Density

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center, spacing: 8) {
                ProviderSectionTitle(
                    tool: .gemini,
                    title: "\(ToolType.gemini.productName) Cost",
                    subtitle: "No usage yet",
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16,
                    badgeSize: 24
                )
                Spacer(minLength: 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("No Gemini or AntiGravity usage found yet.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                Text("AntiGravity is the live Google/Gemini source. Open AntiGravity at least once while Vibe Bar is running so it can sync cascade usage from the language server; cached results then persist after you quit it.")
                    .font(.system(size: max(10, density.subtitleFontSize - 1)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(nil)
            }
            Spacer(minLength: 0)
        }
        .padding(density.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }
}

private struct ProviderCostStack: View {
    let tool: ToolType
    let snapshot: CostSnapshot
    let density: Theme.Density
    var titleOverride: String? = nil
    var toolNameOverride: String? = nil
    var heatmapTitleOverride: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            CostHeaderCard(
                tool: tool,
                snapshot: snapshot,
                density: density,
                titleOverride: titleOverride,
                toolNameOverride: toolNameOverride
            )
            CostHistoryView(
                tool: tool,
                snapshot: snapshot,
                density: density,
                chartHeight: density.detailCostChartHeight
            )
            ModelRankingList(snapshot: snapshot, density: density)
            YearlyContributionHeatmapView(
                history: snapshot.dailyHistory,
                density: density,
                toolName: toolNameOverride ?? tool.menuTitle
            )
            UsageActivityView(heatmap: snapshot.heatmap, density: density, titleOverride: heatmapTitleOverride)
        }
    }
}

/// Sits above the per-provider columns: cost and token summary on the left,
/// current provider status on the right. The two cards use equal columns so
/// the Overview header aligns with the waterfall below it.
private struct CombinedTotalsRow: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService
    @EnvironmentObject var settingsStore: SettingsStore
    var body: some View {
        // Headline totals span every cost-aware provider, including
        // Google AI (Gemini + AntiGravity): AntiGravity usage is now
        // captured offline (`.db`) and via the language-server RPC
        // (`.pb`), so it's reliable enough to roll up here.
        let visibleCostProviders = ToolType.costAwareProviders.filter {
            settingsStore.settings.isCoreProviderVisible($0)
        }
        let snapshots = visibleCostProviders
            .compactMap { environment.costService.snapshot(for: $0) }
        let dailyHistory = CostSnapshotAggregator.combinedDailyHistory(snapshots)
        let totalCost = snapshots.reduce(0.0) { $0 + $1.allTimeCostUSD }
        let todayCost = snapshots.reduce(0.0) { $0 + $1.todayCostUSD }
        let yesterdayCost = snapshots.reduce(0.0) { $0 + CostTimeframe.yesterday.cost(in: $1) }
        let weekCost = snapshots.reduce(0.0) { $0 + $1.last7DaysCostUSD }
        let monthCost = snapshots.reduce(0.0) { $0 + $1.last30DaysCostUSD }
        let totalTokens = snapshots.reduce(0) { $0 + $1.allTimeTokens }
        let todayTokens = snapshots.reduce(0) { $0 + $1.todayTokens }
        let yesterdayTokens = snapshots.reduce(0) { $0 + CostTimeframe.yesterday.tokens(in: $1) }
        let weekTokens = snapshots.reduce(0) { $0 + $1.last7DaysTokens }
        let monthTokens = snapshots.reduce(0) { $0 + $1.last30DaysTokens }
        // Pick the single day with the highest cost across all
        // providers, then surface both its cost and token totals so
        // the user sees what they spent *and* burned on their worst
        // day. Using `.max(by:)` rather than two separate `.max()`
        // calls keeps the two numbers from drifting onto different
        // days when token-heavy and dollar-heavy days disagree.
        let peakDayPoint = dailyHistory.max(by: { $0.costUSD < $1.costUSD })
        let peakDayCost = peakDayPoint?.costUSD ?? 0
        let peakDayTokens = peakDayPoint?.totalTokens ?? 0
        GeometryReader { geometry in
            let spacing = density.interSectionSpacing
            let availableWidth = max(0, geometry.size.width - spacing)
            let columnWidth = availableWidth / 2

            HStack(alignment: .top, spacing: spacing) {
                VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cost")
                        .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    Spacer()
                    if let lastRefreshed = costService.lastRefreshedAt {
                        Text(ResetCountdownFormatter.updatedAgo(from: lastRefreshed, now: Date()))
                            .font(.system(size: max(9, density.subtitleFontSize - 1)))
                            .foregroundStyle(.tertiary)
                    }
                    if costService.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    }
                    BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh cost data") {
                        environment.refreshCostUsage()
                    }
                    .disabled(costService.isRefreshing)
                }
                    // 4 × 3 summary: durable all-time/peak context first,
                    // followed by matching cost and token timeframes. The
                    // flexible gaps use the full height shared with Status,
                    // instead of leaving one empty band below the third row.
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            metric(label: "TOTAL COST", value: formatCost(totalCost), highlight: true)
                            divider
                            metric(label: "TOTAL TOK", value: formatTokens(totalTokens), highlight: true)
                            divider
                            metric(label: "PEAK DAY", value: formatCost(peakDayCost))
                            divider
                            metric(label: "PEAK DAY TOK", value: formatTokens(peakDayTokens))
                        }
                        Spacer(minLength: 8)
                        HStack(alignment: .top, spacing: 0) {
                            metric(label: "TODAY", value: formatCost(todayCost))
                            divider
                            metric(label: "YESTERDAY", value: formatCost(yesterdayCost))
                            divider
                            metric(label: "7-DAY", value: formatCost(weekCost))
                            divider
                            metric(label: "30-DAY", value: formatCost(monthCost))
                        }
                        Spacer(minLength: 8)
                        HStack(alignment: .top, spacing: 0) {
                            metric(label: "TODAY TOK", value: formatTokens(todayTokens))
                            divider
                            metric(label: "YESTERDAY TOK", value: formatTokens(yesterdayTokens))
                            divider
                            metric(label: "7-DAY TOK", value: formatTokens(weekTokens))
                            divider
                            metric(label: "30-DAY TOK", value: formatTokens(monthTokens))
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(density.cardPadding)
                .frame(
                    minWidth: columnWidth,
                    idealWidth: columnWidth,
                    maxWidth: columnWidth,
                    minHeight: density.overviewSummaryHeight,
                    idealHeight: density.overviewSummaryHeight,
                    maxHeight: density.overviewSummaryHeight,
                    alignment: .topLeading
                )
                .background(
                    RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                        .fill(.background.tertiary.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.4), lineWidth: 0.5)
                )

                OverviewStatusSummaryCard(
                    density: density,
                    minHeight: density.overviewSummaryHeight,
                    tools: ToolType.combinedStatusPageProviders.filter {
                        settingsStore.settings.isCoreProviderVisible($0)
                    }
                )
                    .frame(
                        minWidth: columnWidth,
                        idealWidth: columnWidth,
                        maxWidth: columnWidth,
                        alignment: .topLeading
                    )
            }
        }
        .frame(height: density.overviewSummaryHeight)
    }

    private var divider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func metric(label: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.system(
                    size: highlight ? density.bucketTitleFontSize + 1 : density.bucketTitleFontSize,
                    weight: highlight ? .bold : .semibold,
                    design: .rounded
                ).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value < 0.01 { return "$0.00" }
        if value < 100  { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.2fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func formatModelName(_ modelName: String?) -> String {
        guard let modelName, !modelName.isEmpty else { return "-" }
        if modelName.count <= 18 { return modelName }
        return "\(modelName.prefix(17))..."
    }
}

private struct OverviewStatusSummaryCard: View {
    let density: Theme.Density
    let minHeight: CGFloat
    let tools: [ToolType]

    @EnvironmentObject var serviceStatus: ServiceStatusController

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Status")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if let lastFetched = serviceStatus.lastFetched {
                    Text(ResetCountdownFormatter.updatedAgo(from: lastFetched, now: Date()))
                        .font(.system(size: max(9, density.subtitleFontSize - 1)))
                        .foregroundStyle(.tertiary)
                }
                if !serviceStatus.inFlight.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                }
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh service status") {
                    serviceStatus.refreshAll()
                }
                .disabled(!serviceStatus.inFlight.isEmpty)
            }
            if tools.isEmpty {
                Text("Enable a core provider in Settings to show service status.")
                    .font(.system(size: max(9, density.subtitleFontSize - 1)))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                let columnCount = min(2, max(1, tools.count))
                let rowCount = Int(ceil(Double(tools.count) / Double(columnCount)))
                let tileHeight = statusTileHeight(rowCount: rowCount)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: density.cardSpacing, alignment: .top),
                        count: columnCount
                    ),
                    alignment: .leading,
                    spacing: density.cardSpacing
                ) {
                    ForEach(tools, id: \.self) { tool in
                        providerStatusTile(tool, height: tileHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(density.cardPadding)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func statusTileHeight(rowCount: Int) -> CGFloat {
        let rows = max(1, rowCount)
        let headerHeight = max(18, density.bucketTitleFontSize + 6)
        let gridSpacing = CGFloat(max(0, rows - 1)) * density.cardSpacing
        let available = minHeight
            - density.cardPadding * 2
            - headerHeight
            - density.cardSpacing
            - gridSpacing
        let minimum: CGFloat
        switch density.profile {
        case .compact: minimum = 46
        case .regular: minimum = 58
        case .spacious: minimum = 70
        }
        return max(minimum, available / CGFloat(rows))
    }

    private func providerStatusTile(_ tool: ToolType, height: CGFloat) -> some View {
        let state = statusState(for: tool)
        let snapshot = statusSnapshot(for: tool)
        return VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(spacing: 7) {
                Image(systemName: state.iconName)
                    .font(.system(size: density.bucketTitleFontSize + 1, weight: .semibold))
                    .foregroundStyle(state.color)
                    .frame(width: 17, height: 17)
                ToolBrandIconView(tool: tool, size: density.bucketTitleFontSize + 6)
                    .opacity(0.9)
                    .frame(width: 22, height: 22)
                Text(statusTitle(for: tool))
                    .font(.system(size: density.subtitleFontSize + 1, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(state.label)
                    .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .semibold, design: .rounded))
                    .foregroundStyle(state.color)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(statusDetail(for: tool, snapshot: snapshot, state: state))
                    .font(.system(size: max(9, density.subtitleFontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let snapshot, snapshot.aggregateUptimePercent > 0 {
                    Text(String(format: "%.2f%%", snapshot.aggregateUptimePercent))
                        .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, density.cardPadding - 2)
        .padding(.vertical, max(6, density.cardPadding - 4))
        .frame(minHeight: height, maxHeight: height, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(state.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(state.color.opacity(0.18), lineWidth: 0.6)
        )
    }

    private func statusDetail(
        for tool: ToolType,
        snapshot: ServiceStatusSnapshot?,
        state: OverviewStatusState
    ) -> String {
        if statusInFlight(for: tool) { return "Refreshing" }
        if statusError(for: tool) != nil { return "Fetch failed" }
        if let incident = snapshot?.recentIncidents.first, !incident.isResolved {
            return incident.name
        }
        return snapshot?.description ?? state.detail
    }

    private func statusState(for tool: ToolType) -> OverviewStatusState {
        if statusInFlight(for: tool) {
            return .checking
        }
        if statusError(for: tool) != nil {
            return .down
        }
        guard let indicator = statusSnapshot(for: tool)?.indicator else {
            return .checking
        }
        switch indicator {
        case .none:
            return .up
        case .maintenance:
            return .maintenance
        case .minor, .major:
            // Partial degradation should not look like a hard outage. AQ
            // pointed out that an OpenAI page reporting a degraded sub-system
            // was rendering as the same red X we use for "fully down", which
            // overstated the severity. Reserve the red X for `.critical` only.
            return .degraded
        case .critical:
            return .down
        }
    }

    private func statusTitle(for tool: ToolType) -> String {
        // Service-status row always renders at the L1 vendor level —
        // the Gemini/AntiGravity pair both roll up to Google so the
        // shared status feed gets one "Google" header instead of two.
        tool.statusProviderName
    }

    private func statusSnapshot(for tool: ToolType) -> ServiceStatusSnapshot? {
        if tool == .gemini {
            return serviceStatus.snapshotByTool[.gemini]
                ?? serviceStatus.snapshotByTool[.antigravity]
        }
        return serviceStatus.snapshotByTool[tool]
    }

    private func statusInFlight(for tool: ToolType) -> Bool {
        if tool == .gemini {
            return serviceStatus.inFlight.contains(.gemini)
                || serviceStatus.inFlight.contains(.antigravity)
        }
        return serviceStatus.inFlight.contains(tool)
    }

    private func statusError(for tool: ToolType) -> String? {
        if tool == .gemini {
            if statusSnapshot(for: tool) != nil { return nil }
            return serviceStatus.errorByTool[.gemini]
                ?? serviceStatus.errorByTool[.antigravity]
        }
        return serviceStatus.errorByTool[tool]
    }
}

private enum OverviewStatusState {
    case up
    case degraded
    case down
    case checking
    case maintenance

    var label: String {
        switch self {
        case .up:          return "Up"
        case .degraded:    return "Degraded"
        case .down:        return "Down"
        case .checking:    return "Checking"
        case .maintenance: return "Maintenance"
        }
    }

    var iconName: String {
        switch self {
        case .up:          return "checkmark.circle.fill"
        case .degraded:    return "exclamationmark.triangle.fill"
        case .down:        return "xmark.octagon.fill"
        case .checking:    return "arrow.clockwise.circle.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        }
    }

    var detail: String {
        switch self {
        case .up:          return "Operational"
        case .degraded:    return "Partial outage"
        case .down:        return "Needs attention"
        case .checking:    return "Checking"
        case .maintenance: return "Maintenance"
        }
    }

    var color: Color {
        switch self {
        case .up:          return .green
        // Yellow-gold reads as "warning" without escalating to the red used
        // for full outages. Same tone the pace marker uses for "slightly
        // ahead" so the palette stays consistent.
        case .degraded:    return Color(red: 0.96, green: 0.72, blue: 0.20)
        case .down:        return .red
        case .checking:    return .blue
        case .maintenance: return .blue
        }
    }
}

/// Cost card for the Overview right column — full Cost History bar chart with
/// timeframe picker, plus a 4-column summary header. Tall enough to roughly
/// match the height of the left-column quota cards (~280pt by default).
private struct OverviewCostCard: View {
    let tool: ToolType
    let density: Theme.Density
    var snapshotOverride: CostSnapshot? = nil
    var titleOverride: String? = nil
    var emptyMessageOverride: String? = nil
    var toolNameOverride: String? = nil
    var heatmapTitleOverride: String? = nil

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService
    @State private var detailPresented: Bool = false

    var body: some View {
        let snapshot = snapshotOverride ?? environment.costService.snapshot(for: tool)
        let title = titleOverride ?? "\(tool.menuTitle) Cost"
        let toolName = toolNameOverride ?? tool.menuTitle
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center) {
                ProviderSectionTitle(
                    tool: tool,
                    title: title,
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 15,
                    badgeSize: 22
                )
                Spacer(minLength: 4)
                if costService.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                }
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh \(toolName) cost") {
                    environment.refreshCostUsage()
                }
                .disabled(costService.isRefreshing)
                if snapshot != nil {
                    Button {
                        detailPresented = true
                    } label: {
                        Image(systemName: "rectangle.expand.vertical")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(.secondary)
                    .help("Open full charts")
                    .popover(isPresented: $detailPresented, arrowEdge: .trailing) {
                        CostDetailPopoverContent(
                            tool: tool,
                            density: density,
                            snapshotOverride: snapshot,
                            titleOverride: "\(title) — Full Charts",
                            toolNameOverride: toolName,
                            heatmapTitleOverride: heatmapTitleOverride
                        )
                            .frame(width: max(660, density.popoverWidth * 0.70), height: 660)
                    }
                }
            }
            if let snapshot, snapshot.jsonlFilesFound > 0 {
                CostSummaryRow(snapshot: snapshot, density: density)
                TopModelTile(snapshot: snapshot, density: density)
                CostHistoryView(
                    tool: tool,
                    snapshot: snapshot,
                    density: density,
                    chartHeight: density.detailCostChartHeight
                )
                    .padding(.top, 2)
            } else {
                Text(emptyMessageOverride ?? emptyMessage)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var emptyMessage: String {
        switch tool {
        case .codex:  return "No Codex CLI sessions found yet."
        case .claude: return "No Claude CLI sessions found yet."
        case .gemini: return "No Gemini CLI or chat-history usage found yet."
        case .antigravity: return "No Antigravity conversation token metadata found yet."
        case .grok: return "No Grok Build session usage found yet."
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers' empty cost-history view shouldn't be
            // reachable (cost cards are gated on
            // `tool.supportsTokenCost`), but render a graceful
            // fallback if it ever is.
            return "Cost history isn't tracked for \(tool.menuTitle)."
        }
    }
}

/// Detail popover surfaced when the user clicks the expand button on an
/// Overview cost card. Contains the yearly contribution heatmap + weekday-hour
/// heatmap + hourly burn rate.
private struct CostDetailPopoverContent: View {
    let tool: ToolType
    let density: Theme.Density
    var snapshotOverride: CostSnapshot? = nil
    var titleOverride: String? = nil
    var toolNameOverride: String? = nil
    var heatmapTitleOverride: String? = nil

    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        let snapshot = snapshotOverride ?? environment.costService.snapshot(for: tool)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                HStack(alignment: .center) {
                    ProviderSectionTitle(
                        tool: tool,
                        title: titleOverride ?? "\(tool.menuTitle) Cost — Full Charts",
                        titleFontSize: density.titleFontSize,
                        subtitleFontSize: density.subtitleFontSize,
                        iconSize: 15,
                        badgeSize: 22
                    )
                    Spacer()
                    if let updated = snapshot?.updatedAt {
                        Text(updated, style: .relative)
                            .font(.system(size: density.subtitleFontSize))
                            .foregroundStyle(.secondary)
                    }
                }
                if let snap = snapshot {
                    YearlyContributionHeatmapView(
                        history: snap.dailyHistory,
                        density: density,
                        toolName: toolNameOverride ?? tool.menuTitle
                    )
                    UsageActivityView(heatmap: snap.heatmap, density: density, titleOverride: heatmapTitleOverride)
                }
            }
            .padding(density.cardPadding)
        }
    }
}

// MARK: - Single-provider detail (two-column waterfall)

/// Single-provider popover content. Two-column layout — narrow left for the
/// live subscription panels, wider right for cost charts and heatmaps. The
/// two columns size independently and do NOT have to match in height.
///
/// Left column (fixed order, narrow):
///   1. Quota / Usage bar
///   2. Subscription Utilization
///   3. Service Status
///
/// Right column (wide): Cost summary card (TODAY / 7D / 30D / ALL + Top
/// Model) → Cost History → Model Ranking → yearly contribution heatmap →
/// weekday-hour heatmap → hourly burn rate.
///
/// AQ tried the cost summary on the left and decided it looked off there;
/// the entire cost section now lives on the right with the rest of the
/// charts, where the wider column suits its grid of metrics.
private struct ProviderDetailView: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let snapshot = environment.costService.snapshot(for: tool)
        let hasCostData = (snapshot?.jsonlFilesFound ?? 0) > 0
        HStack(alignment: .top, spacing: density.interSectionSpacing) {
            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                ProviderQuotaCard(tool: tool, density: density, compact: false)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    SubscriptionUtilizationView(
                        tool: tool,
                        buckets: environment.quota(for: tool)?.buckets ?? [],
                        mode: settingsStore.displayMode,
                        density: density,
                        now: context.date
                    )
                }
                ServiceStatusCard(tools: [tool], density: density)
            }
            .frame(
                minWidth: leftColumnMinWidth,
                idealWidth: leftColumnIdealWidth,
                maxWidth: leftColumnMaxWidth,
                alignment: .topLeading
            )

            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                if let snapshot, hasCostData {
                    CostHeaderCard(tool: tool, snapshot: snapshot, density: density)
                    CostHistoryView(
                        tool: tool,
                        snapshot: snapshot,
                        density: density,
                        chartHeight: density.detailCostChartHeight
                    )
                    ModelRankingList(snapshot: snapshot, density: density)
                    YearlyContributionHeatmapView(history: snapshot.dailyHistory, density: density, toolName: tool.menuTitle)
                    UsageActivityView(heatmap: snapshot.heatmap, density: density)
                } else {
                    Text("No \(tool.menuTitle) CLI sessions found yet.")
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(minWidth: rightColumnMinWidth, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var leftColumnMinWidth: CGFloat {
        density.detailLeftColumnRange.lowerBound
    }

    private var leftColumnIdealWidth: CGFloat {
        min(
            density.detailLeftColumnRange.upperBound,
            max(leftColumnMinWidth, density.popoverWidth * density.detailLeftColumnFraction)
        )
    }

    private var leftColumnMaxWidth: CGFloat {
        density.detailLeftColumnRange.upperBound
    }

    private var rightColumnMinWidth: CGFloat {
        density.detailRightColumnMinimum
    }
}

/// Composite Cost header for the right column: 4-cell summary row + Top Model.
/// Bundled so the right column has clear "this is the cost section" framing
/// before the chart starts.
private struct CostHeaderCard: View {
    let tool: ToolType
    let snapshot: CostSnapshot
    let density: Theme.Density
    var titleOverride: String? = nil
    var toolNameOverride: String? = nil

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center) {
                ProviderSectionTitle(
                    tool: tool,
                    title: titleOverride ?? "\(tool.menuTitle) Cost",
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 15,
                    badgeSize: 22
                )
                Spacer()
                Text(snapshot.updatedAt, style: .relative)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                if costService.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                }
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh \(toolNameOverride ?? tool.menuTitle) cost") {
                    environment.refreshCostUsage()
                }
                .disabled(costService.isRefreshing)
            }
            CostSummaryRow(snapshot: snapshot, density: density)
            TopModelTile(snapshot: snapshot, density: density)
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }
}

// MARK: - Provider quota card

private struct ExtraGroup: Identifiable {
    let title: String
    var buckets: [QuotaBucket]
    var id: String { title }
}

private func groupExtraBuckets(_ buckets: [QuotaBucket]) -> [ExtraGroup] {
    var seen: [String: Int] = [:]
    var out: [ExtraGroup] = []
    for bucket in buckets {
        let title = bucket.groupTitle ?? "Other"
        if let idx = seen[title] {
            out[idx].buckets.append(bucket)
        } else {
            seen[title] = out.count
            out.append(ExtraGroup(title: title, buckets: [bucket]))
        }
    }
    return out
}

/// Provider quota card. Renders all top-level buckets, then any grouped
/// (Additional Features) buckets, then live extras (credits / overage) at the
/// bottom — Extras is no longer its own tab.
///
/// When `accountId` is non-nil the card targets that specific account
/// (used by Gemini Web, where `.gemini` has a dedicated `web-gemini`
/// account). The default — `accountId == nil` — falls
/// back to "first account for this tool", which is the single-account
/// behaviour every other provider uses today.
struct ProviderQuotaCard: View {
    let tool: ToolType
    var accountId: String?
    let density: Theme.Density
    /// When true, only the headline (no-group) buckets are rendered. Used in
    /// Overview where 3 cards are stacked. Single-provider popovers pass `false`
    /// so every bucket appears (Sonnet, Designs, Daily Routines, …).
    var compact: Bool = false
    /// When true, drop the outer rounded-rectangle chrome so the card can
    /// be nested inside a larger container (the unified Gemini card uses
    /// this to host Gemini Web + AntiGravity as L3 sub-sections inside a
    /// single L2 Gemini surface).
    var embedded: Bool = false

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let account: AccountIdentity? = {
            if let accountId {
                return environment.accountStore.accounts.first { $0.id == accountId }
            }
            return environment.account(for: tool)
        }()
        let quota: AccountQuota? = {
            if let account, let cached = quotaService.cachedQuota(for: account.id) {
                return cached
            }
            return accountId == nil ? environment.quota(for: tool) : nil
        }()
        let liveError = displayableError(
            account.flatMap { quotaService.lastErrorByAccount[$0.id] },
            with: quota
        )
        let isProviderRefreshing = account.map { quotaService.inFlightAccountIds.contains($0.id) } == true
        let planBadge = settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: quota?.plan,
            accountPlan: account?.plan
        )
        let cardTitle = (accountId != nil ? account?.alias : nil) ?? tool.menuTitle
        let cardSubtitle: String = {
            guard accountId != nil else { return tool.subtitle }
            switch account?.source {
            case .webCookie: return "gemini.google.com · current + weekly"
            default: return tool.subtitle
            }
        }()

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            // The embedded variant lives inside a parent container
            // (e.g. GeminiCombinedCard) that already owns the L2
            // title + per-provider refresh. Rendering ProviderSectionTitle
            // again here produced two "Gemini" headers stacked on top of
            // each other — drop the inner header so the parent's title
            // is the only label.
            if !embedded {
                HStack(alignment: .center, spacing: 8) {
                    ProviderSectionTitle(
                        tool: tool,
                        title: cardTitle,
                        subtitle: cardSubtitle,
                        titleFontSize: density.titleFontSize,
                        subtitleFontSize: density.subtitleFontSize,
                        iconSize: 16,
                        badgeSize: 24
                    )
                    Spacer(minLength: 4)
                    if planBadge?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        PlanBadgeView(
                            text: planBadge,
                            fontSize: max(9, density.subtitleFontSize - 1)
                        )
                    }
                    BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                        environment.refresh(tool)
                    }
                    .disabled(isProviderRefreshing)
                    if isProviderRefreshing {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    }
                }
            }

            if let quota, !quota.buckets.isEmpty {
                bucketContent(quota.buckets, accountId: account?.id)
                if tool == .codex, let credits = quota.resetCredits, credits.availableCount > 0 {
                    ResetCreditsRow(credits: credits, density: density)
                }
                if let liveError {
                    messageRow(text: "Update failed: \(liveError.userFacingMessage)", color: .orange)
                }
            } else if let liveError {
                messageRow(text: liveError.userFacingMessage, color: .orange)
            } else {
                messageRow(text: emptyMessage, color: .secondary)
            }
        }
        .padding(embedded ? 0 : density.cardPadding)
        .background(
            embedded
                ? AnyView(Color.clear)
                : AnyView(
                    RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                        .fill(.background.tertiary.opacity(0.6))
                )
        )
        .overlay(
            embedded
                ? AnyView(EmptyView())
                : AnyView(
                    RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    private func bucketContent(_ buckets: [QuotaBucket], accountId: String?) -> some View {
        let primary = buckets.filter { $0.groupTitle == nil }
        let extras = buckets.filter { $0.groupTitle != nil }
        return VStack(alignment: .leading, spacing: density.bucketGroupSpacing) {
            if !primary.isEmpty {
                ForEach(primary) { bucket in
                    ProviderBucketRow(
                        tool: tool,
                        accountId: accountId,
                        bucket: bucket,
                        mode: settingsStore.displayMode,
                        density: density
                    )
                }
            }
            if !compact, !extras.isEmpty {
                let groups = groupExtraBuckets(extras)
                ForEach(Array(groups.enumerated()), id: \.element.id) { _, group in
                    // Soft hairline before every model group — separates Sonnet
                    // from Designs from Daily Routines without overwhelming the
                    // card visually.
                    Divider()
                        .opacity(0.18)
                        .padding(.vertical, 1)
                    VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
                        Text(group.title)
                            .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.4)
                        ForEach(group.buckets) { bucket in
                            ProviderBucketRow(
                                tool: tool,
                                accountId: accountId,
                                bucket: bucket,
                                mode: settingsStore.displayMode,
                                density: density
                            )
                        }
                    }
                }
            } else if compact, !extras.isEmpty {
                Text("\(extras.count) per-model limit\(extras.count == 1 ? "" : "s") · open \(tool.menuTitle) for details")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyMessage: String {
        switch tool {
        case .codex:  return "Run codex login, then refresh."
        case .claude: return "Run claude login, then refresh."
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .grok, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers route through the Misc page's per-card
            // setup CTA. This empty-message path is only reachable from
            // a primary-provider detail view, but cover misc cases
            // defensively in case a future change reuses the helper.
            return "Configure \(tool.menuTitle) in Settings → Misc Providers."
        }
    }

    private func messageRow(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(color)
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(color)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func displayableError(_ error: QuotaError?, with quota: AccountQuota?) -> QuotaError? {
        guard let error else { return nil }
        // A credential route can disappear temporarily when an account source
        // reloads, even though the last successful quota remains complete and
        // usable until its next reset. Do not turn that transient routing state
        // into a large orange error inside an otherwise healthy quota card.
        // Settings still exposes the live route-health result, while network
        // and response-format failures continue to surface here.
        guard error.isCredentialState,
              let quota,
              !quota.buckets.isEmpty
        else {
            return error
        }
        return nil
    }
}

/// Codex "Limit reset credits" — manual rate-limit resets the user can spend,
/// with the next expiry when the dedicated endpoint surfaced it. Only rendered
/// when at least one reset is available.
private struct ResetCreditsRow: View {
    let credits: CodexResetCredits
    let density: Theme.Density

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.secondary)
                Text("Limit reset credits")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(credits.availableCount)")
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.green)
            }
            Text(subtitle)
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        let noun = credits.availableCount == 1 ? "manual reset available" : "manual resets available"
        if let expiry = credits.nextExpiresAt,
           let countdown = ResetCountdownFormatter.string(from: expiry, now: Date()) {
            return "\(credits.availableCount) \(noun) · next expires in \(countdown)"
        }
        return "\(credits.availableCount) \(noun)"
    }
}

private struct ProviderBucketRow: View {
    let tool: ToolType
    let accountId: String?
    let bucket: QuotaBucket
    let mode: DisplayMode
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        // We only refresh "resets in …" periodically, but we don't repaint
        // the entire bucket row at that cadence — only the strings that depend
        // on `now`. The displayed countdown is minute-granular, so 30 seconds
        // keeps it fresh without making popover open/close fight row updates.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let percent = bucket.displayPercent(mode)
        let pace = UsagePace.compute(bucket: bucket, now: now)
        let forecast = paceForecast(now: now)
        let expectedDisplayed = forecast.map { displayedPlan($0) }
            ?? pace.map { expectedDisplay(for: $0, mode: mode) }
        let forecastRange = forecast.map { displayedRange($0) }
        let forecastMedian = forecast.map { displayedForecast($0) }
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                if let resetAt = bucket.resetAt,
                   let reset = ResetCountdownFormatter.string(from: resetAt, now: now) {
                    Text("resets in \(reset)")
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.barColor(percent: percent, mode: mode))
            }
            if let expectedDisplayed {
                PaceMarkerCapsule(
                    usedPercent: percent,
                    expectedPercent: expectedDisplayed,
                    mode: mode,
                    height: density.bucketBarHeight,
                    forecastLowerPercent: forecastRange?.lowerBound,
                    forecastUpperPercent: forecastRange?.upperBound,
                    forecastMedianPercent: forecastMedian
                )
            } else {
                QuotaBarShape(percent: percent, mode: mode, height: density.bucketBarHeight)
            }
            if let forecast {
                QuotaForecastRow(
                    forecast: forecast,
                    now: now,
                    fontSize: density.resetCountdownFontSize
                )
            } else if let pace {
                UsagePaceRow(pace: pace, now: now, fontSize: density.resetCountdownFontSize)
            }
        }
    }

    private func paceForecast(now: Date) -> QuotaPaceForecast? {
        guard let resolvedAccountId = accountId ?? environment.account(for: tool)?.id else { return nil }
        let snapshot = environment.costService.snapshot(for: tool)
        return quotaService.paceForecast(
            accountId: resolvedAccountId,
            bucket: bucket,
            activityHeatmap: snapshot?.heatmap,
            dailyActivity: snapshot?.dailyHistory ?? [],
            now: now
        )
    }

    private func displayedPlan(_ forecast: QuotaPaceForecast) -> Double {
        switch mode {
        case .used: forecast.plannedUsedPercent
        case .remaining: 100 - forecast.plannedUsedPercent
        }
    }

    private func displayedForecast(_ forecast: QuotaPaceForecast) -> Double {
        switch mode {
        case .used: forecast.projectedUsedPercent
        case .remaining: 100 - forecast.projectedUsedPercent
        }
    }

    private func displayedRange(_ forecast: QuotaPaceForecast) -> ClosedRange<Double> {
        switch mode {
        case .used:
            return forecast.projectedUsedLowerPercent...forecast.projectedUsedUpperPercent
        case .remaining:
            return (100 - forecast.projectedUsedUpperPercent)...(100 - forecast.projectedUsedLowerPercent)
        }
    }

    private func expectedDisplay(for pace: UsagePace, mode: DisplayMode) -> Double {
        switch mode {
        case .used:      return pace.expectedUsedPercent
        case .remaining: return 100 - pace.expectedUsedPercent
        }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}
