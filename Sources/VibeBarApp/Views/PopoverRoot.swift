import SwiftUI
import AppKit
import VibeBarCore

/// Top-level popover content. Each menu bar item kind opens its own popover.
///
/// - `.compact` → Overview: a wide provider-column waterfall with a small
///   page switcher for all-provider and single-provider views.
/// - `.codex` / `.claude` → single-provider detail waterfall.
/// - `.status` → service status only.
struct PopoverRoot: View {
    let kind: MenuBarItemKind
    let width: CGFloat
    let closePopover: () -> Void
    let onContentHeightChange: (CGFloat) -> Void
    let onToggleMiniWindow: () -> Void

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService
    @State private var overviewPage: OverviewPage = .overview
    @State private var autoRefreshedPageKeys: Set<String> = []

    var body: some View {
        let density = activeDensity
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            HeaderView(
                title: headerTitle,
                subtitle: headerSubtitle,
                plan: headerPlan,
                lastUpdated: latestUpdated,
                isRefreshing: isRefreshing,
                titleFontSize: density.titleFontSize + 2,
                subtitleFontSize: density.subtitleFontSize,
                accessory: kind == .compact
                    ? AnyView(OverviewPageSwitch(selection: $overviewPage, density: density))
                    : nil,
                onRefresh: { environment.refreshAll() },
                onToggleMiniWindow: onToggleMiniWindow,
                onShowSettings: { environment.showSettingsWindow() }
            )
            Divider().opacity(0.3)
            ScrollView(.vertical, showsIndicators: false) {
                content(density: density)
                    .padding(.bottom, 4)
            }
            .frame(maxHeight: maxScrollHeight)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, density.popoverPaddingV)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .readHeight(onContentHeightChange)
        .onAppear(perform: refreshVisibleProvidersIfNeeded)
        .onChange(of: overviewPage) { _, _ in
            refreshVisibleProvidersIfNeeded()
        }
    }

    /// Resolves the "logical" menu bar kind for the current view. When the
    /// overview popover sits on a sub-page (Claude / OpenAI), every kind-keyed
    /// piece of state — density preference, header title/subtitle/plan,
    /// `visibleTools` — is taken from the matching dedicated kind so the
    /// rendering is byte-for-byte consistent with what the user would see if
    /// they had opened that provider's menu bar item directly.
    private var effectiveKind: MenuBarItemKind {
        switch kind {
        case .compact:
            switch overviewPage {
            case .overview: return .compact
            case .claude:   return .claude
            case .openAI:   return .codex
            case .misc:     return .compact
            }
        default:
            return kind
        }
    }

    private var activeDensity: Theme.Density {
        let popDens = settingsStore.settings.popoverDensity(for: effectiveKind)
        switch effectiveKind {
        case .compact:
            return Theme.overviewDensity(for: popDens)
        case .codex, .claude:
            return Theme.detailDensity(for: popDens)
        case .status:
            return Theme.density(for: popDens)
        }
    }

    private var maxScrollHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, visible - 150)
    }

    @ViewBuilder
    private func content(density: Theme.Density) -> some View {
        switch kind {
        case .compact:
            switch overviewPage {
            case .overview:
                OverviewWaterfall(density: density)
            case .claude:
                ProviderDetailView(tool: .claude, density: density)
            case .openAI:
                ProviderDetailView(tool: .codex, density: density)
            case .misc:
                MiscProvidersPage(density: density)
            }
        case .codex:
            ProviderDetailView(tool: .codex, density: density)
        case .claude:
            ProviderDetailView(tool: .claude, density: density)
        case .status:
            // Status card only renders providers that actually publish
            // an Atlassian-style status feed — misc providers don't.
            ServiceStatusCard(tools: ToolType.primaryProviders)
        }
    }

    private var headerTitle: String {
        if kind == .compact, overviewPage == .misc {
            return "Misc Providers"
        }
        switch effectiveKind {
        case .compact: return "Overview"
        case .codex:   return "OpenAI"
        case .claude:  return "Claude"
        case .status:  return "Service Status"
        }
    }

    private var headerSubtitle: String? {
        if kind == .compact, overviewPage == .misc {
            return "Usage-only · sign in or paste a key"
        }
        switch effectiveKind {
        case .compact: return "All providers · quota & cost"
        case .codex:   return ToolType.codex.subtitle
        case .claude:  return ToolType.claude.subtitle
        case .status:  return "Live status pages"
        }
    }

    private var headerPlan: String? {
        // Always check `kind` here (not `effectiveKind`). The Overview popover
        // sits between the page switcher and the refresh / settings buttons,
        // so any extra accessory in that header band gets in the user's way
        // when they're trying to switch tabs. AQ explicitly does not want a
        // plan badge to appear in Overview, even when the active sub-page is
        // Claude or OpenAI. Dedicated provider popovers still show it.
        switch kind {
        case .compact, .status: return nil
        case .codex:   return planBadgeLabel(for: .codex)
        case .claude:  return planBadgeLabel(for: .claude)
        }
    }

    private var visibleTools: [ToolType] {
        // Header timestamps and refresh state aggregate the providers
        // visible in the current popover. The Misc subpage owns its
        // eight usage-only integrations; the normal Overview and Status
        // surfaces continue to aggregate just the primary providers.
        if kind == .compact, overviewPage == .misc {
            return ToolType.miscProviders
        }
        switch effectiveKind {
        case .compact, .status: return ToolType.primaryProviders
        case .codex:            return [.codex]
        case .claude:           return [.claude]
        }
    }

    private var latestUpdated: Date? {
        visibleTools
            .compactMap { environment.account(for: $0) }
            .compactMap { quotaService.lastUpdatedByAccount[$0.id] }
            .max()
    }

    private var isRefreshing: Bool {
        let ids = visibleTools
            .compactMap { environment.account(for: $0)?.id }
        return ids.contains { quotaService.inFlightAccountIds.contains($0) }
    }

    private func planBadgeLabel(for tool: ToolType) -> String? {
        settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: environment.quota(for: tool)?.plan,
            accountPlan: environment.account(for: tool)?.plan
        )
    }

    private var autoRefreshKey: String {
        "\(kind.rawValue):\(overviewPage.rawValue)"
    }

    private func refreshVisibleProvidersIfNeeded() {
        let key = autoRefreshKey
        guard !autoRefreshedPageKeys.contains(key) else { return }
        let accounts = visibleTools.compactMap { environment.account(for: $0) }
        let missing = accounts.filter { account in
            quotaService.cachedQuota(for: account.id) == nil
                && quotaService.lastErrorByAccount[account.id] == nil
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
    case misc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .openAI:   return "OpenAI"
        case .claude:   return "Claude"
        case .misc:     return "Misc"
        }
    }

    var menuBarKind: MenuBarItemKind {
        switch self {
        case .overview: return .compact
        case .openAI:   return .codex
        case .claude:   return .claude
        case .misc:     return .compact
        }
    }
}

