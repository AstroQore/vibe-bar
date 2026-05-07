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
            ScrollView(.vertical, showsIndicators: true) {
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
    }

    private var activeDensity: Theme.Density {
        let popDens = settingsStore.settings.popoverDensity(for: kind)
        switch kind {
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
            }
        case .codex:
            ProviderDetailView(tool: .codex, density: density)
        case .claude:
            ProviderDetailView(tool: .claude, density: density)
        case .status:
            ServiceStatusCard(tools: ToolType.allCases)
        }
    }

    private var headerTitle: String {
        switch kind {
        case .compact: return "Overview"
        case .codex:   return "OpenAI"
        case .claude:  return "Claude"
        case .status:  return "Service Status"
        }
    }

    private var headerSubtitle: String? {
        switch kind {
        case .compact: return "All providers · quota & cost"
        case .codex:   return ToolType.codex.subtitle
        case .claude:  return ToolType.claude.subtitle
        case .status:  return "Live status pages"
        }
    }

    private var headerPlan: String? {
        switch kind {
        case .compact, .status: return nil
        case .codex:   return planBadgeLabel(for: .codex)
        case .claude:  return planBadgeLabel(for: .claude)
        }
    }

    private var visibleTools: [ToolType] {
        switch kind {
        case .compact, .status: return ToolType.allCases
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
}

private struct ProviderSectionTitle: View {
    let tool: ToolType
    let title: String
    var subtitle: String?
    let titleFontSize: CGFloat
    let subtitleFontSize: CGFloat
    var iconSize: CGFloat = 15
    var badgeSize: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ProviderBrandBadge(
                kind: tool.brandMenuBarKind,
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
    case claude
    case openAI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .claude:   return "Claude"
        case .openAI:   return "OpenAI"
        }
    }

    var menuBarKind: MenuBarItemKind {
        switch self {
        case .overview: return .compact
        case .claude:   return .claude
        case .openAI:   return .codex
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
        ProviderBrandIconView(kind: page.menuBarKind, size: page == .overview ? 12 : 11)
            .opacity(isSelected ? 1 : 0.72)
            .frame(width: 16, height: 14, alignment: .center)
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
        let snapshots = ToolType.allCases.compactMap { environment.costService.snapshot(for: $0) }
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
                ForEach(ToolType.allCases, id: \.self) { tool in
                    if tool.supportsTokenCost {
                        OverviewCostCard(tool: tool, density: density)
                    }
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
/// left and current provider status on the right.
private struct CombinedTotalsRow: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    private let summaryHeight: CGFloat = 112

    var body: some View {
        let snapshots = ToolType.allCases.compactMap { environment.costService.snapshot(for: $0) }
        let totalCost = snapshots.reduce(0.0) { $0 + $1.allTimeCostUSD }
        let todayCost = snapshots.reduce(0.0) { $0 + $1.todayCostUSD }
        let weekCost = snapshots.reduce(0.0) { $0 + $1.last7DaysCostUSD }
        let monthCost = snapshots.reduce(0.0) { $0 + $1.last30DaysCostUSD }
        let totalTokens = snapshots.reduce(0) { $0 + $1.allTimeTokens }
        let todayTokens = snapshots.reduce(0) { $0 + $1.todayTokens }
        let weekTokens = snapshots.reduce(0) { $0 + $1.last7DaysTokens }
        let totalFiles = snapshots.reduce(0) { $0 + $1.jsonlFilesFound }

        HStack(alignment: .top, spacing: density.interSectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
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
            .frame(maxWidth: .infinity, minHeight: summaryHeight, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .fill(.background.tertiary.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .stroke(.separator.opacity(0.4), lineWidth: 0.5)
            )

            OverviewStatusSummaryCard(density: density)
                .frame(maxWidth: .infinity, minHeight: summaryHeight, alignment: .center)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("STATUS")
                    .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
                Spacer()
                if let lastFetched = serviceStatus.lastFetched {
                    Text(ResetCountdownFormatter.updatedAgo(from: lastFetched, now: Date()))
                        .font(.system(size: max(9, density.subtitleFontSize - 1)))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                ForEach(ToolType.allCases, id: \.self) { tool in
                    providerStatusTile(tool)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(density.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.color)
                ProviderBrandIconView(kind: tool.brandMenuBarKind, size: 11)
                    .opacity(0.85)
                    .frame(width: 14, height: 14)
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
        case .minor, .major, .critical:
            return .down
        }
    }
}

private enum OverviewStatusState {
    case up
    case down
    case checking
    case maintenance

    var label: String {
        switch self {
        case .up:          return "Up"
        case .down:        return "Down"
        case .checking:    return "Checking"
        case .maintenance: return "Maintenance"
        }
    }

    var iconName: String {
        switch self {
        case .up:          return "checkmark.circle.fill"
        case .down:        return "xmark.octagon.fill"
        case .checking:    return "arrow.clockwise.circle.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        }
    }

    var detail: String {
        switch self {
        case .up:          return "Operational"
        case .down:        return "Needs attention"
        case .checking:    return "Checking"
        case .maintenance: return "Maintenance"
        }
    }

    var color: Color {
        switch self {
        case .up:          return .green
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
    @State private var detailPresented: Bool = false

    var body: some View {
        let snapshot = environment.costService.snapshot(for: tool)
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center) {
                ProviderSectionTitle(
                    tool: tool,
                    title: "\(tool.menuTitle) cost",
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 15,
                    badgeSize: 22
                )
                Spacer(minLength: 4)
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
                        title: "\(tool.menuTitle) cost — full charts",
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

/// Single-provider popover content. No tabs — laid out as a two-column
/// waterfall to match the Overview popover:
///   - Left column: Quota card (all buckets) + Subscription utilization
///   - Right column: Cost summary + Top Model + Model Ranking + history chart
///                  + yearly heatmap + weekday-hour heatmap + hourly burn
///
/// The user explicitly asked for this — quota/utilization content is short,
/// cost content is long, so vertically stacking them in two columns balances
/// the popover height instead of forcing a tab switcher.
private struct ProviderDetailView: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
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
                let snapshot = environment.costService.snapshot(for: tool)
                if let snapshot, snapshot.jsonlFilesFound > 0 {
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

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center) {
                ProviderSectionTitle(
                    tool: tool,
                    title: "\(tool.menuTitle) cost",
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 15,
                    badgeSize: 22
                )
                Spacer()
                Text(snapshot.updatedAt, style: .relative)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
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
        let liveError = account.flatMap { quotaService.lastErrorByAccount[$0.id] }
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