private struct OverviewPageSwitch: View {
    @Binding var selection: OverviewPage
    let density: Theme.Density

    var body: some View {
        HStack(spacing: 3) {
            ForEach(OverviewPage.allCases) { page in
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
    }
}

private struct OverviewSwitchIcon: View {
    let page: OverviewPage
    let isSelected: Bool

    var body: some View {
        Group {
            if page == .misc {
                // Misc gets a generic "more" glyph — the misc tab
                // covers eight providers so no single brand icon is
                // a fair representative.
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
            } else {
                ProviderBrandIconView(kind: page.menuBarKind, size: page == .overview ? 14 : 13)
            }
        }
        .opacity(isSelected ? 1 : 0.72)
        .frame(width: 18, height: 16, alignment: .center)
    }
}

/// Overview popover content, top-to-bottom:
///   1. `CombinedTotalsRow` — cost+token grid plus live service status.
///   2. A `ColumnMasonryLayout` covering everything else. The first two
///      subviews — OpenAI Quota and Claude Quota — are anchored to the top
///      of columns 0 and 1 respectively (AQ wants the quota cards locked in
///      place). Every subsequent card flows into whichever column is
///      currently shorter, so the empty space below the shorter quota card
///      gets filled by Cost / Model Ranking / heatmap cards instead of left
///      blank. The cost and summary cards therefore drift between columns
///      based on how the heights work out — this is intentional.
private struct OverviewWaterfall: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        let snapshots = ToolType.primaryProviders.compactMap { environment.costService.snapshot(for: $0) }
        let combinedHistory = CostSnapshotAggregator.combinedDailyHistory(snapshots)
        let combinedHeatmap = CostSnapshotAggregator.combinedHeatmap(snapshots)
        let combinedModels = CostSnapshotAggregator.combinedModelBreakdowns(snapshots)
        let hasCostData = snapshots.contains { $0.jsonlFilesFound > 0 }

        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            CombinedTotalsRow(density: density)
            ColumnMasonryLayout(
                columns: 2,
                spacing: density.interSectionSpacing,
                anchoredItems: 2
            ) {
                ProviderQuotaCard(tool: .codex, density: density, compact: false)
                ProviderQuotaCard(tool: .claude, density: density, compact: false)
                ForEach(ToolType.primaryProviders, id: \.self) { tool in
                    OverviewCostCard(tool: tool, density: density)
                }
                if hasCostData {
                    ModelRankingList(
                        breakdowns: combinedModels,
                        density: density,
                        subtitle: "All providers · all time"
                    )
                    YearlyContributionHeatmapView(
                        history: combinedHistory,
                        density: density,
                        toolName: "All providers"
                    )
                    UsageHeatmapView(
                        heatmap: combinedHeatmap,
                        density: density,
                        titleOverride: "When you use everything"
                    )
                    UsageRateView(
                        heatmap: combinedHeatmap,
                        density: density
                    )
                }
            }
        }
    }
}

/// Sits above the per-provider columns: eight usage metrics in two rows on the
/// left and current provider status on the right. Both halves get their own
/// refresh button so the user can pull just-this-card data without firing the
/// global header refresh.
private struct CombinedTotalsRow: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService
    private let summaryHeight: CGFloat = 134

    var body: some View {
        let snapshots = ToolType.primaryProviders.compactMap { environment.costService.snapshot(for: $0) }
        let totalCost = snapshots.reduce(0.0) { $0 + $1.allTimeCostUSD }
        let todayCost = snapshots.reduce(0.0) { $0 + $1.todayCostUSD }
        let weekCost = snapshots.reduce(0.0) { $0 + $1.last7DaysCostUSD }
        let monthCost = snapshots.reduce(0.0) { $0 + $1.last30DaysCostUSD }
        let totalTokens = snapshots.reduce(0) { $0 + $1.allTimeTokens }
        let todayTokens = snapshots.reduce(0) { $0 + $1.todayTokens }
        let weekTokens = snapshots.reduce(0) { $0 + $1.last7DaysTokens }
        let totalFiles = snapshots.reduce(0) { $0 + $1.jsonlFilesFound }

        HStack(alignment: .top, spacing: density.interSectionSpacing) {
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
                HStack(alignment: .top, spacing: 0) {
                    metric(label: "TOTAL COST", value: formatCost(totalCost), highlight: true)
                    divider
                    metric(label: "TODAY", value: formatCost(todayCost))
                    divider
                    metric(label: "7-DAY", value: formatCost(weekCost))
                    divider
                    metric(label: "30-DAY", value: formatCost(monthCost))
                }
                HStack(alignment: .top, spacing: 0) {
                    metric(label: "TOTAL TOK", value: formatTokens(totalTokens), highlight: true)
                    divider
                    metric(label: "TODAY TOK", value: formatTokens(todayTokens))
                    divider
                    metric(label: "7-DAY TOK", value: formatTokens(weekTokens))
                    divider
                    metric(label: "SESSIONS", value: "\(totalFiles)")
                }
            }
            .padding(density.cardPadding)
            .frame(maxWidth: .infinity, minHeight: summaryHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .fill(.background.tertiary.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .stroke(.separator.opacity(0.4), lineWidth: 0.5)
            )

            OverviewStatusSummaryCard(density: density)
                .frame(maxWidth: .infinity, minHeight: summaryHeight, alignment: .topLeading)
        }
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

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100  { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.2fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

private struct OverviewStatusSummaryCard: View {
    let density: Theme.Density

    @EnvironmentObject var serviceStatus: ServiceStatusController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            HStack(spacing: 8) {
                // Only providers with an Atlassian-style status feed
                // belong here — misc providers don't publish one.
                ForEach(ToolType.primaryProviders, id: \.self) { tool in
                    providerStatusTile(tool)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(density.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 134, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func providerStatusTile(_ tool: ToolType) -> some View {
        let state = statusState(for: tool)
        let snapshot = serviceStatus.snapshotByTool[tool]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: state.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.color)
                ToolBrandIconView(tool: tool, size: 16)
                    .opacity(0.9)
                    .frame(width: 18, height: 18)
                Text(tool.statusProviderName)
                    .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 54, alignment: .center)
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
        if serviceStatus.inFlight.contains(tool) { return "Refreshing" }
        if serviceStatus.errorByTool[tool] != nil { return "Fetch failed" }
        if let incident = snapshot?.recentIncidents.first, !incident.isResolved {
            return incident.name
        }
        return snapshot?.description ?? state.detail
    }

    private func statusState(for tool: ToolType) -> OverviewStatusState {
        if serviceStatus.inFlight.contains(tool) {
            return .checking
        }
        if serviceStatus.errorByTool[tool] != nil {
            return .down
        }
        guard let indicator = serviceStatus.snapshotByTool[tool]?.indicator else {
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

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService
    @State private var detailPresented: Bool = false

    var body: some View {
        let snapshot = environment.costService.snapshot(for: tool)
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center) {
                ProviderSectionTitle(
                    tool: tool,
                    title: "\(tool.menuTitle) Cost",
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
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh \(tool.menuTitle) cost") {
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
                        CostDetailPopoverContent(tool: tool, density: density)
                            .frame(width: max(660, density.popoverWidth * 0.70), height: 660)
                    }
                }
            }
            if let snapshot, snapshot.jsonlFilesFound > 0 {
                CostSummaryRow(snapshot: snapshot, density: density)
                TopModelTile(snapshot: snapshot, density: density)
                CostHistoryView(tool: tool, snapshot: snapshot, density: density, chartHeight: 160)
                    .padding(.top, 2)
            } else {
                Text(emptyMessage)
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
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine:
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

    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        let snapshot = environment.costService.snapshot(for: tool)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                HStack(alignment: .center) {
                    ProviderSectionTitle(
                        tool: tool,
                        title: "\(tool.menuTitle) Cost — Full Charts",
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
                    YearlyContributionHeatmapView(history: snap.dailyHistory, density: density, toolName: tool.menuTitle)
                    UsageHeatmapView(heatmap: snap.heatmap, density: density)
                    UsageRateView(heatmap: snap.heatmap, density: density)
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
                ServiceStatusCard(tools: [tool])
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
                        chartHeight: 160
                    )
                    ModelRankingList(snapshot: snapshot, density: density)
                    YearlyContributionHeatmapView(history: snapshot.dailyHistory, density: density, toolName: tool.menuTitle)
                    UsageHeatmapView(heatmap: snapshot.heatmap, density: density)
                    UsageRateView(heatmap: snapshot.heatmap, density: density)
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
        max(320, min(380, density.popoverWidth * 0.34))
    }

    private var leftColumnIdealWidth: CGFloat {
        max(leftColumnMinWidth, min(410, density.popoverWidth * 0.38))
    }

    private var leftColumnMaxWidth: CGFloat {
        max(leftColumnIdealWidth, min(440, density.popoverWidth * 0.42))
    }

    private var rightColumnMinWidth: CGFloat {
        500
    }
}

/// Composite Cost header for the right column: 4-cell summary row + Top Model.
/// Bundled so the right column has clear "this is the cost section" framing
/// before the chart starts.
private struct CostHeaderCard: View {
    let tool: ToolType
    let snapshot: CostSnapshot
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center) {
                ProviderSectionTitle(
                    tool: tool,
                    title: "\(tool.menuTitle) Cost",
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
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh \(tool.menuTitle) cost") {
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
struct ProviderQuotaCard: View {
    let tool: ToolType
    let density: Theme.Density
    /// When true, only the headline (no-group) buckets are rendered. Used in
    /// Overview where 3 cards are stacked. Single-provider popovers pass `false`
    /// so every bucket appears (Sonnet, Designs, Daily Routines, …).
    var compact: Bool = false

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let account = environment.account(for: tool)
        let quota = environment.quota(for: tool)
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

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center, spacing: 8) {
                ProviderSectionTitle(
                    tool: tool,
                    title: tool.menuTitle,
                    subtitle: tool.subtitle,
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

            if let quota, !quota.buckets.isEmpty {
                bucketContent(quota.buckets)
                if let liveError {
                    messageRow(text: "Update failed: \(liveError.userFacingMessage)", color: .orange)
                }
            } else if let liveError {
                messageRow(text: liveError.userFacingMessage, color: .orange)
            } else {
                messageRow(text: emptyMessage, color: .secondary)
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

    private func bucketContent(_ buckets: [QuotaBucket]) -> some View {
        let primary = buckets.filter { $0.groupTitle == nil }
        let extras = buckets.filter { $0.groupTitle != nil }
        return VStack(alignment: .leading, spacing: density.bucketGroupSpacing) {
            if !primary.isEmpty {
                ForEach(primary) { bucket in
                    ProviderBucketRow(bucket: bucket, mode: settingsStore.displayMode, density: density)
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
                            ProviderBucketRow(bucket: bucket, mode: settingsStore.displayMode, density: density)
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
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine:
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
        guard error.isCredentialState,
              let quota,
              !quota.buckets.isEmpty,
              Date().timeIntervalSince(quota.queriedAt) < 30 * 60
        else {
            return error
        }
        return nil
    }
}

private struct ProviderBucketRow: View {
    let bucket: QuotaBucket
    let mode: DisplayMode
    let density: Theme.Density

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
        let expectedDisplayed = pace.map { expectedDisplay(for: $0, mode: mode) }
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
                    height: density.bucketBarHeight
                )
            } else {
                QuotaBarShape(percent: percent, mode: mode, height: density.bucketBarHeight)
            }
            if let pace {
                UsagePaceRow(pace: pace, now: now, fontSize: density.resetCountdownFontSize)
            }
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
