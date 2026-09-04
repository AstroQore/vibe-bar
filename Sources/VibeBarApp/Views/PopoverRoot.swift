import SwiftUI
import AppKit
import VibeBarCore

/// Top-level content for Vibe Bar's single tabbed popover workspace.
struct PopoverRoot: View {
    let width: CGFloat
    let onContentHeightChange: (CGFloat) -> Void
    let onToggleMiniWindow: () -> Void
    /// The tab the popover opens on. Production always starts on Overview;
    /// demo mode builds one popover per captured page.
    var initialPage: OverviewPage = .overview

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var remoteProbeService: RemoteProbeService
    @State private var overviewPage: OverviewPage = .overview
    @State private var staleCacheCheckedPage: OverviewPage?
    @State private var hasAppliedInitialPage = false

    var body: some View {
        let shellDensity = shellDensity
        let contentDensity = activeDensity
        let shellContentWidth = max(0, width - shellDensity.popoverPaddingH * 2)
        VStack(alignment: .leading, spacing: 0) {
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
                onShowWorkbench: { environment.showWorkbench() },
                onShowSettings: { environment.showSettingsWindow() }
            )
            .frame(height: shellDensity.headerHeight, alignment: .center)
            .padding(.bottom, max(4, shellDensity.interSectionSpacing * 0.45))
            Divider()
                .opacity(0.3)
                .padding(.bottom, shellDensity.interSectionSpacing)
            ScrollView(.vertical, showsIndicators: false) {
                content(density: contentDensity)
                    // A vertical ScrollView does not always pass a finite
                    // horizontal proposal through to intrinsically wide
                    // HStacks. Provider detail pages then grow to the sum of
                    // both columns' ideal widths and their right edge escapes
                    // the shared popover shell. Give every tab the exact same
                    // viewport width so only its height remains scrollable.
                    .frame(width: shellContentWidth, alignment: .topLeading)
                    .padding(.bottom, 4)
            }
            .frame(maxHeight: maxScrollHeight)
        }
        // Provider pages have a narrower intrinsic HStack than Overview and
        // Misc. Pin the shared shell's inner width before adding padding so
        // SwiftUI never centers those pages inside the outer frame.
        .frame(width: shellContentWidth, alignment: .topLeading)
        .padding(.horizontal, shellDensity.popoverPaddingH)
        .padding(.vertical, shellDensity.popoverPaddingV)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // Every control in the popover is hand-drawn; the system focus ring
        // is switched off once here and `VibeBarButtonStyle` draws its own
        // accent hairline where keyboard focus lands.
        .vibeBarControlFocus()
        .readHeight(onContentHeightChange)
        .onAppear {
            if !hasAppliedInitialPage {
                hasAppliedInitialPage = true
                // A caller can name a page the strip is not showing — demo
                // mode restores one by raw value, and a workspace can be
                // disconnected between opening the popover twice. Landing on
                // a tab that is not in the strip leaves nothing selected.
                let pages = OverviewPage.visiblePages(
                    settings: settingsStore.settings,
                    remoteConfigured: remoteProbeService.isConfigured
                )
                overviewPage = pages.contains(initialPage) ? initialPage : .overview
            }
            refreshStaleCacheForCurrentPage()
        }
        .onChange(of: overviewPage) { _, _ in
            refreshStaleCacheForCurrentPage()
        }
    }

    /// Switching pages already refreshed a missing/stale/expired cache, but
    /// opening the popover straight onto the page it was last left on changes
    /// nothing and so triggered nothing — the provider the user is looking at
    /// right now was the one page that never got this check. Run it on appear
    /// too, and remember the page it ran for so the two paths cannot both fire
    /// for the same one.
    private func refreshStaleCacheForCurrentPage() {
        guard staleCacheCheckedPage != overviewPage else { return }
        staleCacheCheckedPage = overviewPage
        environment.scheduler.triggerRefreshForStaleCacheIfNeeded()
    }

    /// The tabbed popover is one shared shell. The title band, content cards,
    /// and outer margins all use the same density so switching pages never
    /// shifts the left edge or changes the apparent workspace padding.
    private var shellDensity: Theme.Density {
        Theme.overviewDensity(for: settingsStore.settings.popoverDensity)
    }

    private var activeDensity: Theme.Density {
        shellDensity
    }

    private var maxScrollHeight: CGFloat {
        let visible = NSScreen.vibeBarPresentationScreen?.visibleFrame.height ?? 900
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
        case .machines:
            RemoteMachinesPage(density: density)
        }
    }

    private var headerTitle: String {
        switch overviewPage {
        // The four company names are quota-axis identifiers — AGENTS.md
        // § 7.1 — and stay as their owners spell them in every language.
        case .overview: return L10n.Popover.Tab.overview
        case .openAI: return "OpenAI"
        case .claude: return "Anthropic"
        case .googleAI: return "Google AI"
        case .grok: return "SpaceXAI"
        case .misc: return L10n.Popover.Tab.misc
        case .machines: return L10n.Popover.Tab.machines
        }
    }

    private var headerSubtitle: String? {
        switch overviewPage {
        case .overview: return L10n.Popover.Header.overviewSubtitle
        case .openAI, .claude, .googleAI, .grok: return nil
        case .misc: return L10n.Popover.Header.miscSubtitle
        case .machines: return L10n.Popover.Header.machinesSubtitle
        }
    }

    private var visibleTools: [ToolType] {
        // Header timestamps and refresh state aggregate the providers
        // visible in the current popover. The Misc subpage owns its
        // usage-only integrations; the Google AI subpage aggregates the
        // linked partial-primary tools; the Grok page aggregates its family
        // without adding a separate Cursor tab.
        if overviewPage == .misc {
            return settingsStore.settings.visibleMiscProviderList
        }
        if overviewPage == .googleAI {
            return ToolType.googleAIPair
        }
        if overviewPage == .grok {
            return ToolType.grokFamily
        }
        if overviewPage == .machines {
            return []
        }
        switch overviewPage {
        case .overview:
            return settingsStore.settings.visibleCoreProviderList
        case .openAI: return [.codex]
        case .claude: return [.claude]
        case .googleAI: return ToolType.googleAIPair
        case .grok: return ToolType.grokFamily
        case .misc: return settingsStore.settings.visibleMiscProviderList
        case .machines: return []
        }
    }

    private var latestUpdated: Date? {
        if overviewPage == .machines { return remoteProbeService.lastUpdated }
        return visibleAccounts
            .compactMap { quotaService.lastUpdatedByAccount[$0.id] }
            .max()
    }

    private var isRefreshing: Bool {
        if overviewPage == .machines { return remoteProbeService.isRefreshing }
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

}

struct ProviderSectionTitle: View {
    let tool: ToolType
    let title: String
    var subtitle: String?
    let titleFontSize: CGFloat
    let subtitleFontSize: CGFloat
    var iconSize: CGFloat = 17
    var badgeSize: CGFloat = 24
    /// Nearly every caller titles this with `vendorName` — an L1 company — so
    /// the company mark is the default and a product-level heading opts out.
    var showsCompanyMark: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsCompanyMark {
                CompanyBrandBadge(
                    tool: tool,
                    iconSize: iconSize,
                    containerSize: badgeSize
                )
            } else {
                ToolBrandBadge(
                    tool: tool,
                    iconSize: iconSize,
                    containerSize: badgeSize
                )
            }
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

/// The popover's tab strip, and — through `layoutPageID` — the list of pages
/// the layout editor can arrange. Internal rather than private so the Settings
/// editor enumerates exactly the tabs the popover is showing instead of
/// maintaining its own idea of which providers exist.
enum OverviewPage: String, CaseIterable, Identifiable {
    case overview
    case openAI
    case claude
    case googleAI
    case grok
    case misc
    case machines

    var id: String { rawValue }

    /// Tabs currently visible in the popover, in strip order.
    ///
    /// Remote machines is experimental and appears only once a workspace is
    /// connected. There is no separate opt-in switch because connecting one
    /// *is* the opt-in — and an empty tab that every user carries is a worse
    /// answer than no tab, since the strip's width is shared by every
    /// provider the user actually has.
    static func visiblePages(
        settings: AppSettings,
        remoteConfigured: Bool
    ) -> [OverviewPage] {
        [.overview]
            + settings.visibleCoreProviderList.compactMap(OverviewPage.page(for:))
            + (remoteConfigured ? [.machines] : [])
            + [.misc]
    }

    /// The layout-engine page this tab renders, or `nil` for tabs that are not
    /// laid out as two columns of modules. Misc is a self-managing grid of
    /// usage-only provider tiles, not a module page.
    var layoutPageID: PageLayoutPageID? {
        switch self {
        case .overview: return .overview
        case .openAI:   return .detail(.codex)
        case .claude:   return .detail(.claude)
        case .googleAI: return .detail(.gemini)
        case .grok:     return .detail(.grok)
        case .misc:     return nil
        case .machines: return nil
        }
    }

    /// L1 enterprise/brand labels. SubProviders are named inside each card,
    /// so the tab strip and card header use one consistent level.
    var label: String {
        switch self {
        case .overview: return L10n.Popover.Tab.overview
        case .openAI:   return "OpenAI"
        case .claude:   return "Anthropic"
        case .googleAI: return "Google AI"
        case .grok:     return "SpaceXAI"
        case .misc:     return L10n.Popover.Tab.miscShort
        case .machines: return L10n.Popover.Tab.machines
        }
    }

    var coreProvider: ToolType? {
        switch self {
        case .openAI: return .codex
        case .claude: return .claude
        case .googleAI: return .gemini
        case .grok: return .grok
        case .overview, .misc, .machines: return nil
        }
    }

    static func page(for tool: ToolType) -> OverviewPage? {
        switch tool.coreProviderRepresentative {
        case .codex: return .openAI
        case .claude: return .claude
        case .gemini: return .googleAI
        case .grok: return .grok
        default: return nil
        }
    }
}

private struct OverviewPageSwitch: View {
    @Binding var selection: OverviewPage
    let density: Theme.Density

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var remoteProbeService: RemoteProbeService

    private var visiblePages: [OverviewPage] {
        OverviewPage.visiblePages(
            settings: settingsStore.settings,
            remoteConfigured: remoteProbeService.isConfigured
        )
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
                .help(L10n.Popover.showPage(page: page.label))
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
            fallBackIfSelectionVanished()
        }
        // Disconnecting a workspace removes a tab while the user is standing
        // on it, so the same fallback has to watch configuration too.
        .onChange(of: remoteProbeService.isConfigured) { _, _ in
            fallBackIfSelectionVanished()
        }
    }

    private func fallBackIfSelectionVanished() {
        if !visiblePages.contains(selection) {
            selection = .overview
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
        // One renderer keeps every tab visually pinned to the same
        // baseline. Overview and Misc still get SF symbols because
        // they aren't single-provider tabs.
        //
        // The strip labels L1 companies, so it draws L1 marks:
        // `CompanyBrandIconView` gives Google AI and SpaceXAI their own
        // rather than borrowing Gemini's spark and Grok's slash.
        Group {
            switch page {
            case .overview:
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: Self.iconSize, weight: .semibold))
            case .misc:
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: Self.iconSize, weight: .medium))
            case .machines:
                Image(systemName: "server.rack")
                    .font(.system(size: Self.iconSize, weight: .medium))
            case .openAI:
                ToolBrandIconView(tool: .codex, size: Self.iconSize)
            case .claude:
                ToolBrandIconView(tool: .claude, size: Self.iconSize)
            case .googleAI:
                CompanyBrandIconView(tool: .gemini, size: Self.iconSize)
            case .grok:
                CompanyBrandIconView(tool: .grok, size: Self.iconSize)
            }
        }
        .opacity(isSelected ? 1 : 0.72)
        .frame(width: 18, height: 16, alignment: .center)
    }
}

/// Overview popover content: one module waterfall, cost and status summary
/// included.
///
/// The two summary cards used to be a hard-coded header row above the
/// waterfall, on the grounds that "two half-width cards pinned to one shared
/// height" was not something two independently flowing columns could express.
/// They are ordinary modules now, carrying `OverviewMasonryPhase.summary`: the
/// planner places a summary phase across the columns in declaration order
/// rather than balancing it, which reproduces that row exactly while making the
/// two cards arrangeable like everything else.
///
/// Until the user arranges the page by hand this is the live-measured
/// `ColumnMasonryLayout` it has always been — summary row first, then the quota
/// cards balanced globally, then Cost from those seeded column heights, and
/// finally the shorter side filled with supporting analytics. Once a saved
/// arrangement exists, the same cards render in the saved order at the saved
/// column widths.
private struct OverviewWaterfall: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var layoutModel: PageLayoutModel
    /// Same reason as `ProviderDetailView`: whether the Overview has cost and
    /// analytics cards at all depends on whether any snapshot has found session
    /// logs, and that answer arrives from the service, which the surrounding
    /// view must observe for the module set to follow it.
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var costService: CostUsageService
    @State private var masonrySession = ColumnMasonryLayout.Session()
    /// Present only on the Layout Studio's stage — see `StudioPageOverride`.
    @Environment(\.studioPageOverride) private var studioPageOverride

    private let page = PageLayoutPageID.overview

    var body: some View {
        let settings = settingsStore.settings
        let descriptors = PageModuleCatalog.descriptors(
            for: page,
            environment: environment,
            settings: settings
        )
        // One rollup for the whole pass. Every aggregation below used to be
        // re-derived per card — and the module catalog above derived them a
        // fourth time — which is why an unrelated quota publish could cost the
        // Overview several full cross-provider combines per re-render.
        let rollup = PageModuleCatalog.overviewRollup(
            environment: environment,
            settings: settings
        )
        let context = OverviewModuleContext(
            history: rollup.dailyHistory,
            heatmap: rollup.heatmap,
            models: rollup.modelBreakdowns,
            combinedSnapshot: rollup.combinedSnapshot,
            // Product-family snapshots are requested only when their matching
            // Overview modules are visible; the aggregation cache makes these
            // reads share the rollup's already-computed inputs.
            googleAISnapshot: settings.isCoreProviderVisible(.gemini)
                ? PageModuleCatalog.googleAICostSnapshot(environment: environment)
                : .empty(tool: .antigravity),
            grokSnapshot: settings.isCoreProviderVisible(.grok)
                ? PageModuleCatalog.grokCostSnapshot(environment: environment)
                : .empty(tool: .grok)
        )

        // `auto` is the only mode the balancer runs in. `compact` and `manual`
        // both render fixed columns — one packed for height by
        // `PageLayoutPacker`, band by band, one arranged by hand — through the
        // same path, so the two can never diverge in anything but their source
        // of column order.
        //
        // On the Studio's stage every mode draws through the fixed-column
        // path — with the arrangement a drag is proposing, or with the
        // resolved one, which for `auto` is the same planner answer the
        // balancer would produce. Starting a drag must not switch layouts
        // under the pointer.
        if let override = studioPageOverride, override.page == page {
            arrangedWaterfall(descriptors: descriptors, context: context, arrangement: override.arrangement)
        } else if layoutModel.mode(for: page) == .auto {
            balancedWaterfall(descriptors: descriptors, context: context)
        } else {
            arrangedWaterfall(descriptors: descriptors, context: context)
        }
    }

    /// The page as it was arranged — by the user in `manual`, by the packer in
    /// `compact`: fixed order, saved column widths.
    ///
    /// - Parameter arrangement: what to draw instead of the resolved
    ///   arrangement; the Studio passes the one a drag is proposing.
    private func arrangedWaterfall(
        descriptors: [PageModuleDescriptor],
        context: OverviewModuleContext,
        arrangement: PageLayoutArrangement? = nil
    ) -> some View {
        let resolved = arrangement ?? layoutModel.arrangement(
            for: page,
            descriptors: descriptors,
            spacing: Double(density.interSectionSpacing)
        )
        return PageLayoutColumns(
            page: page,
            descriptors: descriptors,
            arrangement: resolved,
            widths: PageColumnWidths(density: density, ratio: resolved.ratio),
            spacing: density.interSectionSpacing,
            model: layoutModel
        ) { descriptor in
            card(for: descriptor, context: context)
        }
    }

    /// The built-in arrangement: the auto-balancing waterfall, planned inside
    /// the page's segments.
    ///
    /// The segments are handed to the layout rather than derived from the
    /// descriptors' phases, so a grouping the user chose in Settings changes what
    /// the balancer balances. With no chosen grouping the resolved segments *are*
    /// the phase grouping, so the untouched Overview plans exactly as before.
    private func balancedWaterfall(
        descriptors: [PageModuleDescriptor],
        context: OverviewModuleContext
    ) -> some View {
        let visible = layoutModel.visibleDescriptors(for: page, descriptors: descriptors)
        let groups = layoutModel
            .resolvedSegments(for: page, descriptors: descriptors)
            .map { $0.map(\.rawValue) }
        return ColumnMasonryLayout(
            columns: 2,
            spacing: density.interSectionSpacing,
            groups: groups,
            session: masonrySession
        ) {
            ForEach(visible) { descriptor in
                card(for: descriptor, context: context)
                    .measuredPageModule(descriptor.id, page: page, model: layoutModel)
                    .overviewMasonryItem(id: descriptor.id.rawValue, phase: descriptor.masonryPhase)
            }
        }
        // The session lock exists so refreshes cannot reshuffle the dashboard
        // under the user. Re-grouping the page is not a refresh — it is the user
        // asking for a different arrangement — so the lock is released for one
        // pass and the planner answers the new question.
        .onChange(of: groups) { _, _ in
            masonrySession.columnsByID = [:]
        }
    }

    /// The one place an Overview module identity turns back into its card —
    /// called by both the arranged and the balanced path, so the two can never
    /// render a module differently.
    ///
    /// The Overview starts no periodic timer of its own: a page-level tick
    /// would re-measure every card in the masonry twice a minute, and the
    /// masonry session lock would fight it. The two clock-consuming modules —
    /// the quota cards and Upcoming Resets — each own exactly one `PageClock`
    /// at *card* level instead, which is one timer per card rather than one
    /// per bucket row, and none at all while the popover is closed. Never add
    /// a timer below a card.
    @ViewBuilder
    private func card(
        for descriptor: PageModuleDescriptor,
        context: OverviewModuleContext
    ) -> some View {
        switch descriptor.kind {
        case .overviewCostSummary:
            OverviewCostSummaryCard(density: density)
        case .overviewStatusSummary:
            OverviewStatusSummaryCard(
                density: density,
                minHeight: density.overviewSummaryHeight,
                tools: settingsStore.settings.visibleCoreProviderList
            )
        case let .overviewQuota(tool):
            if tool == .gemini {
                // Gemini Web and AntiGravity share one Google AI company card.
                GeminiCombinedCard(density: density)
            } else if tool == .grok {
                GrokCombinedCard(density: density)
            } else {
                ProviderQuotaCard(tool: tool, density: density, compact: false)
            }
        case .overviewQuotaHistoryAll:
            // Sits with the quota cards, not with the analytics: it is the
            // cross-provider version of what they each show one slice of,
            // and it is the only card that can answer "which of my quotas
            // runs out first".
            OverviewQuotaHistoryCard(density: density)
        case .overviewCostAll:
            CostHistoryView(
                tool: .codex,
                snapshot: context.combinedSnapshot,
                density: density,
                chartHeight: density.overviewCostChartHeight,
                titleOverride: L10n.Cost.History.allProviders
            )
        case let .overviewCost(tool):
            if tool == .gemini {
                // Google AI (Gemini + AntiGravity) cost, surfaced as the
                // single Google AI platform aligned with the other three.
                // AntiGravity is now the only live Google/Gemini usage
                // source (Gemini CLI no longer writes local telemetry);
                // its `.pb`-only cascades are filled via the
                // language-server RPC in CostUsageScanner.scanAntigravity.
                OverviewCostCard(
                    tool: .antigravity,
                    density: density,
                    snapshotOverride: context.googleAISnapshot,
                    titleOverride: L10n.Cost.GoogleAI.title,
                    emptyMessageOverride: L10n.Cost.GoogleAI.empty,
                    // The tool name is a quota-axis company name, not copy.
                    toolNameOverride: "Google AI",
                    heatmapTitleOverride: L10n.Usage.WhenYouUse.googleAI
                )
            } else if tool == .grok {
                OverviewCostCard(
                    tool: .grok,
                    density: density,
                    snapshotOverride: context.grokSnapshot,
                    titleOverride: L10n.Cost.SpaceXAI.title,
                    emptyMessageOverride: L10n.Cost.SpaceXAI.empty,
                    toolNameOverride: "SpaceXAI",
                    heatmapTitleOverride: L10n.Usage.WhenYouUse.spaceXAI
                )
            } else {
                OverviewCostCard(tool: tool, density: density)
            }
        case .overviewUsageMix:
            OverviewUsageMixCard(density: density)
        case .overviewUpcomingResets:
            UpcomingResetsCard(density: density)
        case .overviewResetHistoryCompare:
            ResetHistoryCompareCard(density: density)
        case .overviewModelRanking:
            ModelRankingList(
                breakdowns: context.models,
                density: density,
                subtitle: L10n.Cost.ModelRanking.allProvidersAllTime
            )
        case .overviewYearHeatmap:
            YearlyContributionHeatmapView(
                history: context.history,
                density: density,
                toolName: L10n.Cost.allProviders
            )
        case .overviewActivityHeatmap:
            UsageActivityView(
                heatmap: context.heatmap,
                density: density,
                titleOverride: L10n.Usage.WhenYouUse.everything
            )
        case .quotaGroup, .serviceStatus, .resetHistoryCompare, .costHeader,
             .costHistory, .modelRanking, .yearHeatmap, .activityHeatmap,
             .costEmpty:
            // Provider-page families. `PageModuleCatalog` never puts them on
            // the Overview, and a stale identifier is dropped before it gets
            // here, so this is unreachable rather than a fallback.
            EmptyView()
        }
    }
}

/// Cross-provider rollups the Overview computes once per pass and hands to
/// whichever modules need them.
private struct OverviewModuleContext {
    let history: [DailyCostPoint]
    let heatmap: UsageHeatmap
    let models: [CostSnapshot.ModelBreakdown]
    let combinedSnapshot: CostSnapshot
    let googleAISnapshot: CostSnapshot
    let grokSnapshot: CostSnapshot
}

private struct GrokPage: View {
    let density: Theme.Density

    var body: some View {
        ProviderDetailView(tool: .grok, density: density)
    }
}

/// Overview popover card that merges Gemini Web + AntiGravity into one
/// Google AI company card, with each one rendered as an L2 SubProvider.
/// Replaces the previous side-by-side ProviderQuotaCard pair so the
/// the two SubProviders no longer look like
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
                    title: ToolType.gemini.vendorName,
                    subtitle: nil,
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16,
                    badgeSize: 24
                )
                Spacer(minLength: 4)
                BorderlessIconButton(
                    systemImage: "arrow.clockwise",
                    help: L10n.Popover.refreshGoogleAI
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

            HStack(alignment: .center, spacing: 6) {
                ToolBrandIconView(tool: .gemini, size: 13)
                    .opacity(0.85)
                Text("Gemini Web")
                    .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let label = geminiPlanBadge {
                    PlanBadgeView(text: label, fontSize: max(9, density.subtitleFontSize - 1))
                }
            }

            // Gemini Web buckets follow its SubProvider row. AntiGravity gets
            // an equivalent row below so the two L2 services and their L3
            // quota/model groups remain visually distinct.
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
                        fontSize: max(9, density.subtitleFontSize - 1)
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

    /// Resolve the plan-badge text for a Google AI SubProvider. Looks
    /// at the cached quota first (Gemini Web returns "Pro" / "Ultra" /
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

/// Overview card for the SpaceXAI provider family. Grok, Cursor, and the
/// cloud-only Grok Bot quota are separate SubProviders in the same card.
private struct GrokCombinedCard: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        let grokAccount = environment.account(for: .grok)
        let cursorAccount = environment.account(for: .cursor)
        let cursorQuota = cursorAccount.flatMap { quotaService.cachedQuota(for: $0.id) }
            ?? environment.quota(for: .cursor)
        let showsCursor = (cursorAccount.map { $0.source != .notConfigured } ?? false)
            || cursorQuota != nil
        let showsGrokBot = cursorQuota?.buckets.contains { $0.id == "grok_bot_weekly" } == true
        let anyInFlight = [grokAccount, cursorAccount].compactMap { $0 }.contains {
            quotaService.inFlightAccountIds.contains($0.id)
        }
        let grokBadge = planBadge(for: .grok, account: grokAccount)
        let cursorBadge = planBadge(for: .cursor, account: cursorAccount)

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center, spacing: 8) {
                ProviderSectionTitle(
                    tool: .grok,
                    title: ToolType.grok.vendorName,
                    subtitle: nil,
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16,
                    badgeSize: 24
                )
                Spacer(minLength: 4)
                BorderlessIconButton(
                    systemImage: "arrow.clockwise",
                    help: L10n.Popover.refreshSpaceXAI
                ) {
                    environment.refresh(.grok)
                    environment.refresh(.cursor)
                }
                .disabled(anyInFlight)
                if anyInFlight {
                    ProgressView().controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            }


            HStack(alignment: .center, spacing: 6) {
                ToolBrandIconView(tool: .grok, size: 13)
                    .opacity(0.85)
                Text("Grok")
                    .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let grokBadge {
                    PlanBadgeView(text: grokBadge, fontSize: max(9, density.subtitleFontSize - 1))
                }
            }

            ProviderQuotaCard(
                tool: .grok,
                density: density,
                compact: false,
                embedded: true
            )

            if showsCursor {
                HStack(alignment: .center, spacing: 6) {
                    ToolBrandIconView(tool: .cursor, size: 13)
                        .opacity(0.85)
                    Text(ToolType.cursor.toolName)
                        .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let cursorBadge {
                        PlanBadgeView(text: cursorBadge, fontSize: max(9, density.subtitleFontSize - 1))
                    }
                }
                .padding(.top, 4)

                ProviderQuotaCard(
                    tool: .cursor,
                    density: density,
                    compact: false,
                    embedded: true,
                    includedBucketIDs: ["models", "other_models"]
                )

                if showsGrokBot {
                    HStack(alignment: .center, spacing: 6) {
                        BrandMarkIconView(mark: .grokBot, size: 13)
                            .opacity(0.85)
                        Text("Grok Bot")
                            .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let cursorBadge {
                            PlanBadgeView(text: cursorBadge, fontSize: max(9, density.subtitleFontSize - 1))
                        }
                    }
                    .padding(.top, 4)

                    ProviderQuotaCard(
                        tool: .cursor,
                        density: density,
                        compact: false,
                        embedded: true,
                        includedBucketIDs: ["grok_bot_weekly"],
                        suppressGroupTitles: true,
                        showsFreshnessWarning: false
                    )
                }
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

    private func planBadge(for tool: ToolType, account: AccountIdentity?) -> String? {
        let quotaPlan = account.flatMap { quotaService.cachedQuota(for: $0.id)?.plan }
        let label = settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: quotaPlan,
            accountPlan: account?.plan
        )
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// The dedicated Google AI sub-page (still routed through `OverviewPage.googleAI`
/// for backwards compatibility with persisted menu-bar settings, but labelled "Google AI" at
/// every user-facing surface). Provider pages share one asymmetric layout:
/// live quota, forecast and service status remain together in the narrow left
/// column; cost and analytics use the wider right column.
private struct GeminiTabPage: View {
    let density: Theme.Density

    var body: some View {
        // The Google AI page combines Gemini Web + AntiGravity cost.
        ProviderDetailView(tool: .gemini, density: density)
    }
}

/// Empty state for the Gemini sub-page cost section. AntiGravity's
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
                    title: L10n.Cost.Provider.title(provider: ToolType.gemini.productName),
                    subtitle: L10n.Cost.noUsageYet,
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16,
                    badgeSize: 24,
                    // Titled with the product, so it keeps the product's mark.
                    showsCompanyMark: false
                )
                Spacer(minLength: 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Cost.Gemini.emptyTitle)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                Text(L10n.Cost.Gemini.emptyDetail)
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

/// The Overview's cost and token headline grid — the left half of what used to
/// be a hard-coded header row, now an arrangeable module.
///
/// It keeps its pinned height (`Theme.Density.overviewSummaryHeight`), which is
/// what makes it read as one row with the status card beside it; the width comes
/// from whichever column the layout puts it in, like every other card.
private struct OverviewCostSummaryCard: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var costService: CostUsageService
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var ledgerTokens: UsageTokenHeadlineTotals?

    var body: some View {
        // Headline totals span every cost-aware provider, including
        // Google AI (Gemini + AntiGravity): AntiGravity usage is now
        // captured offline (`.db`) and via the language-server RPC
        // (`.pb`), so it's reliable enough to roll up here.
        let visibleCostProviders = ToolType.costAwareProviders.filter {
            settingsStore.settings.isCoreProviderVisible($0)
        }
        // Ten reduce passes, a per-provider calendar scan for "yesterday", and
        // two peak scans over the combined daily history — all of it derived
        // once per cost refresh in Core rather than once per render pass here.
        let totals = costService.totals(of: visibleCostProviders)
        let remoteTotals = costService.remoteTotals(of: visibleCostProviders)
        let headlineTokens = UsageTokenHeadlineTotals.merging(
            localLedger: ledgerTokens,
            selectedRemote: remoteTotals,
            mergedSnapshot: totals
        )
        let tokenTaskID = visibleCostProviders.map(\.rawValue).joined(separator: ",")
            + "|\(costService.lastRefreshedAt?.timeIntervalSince1970 ?? 0)"
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Cost.title)
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
                BorderlessIconButton(systemImage: "arrow.clockwise", help: L10n.Cost.refreshData) {
                    environment.refreshCostUsage()
                }
                .disabled(costService.isRefreshing)
            }
            // 4 × 3 summary: durable all-time/peak context first, followed by
            // matching cost and token timeframes. The flexible gaps use the
            // full pinned height, instead of leaving one empty band below the
            // third row.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    metric(label: L10n.Cost.Metric.totalCost, value: formatCost(totals.allTimeCostUSD), highlight: true)
                    divider
                    metric(label: L10n.Cost.Metric.totalTokens, value: formatTokens(headlineTokens.allTimeTokens), highlight: true)
                    divider
                    metric(label: L10n.Cost.Metric.peakDay, value: formatCost(totals.peakDayCostUSD))
                    divider
                    metric(label: L10n.Cost.Metric.peakTokenDay, value: formatTokens(headlineTokens.peakDayTokens))
                }
                Spacer(minLength: 8)
                HStack(alignment: .top, spacing: 0) {
                    metric(label: L10n.Cost.Timeframe.today, value: formatCost(totals.todayCostUSD))
                    divider
                    metric(label: L10n.Cost.Timeframe.yesterday, value: formatCost(totals.yesterdayCostUSD))
                    divider
                    metric(label: L10n.Cost.Metric.sevenDay, value: formatCost(totals.last7DaysCostUSD))
                    divider
                    metric(label: L10n.Cost.Metric.thirtyDay, value: formatCost(totals.last30DaysCostUSD))
                }
                Spacer(minLength: 8)
                HStack(alignment: .top, spacing: 0) {
                    metric(label: L10n.Cost.Metric.todayTokens, value: formatTokens(headlineTokens.todayTokens))
                    divider
                    metric(label: L10n.Cost.Metric.yesterdayTokens, value: formatTokens(headlineTokens.yesterdayTokens))
                    divider
                    metric(label: L10n.Cost.Metric.sevenDayTokens, value: formatTokens(headlineTokens.last7DaysTokens))
                    divider
                    metric(label: L10n.Cost.Metric.thirtyDayTokens, value: formatTokens(headlineTokens.last30DaysTokens))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(density.cardPadding)
        .frame(
            maxWidth: .infinity,
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
        .task(id: tokenTaskID) {
            guard let ledger = environment.usageLedger else { return }
            ledgerTokens = try? await ledger.tokenHeadlineTotals(tools: visibleCostProviders)
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

    private func formatCost(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value < 0.01 { return "$0.00" }
        if value < 100  { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.2fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

/// The Overview's live provider-status grid — the right half of the old header
/// row, now an arrangeable module.
///
/// Pinned to exactly `minHeight` — before its background, mirroring the cost
/// summary's frame — so the two cards always read as one aligned pair, the way
/// the old header row's outer pin kept them. The tile grid divides the pinned
/// interior rather than growing the card.
private struct OverviewStatusSummaryCard: View {
    let density: Theme.Density
    let minHeight: CGFloat
    let tools: [ToolType]

    @EnvironmentObject var serviceStatus: ServiceStatusController

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Status.Overview.title)
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
                BorderlessIconButton(systemImage: "arrow.clockwise", help: L10n.Status.Card.refresh) {
                    serviceStatus.refreshAll()
                }
                .disabled(!serviceStatus.inFlight.isEmpty)
            }
            if tools.isEmpty {
                Text(L10n.Status.Overview.enableProvider)
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
        // Pinned exactly, and before the background, so the rounded card is
        // drawn at this height rather than at whatever the tile grid would
        // prefer — a frame applied outside the background would leave the
        // oversized card bleeding past it. Mirrors the cost summary's frame.
        .frame(
            maxWidth: .infinity,
            minHeight: minHeight,
            idealHeight: minHeight,
            maxHeight: minHeight,
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
    }

    private func statusTileHeight(rowCount: Int) -> CGFloat {
        let rows = max(1, rowCount)
        // The refresh button keeps the header at least 22 pt tall regardless
        // of the title font, so budgeting less would overdraw the pin below.
        let headerHeight = max(22, density.bucketTitleFontSize + 6)
        let gridSpacing = CGFloat(max(0, rows - 1)) * density.cardSpacing
        let available = minHeight
            - density.cardPadding * 2
            - headerHeight
            - density.cardSpacing
            - gridSpacing
        // The card's pinned height is authoritative — the tiles divide what is
        // left rather than growing the card past the cost summary beside it.
        // The floor is a last-resort legibility guard: the core-provider list
        // caps at four tools (two rows), so at every density two rows fit and
        // the floor only bites in degenerate configurations.
        return max(44, available / CGFloat(rows))
    }

    private func providerStatusTile(_ tool: ToolType, height: CGFloat) -> some View {
        let projection = serviceStatus.projection(for: tool)
        let state = statusState(projection)
        let snapshot = projection.snapshot
        return VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(spacing: 7) {
                Image(systemName: state.iconName)
                    .font(.system(size: density.bucketTitleFontSize + 1, weight: .semibold))
                    .foregroundStyle(state.color)
                    .frame(width: 17, height: 17)
                // Framed at its drawn size, not a fixed 22 pt box: the icon row
                // sets the tile's tallest line, and the pinned card leaves each
                // tile (height − chrome) / rows — at compact density that is
                // 45 pt, and four points of air here were what pushed the
                // detail line out of it.
                CompanyBrandIconView(tool: tool, size: density.bucketTitleFontSize + 6)
                    .opacity(0.9)
                    .frame(
                        width: density.bucketTitleFontSize + 6,
                        height: density.bucketTitleFontSize + 6
                    )
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
                Text(statusDetail(projection, state: state))
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
        // The vertical budget is fixed by the pinned card: icon row + row
        // spacing + one detail line + this padding must fit within
        // (summary height − card chrome) / 2 at every density — 45/54/66 pt.
        // With the old max(6, padding − 4) the interior needed more than the
        // pin allowed and the detail line was compressed to nothing.
        .padding(.vertical, max(4, density.cardPadding - 9))
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
        _ projection: ServiceStatusController.Projection,
        state: OverviewStatusState
    ) -> String {
        if projection.isRefreshing { return L10n.Status.Overview.refreshing }
        if projection.error != nil { return L10n.Status.Overview.fetchFailed }
        if let incident = projection.snapshot?.recentIncidents.first, !incident.isResolved {
            return incident.name
        }
        // `effectiveDescription`, not `description`: the stored field holds
        // only what the provider itself published, and is empty for the
        // feeds that publish an indicator and no wording. The accessor is
        // what turns that into our own translated summary.
        return projection.snapshot?.effectiveDescription ?? state.detail
    }

    private func statusState(_ projection: ServiceStatusController.Projection) -> OverviewStatusState {
        if projection.isRefreshing {
            return .checking
        }
        if projection.error != nil {
            return .down
        }
        guard let indicator = projection.snapshot?.effectiveIndicator else {
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

}

private enum OverviewStatusState {
    case up
    case degraded
    case down
    case checking
    case maintenance

    var label: String {
        switch self {
        case .up:          return L10n.Status.Overview.up
        case .degraded:    return L10n.Status.Component.degraded
        case .down:        return L10n.Status.Overview.down
        case .checking:    return L10n.Status.Overview.checking
        case .maintenance: return L10n.Status.Component.maintenance
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
        case .up:          return L10n.Status.Component.operational
        case .degraded:    return L10n.Status.Component.partialOutage
        case .down:        return L10n.Status.Overview.needsAttention
        case .checking:    return L10n.Status.Overview.checking
        case .maintenance: return L10n.Status.Component.maintenance
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
        let title = titleOverride ?? "\(tool.vendorName) Cost"
        let toolName = toolNameOverride ?? tool.vendorName
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
                BorderlessIconButton(systemImage: "arrow.clockwise", help: L10n.Cost.refreshProvider(provider: toolName)) {
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
                    .buttonStyle(.vibeBar)
                    .foregroundStyle(.secondary)
                    .help(L10n.Cost.openFullCharts)
                    .popover(isPresented: $detailPresented, arrowEdge: .trailing) {
                        CostDetailPopoverContent(
                            tool: tool,
                            density: density,
                            snapshotOverride: snapshot,
                            titleOverride: L10n.Cost.fullCharts(title: title),
                            toolNameOverride: toolName,
                            heatmapTitleOverride: heatmapTitleOverride
                        )
                            .frame(width: max(660, density.popoverWidth * 0.70), height: 660)
                            .vibeBarNoInitialFocus()
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
        case .codex:  return L10n.Cost.Empty.codex
        case .claude: return L10n.Cost.Empty.claude
        case .gemini: return L10n.Cost.Empty.gemini
        case .antigravity: return L10n.Cost.Empty.antigravity
        case .grok: return L10n.Cost.Empty.grok
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers' empty cost-history view shouldn't be
            // reachable (cost cards are gated on
            // `tool.supportsTokenCost`), but render a graceful
            // fallback if it ever is.
            return L10n.Cost.notTracked(provider: tool.menuTitle)
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
                        title: titleOverride ?? L10n.Cost.providerFullCharts(provider: tool.vendorName),
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
/// live subscription panel, wider right for cost charts and heatmaps. The two
/// columns size independently and do NOT have to match in height.
///
/// Left column (fixed order, narrow):
///   1. One Subscription Utilization card per quota group, in provider order.
///      The first carries the provider header; each carries its own rows,
///      reset-history strips and quota-history chart.
///   2. Service Status
///
/// Right column (wide): Cost summary → Cost History → Model Ranking →
/// yearly contribution heatmap → weekday-hour heatmap.
private struct ProviderDetailView: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var layoutModel: PageLayoutModel
    /// Observed so the page's *module set* tracks the data behind it. The
    /// catalog asks these two which quota groups and which cost cards exist;
    /// reading them only through `environment`, which publishes neither, left a
    /// group that arrived on the first refresh — or the cost cards after the
    /// first scan — missing until something unrelated redrew the page.
    ///
    /// This is a separate trigger from the clock below, and deliberately so:
    /// a service publish re-runs `body` and rebuilds the descriptors, while a
    /// timeline tick re-runs only the closure inside `TimelineView`, which
    /// captures them. Ticking never re-derives the page.
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var costService: CostUsageService
    /// Present only on the Layout Studio's stage — see `StudioPageOverride`.
    @Environment(\.studioPageOverride) private var studioPageOverride

    var body: some View {
        let page = PageLayoutPageID.detail(tool)
        let descriptors = PageModuleCatalog.descriptors(
            for: page,
            environment: environment,
            settings: settingsStore.settings
        )
        // `auto` returns the page's built-in split here, so a provider page
        // needs no second branch: every mode renders the same fixed-order
        // columns, only their contents differ.
        let proposed = studioPageOverride?.page == page ? studioPageOverride?.arrangement : nil
        let resolved = proposed ?? layoutModel.arrangement(
            for: page,
            descriptors: descriptors,
            spacing: Double(density.interSectionSpacing)
        )
        let context = ProviderPageContext(
            pageTool: tool,
            groups: PageModuleCatalog.quotaGroupModules(tool: tool, environment: environment),
            snapshot: PageModuleCatalog.detailCostSnapshot(tool: tool, environment: environment)
        )
        // Exactly one periodic clock per page, at the page level. The quota
        // group cards' countdown strings are the only thing on the page that
        // reads the wall clock; they take the tick as plain data so no card
        // owns a timer of its own. `QuotaHistoryChartView` stays `.equatable()`
        // inside `QuotaGroupCard`, so the chart still ignores the tick.
        //
        // `PageClock` rather than `TimelineView(.periodic(from: .now, ...))`:
        // the anchor has to be stable across body passes (otherwise every
        // re-render re-phases the tick and the forecast memo never hits), and
        // the popover keeps this tree alive after it closes, so the clock has
        // to stop while it is hidden.
        PageClock(interval: 30) { tickDate in
            PageLayoutColumns(
                page: page,
                descriptors: descriptors,
                arrangement: resolved,
                // On `auto` the columns keep the exact clamped narrow-left
                // widths they have always had. The ratio presets take over in
                // the other two modes — including `compact`, where the ratio
                // is one of the inputs the packer balanced against.
                //
                // A drag on the Studio's stage lands the page in `manual`,
                // so the columns take the ratio widths from the moment a
                // card lifts rather than jumping to them at the drop.
                widths: layoutModel.isCustomized(page) || proposed != nil
                    ? PageColumnWidths(density: density, ratio: resolved.ratio)
                    : ProviderDetailColumnWidths(density: density).columnWidths,
                spacing: density.interSectionSpacing,
                model: layoutModel
            ) { descriptor in
                ProviderPageModule(
                    descriptor: descriptor,
                    context: context,
                    density: density,
                    mode: settingsStore.displayMode,
                    now: tickDate
                )
            }
        }
    }
}

/// Everything a provider page resolves once per pass and every one of its
/// modules draws from.
private struct ProviderPageContext {
    let pageTool: ToolType
    let groups: [QuotaGroupModule]
    let snapshot: CostSnapshot?

    /// Tool the cost cards are labelled and keyed by. Gemini's page shows the
    /// combined Gemini + AntiGravity total, which is carried on an AntiGravity
    /// snapshot but presented under the page's L1 company/brand.
    var costTool: ToolType { pageTool == .gemini ? .antigravity : pageTool }
    var costTitle: String? { "\(pageTool.vendorName) Cost" }
    var costToolName: String { pageTool.vendorName }
    var activityHeatmapTitle: String? { pageTool == .gemini ? L10n.Usage.WhenYouUse.googleAI : nil }

    func group(id: String) -> QuotaGroupModule? {
        groups.first { $0.id == id }
    }
}

/// The one place a provider-page module identity turns back into its card.
private struct ProviderPageModule: View {
    let descriptor: PageModuleDescriptor
    let context: ProviderPageContext
    let density: Theme.Density
    let mode: DisplayMode
    /// Tick from the page's single clock. Plain data — this view never starts
    /// a timer, however many quota groups the page ends up arranging.
    let now: Date

    var body: some View {
        switch descriptor.kind {
        case let .quotaGroup(groupID):
            if let group = context.group(id: groupID) {
                QuotaGroupCard(
                    module: group,
                    mode: mode,
                    density: density,
                    now: now,
                    // Only the provider-header card draws the refresh
                    // button, so only it needs the tools behind it.
                    refreshTools: group.showsProviderHeader
                        ? PageModuleCatalog.quotaRefreshTools(for: context.pageTool)
                        : [],
                    emptyMessage: group.rows.isEmpty
                        ? L10n.Quota.Group.noUtilization
                        : nil
                )
            }
        case .serviceStatus:
            ServiceStatusCard(tools: [context.pageTool], density: density)
        case .resetHistoryCompare:
            // Scoped to the page's family, so the Google AI page keeps
            // AntiGravity beside Gemini Web and the SpaceXAI page keeps
            // Cursor beside Grok — the same pairing the refresh button uses.
            ResetHistoryCompareCard(
                density: density,
                tools: PageModuleCatalog.quotaRefreshTools(for: context.pageTool),
                titleOverride: L10n.ResetHistory.cardTitle
            )
        case .costHeader:
            if let snapshot = context.snapshot {
                CostHeaderCard(
                    tool: context.costTool,
                    snapshot: snapshot,
                    density: density,
                    titleOverride: context.costTitle,
                    toolNameOverride: context.pageTool.vendorName
                )
            }
        case .costHistory:
            if let snapshot = context.snapshot {
                CostHistoryView(
                    tool: context.costTool,
                    snapshot: snapshot,
                    density: density,
                    chartHeight: density.detailCostChartHeight
                )
            }
        case .modelRanking:
            if let snapshot = context.snapshot {
                ModelRankingList(snapshot: snapshot, density: density)
            }
        case .yearHeatmap:
            if let snapshot = context.snapshot {
                YearlyContributionHeatmapView(
                    history: snapshot.dailyHistory,
                    density: density,
                    toolName: context.costToolName
                )
            }
        case .activityHeatmap:
            if let snapshot = context.snapshot {
                UsageActivityView(
                    heatmap: snapshot.heatmap,
                    density: density,
                    titleOverride: context.activityHeatmapTitle
                )
            }
        case .costEmpty:
            if context.pageTool == .gemini {
                GeminiCostEmptyCard(density: density)
            } else if context.pageTool == .grok {
                Text(L10n.Cost.SpaceXAI.empty)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                Text(L10n.Cost.Empty.genericCLI(provider: context.pageTool.menuTitle))
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
        case .overviewCostSummary, .overviewStatusSummary, .overviewQuota,
             .overviewQuotaHistoryAll, .overviewCostAll, .overviewCost,
             .overviewUsageMix, .overviewUpcomingResets,
             .overviewResetHistoryCompare, .overviewModelRanking,
             .overviewYearHeatmap, .overviewActivityHeatmap:
            // Overview families. `PageModuleCatalog` never puts them on a
            // provider page, and a stale identifier is dropped before it gets
            // here, so this is unreachable rather than a fallback.
            EmptyView()
        }
    }
}

/// Exact widths for the shared provider-detail shell. Flexible HStack children
/// use their intrinsic ideal size inside a vertical ScrollView, which can make
/// the analytics column wider than the visible popover. Resolve the two
/// columns from the shell's finite content width instead, while preserving the
/// existing narrow-left / wide-right density ratios.
private struct ProviderDetailColumnWidths {
    let left: CGFloat
    let right: CGFloat
    let total: CGFloat

    init(density: Theme.Density) {
        total = max(0, density.popoverWidth - density.popoverPaddingH * 2)
        let usable = max(0, total - density.interSectionSpacing)
        let preferredLeft = min(
            density.detailLeftColumnRange.upperBound,
            max(
                density.detailLeftColumnRange.lowerBound,
                density.popoverWidth * density.detailLeftColumnFraction
            )
        )
        let maximumLeft = max(
            density.detailLeftColumnRange.lowerBound,
            usable - density.detailRightColumnMinimum
        )
        left = min(preferredLeft, maximumLeft)
        right = max(0, usable - left)
    }

    var columnWidths: PageColumnWidths {
        PageColumnWidths(left: left, right: right, total: total)
    }
}

/// Composite Cost header for the provider's wide analytics column: 4-cell
/// summary row + Top Model.
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
                    title: titleOverride ?? L10n.Cost.Provider.title(provider: tool.vendorName),
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
                BorderlessIconButton(systemImage: "arrow.clockwise", help: L10n.Cost.refreshProvider(provider: toolNameOverride ?? tool.menuTitle)) {
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
        let title = bucket.groupTitle.map(QuotaGroupLabelLocalizer.display) ?? L10n.Quota.Group.other
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
    /// be nested inside a larger L1 company card. The combined Google AI and
    /// SpaceXAI cards use this for their L2 SubProvider sections.
    var embedded: Bool = false
    var includedBucketIDs: Set<String>?
    var suppressGroupTitles: Bool = false
    var showsFreshnessWarning: Bool = true

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
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
                        title: tool.vendorName,
                        subtitle: nil,
                        titleFontSize: density.titleFontSize,
                        subtitleFontSize: density.subtitleFontSize,
                        iconSize: 16,
                        badgeSize: 24
                    )
                    Spacer(minLength: 4)
                    BorderlessIconButton(systemImage: "arrow.clockwise", help: L10n.Common.refresh) {
                        environment.refresh(tool)
                    }
                    .disabled(isProviderRefreshing)
                    if isProviderRefreshing {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    }
                }
                HStack(alignment: .center, spacing: 6) {
                    ToolBrandIconView(tool: tool, size: 13)
                        .opacity(0.85)
                    Text(subProviderTitle)
                        .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if resolvedPlanBadge?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        PlanBadgeView(
                            text: resolvedPlanBadge,
                            fontSize: max(9, density.subtitleFontSize - 1)
                        )
                    }
                }
            }

            if let freshnessWarning = currentFreshnessWarning {
                Label(freshnessWarning.label, systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(freshnessWarning.help)
            }

            if !visibleBuckets.isEmpty {
                // One clock for the whole card. Every bucket row used to own a
                // `TimelineView(.periodic(from: .now, by: 30))`, which meant N
                // timers per card, N different tick phases, and therefore N
                // distinct `now` values reaching `QuotaService.paceForecast` —
                // the memo there could never hit. The rows take the date as
                // plain data now, and the shared anchor in `QuotaClockSchedule`
                // makes every card on the page ask for the same instant.
                //
                // Both inputs are resolved *outside* the clock: `visibleBuckets`
                // re-reads the cached quota and `resolvedAccount` scans the
                // account store, and neither answer can change on a tick.
                let buckets = visibleBuckets
                let bucketAccountId = resolvedAccount?.id
                PageClock(interval: 30) { tickDate in
                    bucketContent(buckets, accountId: bucketAccountId, now: tickDate)
                }
                if tool == .codex, let credits = resolvedQuota?.resetCredits, credits.availableCount > 0 {
                    ResetCreditsRow(credits: credits, density: density)
                }
                if let liveError = resolvedLiveError {
                    messageRow(text: L10n.Quota.Update.failed(reason: liveError.userFacingMessage), color: .orange)
                }
            } else if let liveError = resolvedLiveError {
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

    private var resolvedAccount: AccountIdentity? {
        if let accountId {
            return environment.accountStore.accounts.first { $0.id == accountId }
        }
        return environment.account(for: tool)
    }

    private var resolvedQuota: AccountQuota? {
        if let account = resolvedAccount, let cached = quotaService.cachedQuota(for: account.id) {
            return cached
        }
        return accountId == nil ? environment.quota(for: tool) : nil
    }

    private var resolvedLiveError: QuotaError? {
        displayableError(
            resolvedAccount.flatMap { quotaService.lastErrorByAccount[$0.id] },
            with: resolvedQuota
        )
    }

    private var isProviderRefreshing: Bool {
        resolvedAccount.map { quotaService.inFlightAccountIds.contains($0.id) } == true
    }

    private var currentFreshnessWarning: QuotaFreshnessLabel.Description? {
        guard showsFreshnessWarning else { return nil }
        return resolvedAccount.flatMap { freshnessWarning(for: $0, now: Date()) }
    }

    private var resolvedPlanBadge: String? {
        settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: resolvedQuota?.plan,
            accountPlan: resolvedAccount?.plan
        )
    }

    private var visibleBuckets: [QuotaBucket] {
        displayBuckets(from: resolvedQuota)
    }

    private var subProviderTitle: String {
        tool.quotaSubProviderName()
    }

    private func displayBuckets(from quota: AccountQuota?) -> [QuotaBucket] {
        guard let quota else { return [] }
        return quota.buckets.compactMap { bucket in
            guard includedBucketIDs?.contains(bucket.id) ?? true else { return nil }
            guard suppressGroupTitles else { return bucket }
            var copy = bucket
            copy.groupTitle = nil
            return copy
        }
    }

    /// Same composition as `QuotaGroupCard.providerFreshnessWarning`; both go
    /// through `QuotaFreshnessLabel` so the overview card and the provider
    /// page cannot describe one account's staleness two different ways.
    private func freshnessWarning(
        for account: AccountIdentity,
        now: Date
    ) -> QuotaFreshnessLabel.Description? {
        QuotaFreshnessLabel.describe(
            lastSuccessAt: quotaService.lastUpdatedByAccount[account.id],
            lastAttemptAt: quotaService.lastAttemptedByAccount[account.id],
            errorMessage: quotaService.lastErrorByAccount[account.id]?.userFacingMessage,
            staleAfter: TimeInterval(max(300, settingsStore.settings.refreshIntervalSeconds * 2)),
            now: now
        )
    }

    private func bucketContent(
        _ buckets: [QuotaBucket],
        accountId: String?,
        now: Date
    ) -> some View {
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
                        density: density,
                        now: now
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
                        Text(QuotaGroupLabelLocalizer.display(group.title))
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
                                density: density,
                                now: now
                            )
                        }
                    }
                }
            } else if compact, !extras.isEmpty {
                Text(L10n.Quota.perModelLimits(count: extras.count, provider: tool.menuTitle))
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyMessage: String {
        switch tool {
        case .codex:  return L10n.Quota.Login.codex
        case .claude: return L10n.Quota.Login.claude
        case .grok: return L10n.Quota.Login.grok
        case .cursor: return L10n.Quota.Login.cursor
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers route through the Misc page's per-card
            // setup CTA. This empty-message path is only reachable from
            // a primary-provider detail view, but cover misc cases
            // defensively in case a future change reuses the helper.
            return L10n.Quota.Login.misc(provider: tool.menuTitle)
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
                Text(L10n.Quota.ResetCredits.title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text(AppLocale.number(credits.availableCount))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.green)
            }
            Text(subtitle)
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        let available = L10n.Quota.ResetCredits.available(count: credits.availableCount)
        if let expiry = credits.nextExpiresAt,
           let countdown = ResetCountdownFormatter.string(from: expiry, now: Date()) {
            return L10n.Quota.ResetCredits.availableWithExpiry(
                available: available, countdown: countdown
            )
        }
        return available
    }
}

private struct ProviderBucketRow: View {
    let tool: ToolType
    let accountId: String?
    let bucket: QuotaBucket
    let mode: DisplayMode
    let density: Theme.Density
    /// Tick from the enclosing card's single clock. Plain data — this row
    /// starts no timer, however many buckets the card ends up rendering. The
    /// visible cadence is unchanged (30 s, minute-granular countdowns); only
    /// the owner of the clock moved up one level.
    let now: Date

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        content(now: now)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let percent = bucket.displayPercent(mode, tool: tool)
        let pace = UsagePace.compute(bucket: bucket, now: now, allowsPostResetGrace: true)
        let forecast = paceForecast(now: now)
        let timePaceDisplayed = pace.map { expectedDisplay(for: $0, mode: mode) }
        // Same expired-window treatment as `QuotaGroupCard`: past the reset
        // grace this row is drawing the previous cycle, so it says "reset
        // passed" and drops the live percent colour.
        let resetStatus = ResetCountdownFormatter.resetStatus(resetAt: bucket.resetAt, now: now)
        let isExpired = resetStatus?.isExpired ?? false
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(QuotaGroupLabelLocalizer.displayComposed(bucket.title))
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                if let resetStatus {
                    // Same size and scale floor as the primary bucket rows —
                    // see QuotaGroupCard: mismatched caption sizes read as a
                    // typography bug.
                    Text(resetStatus.label)
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .layoutPriority(1)
                }
                Spacer(minLength: 6)
                Text(L10n.Common.percent(value: Int(percent.rounded())))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(
                        isExpired
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Theme.barColor(percent: percent, mode: mode))
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
            bucketBar(
                percent: percent,
                forecast: forecast,
                timePaceDisplayed: timePaceDisplayed
            )
            .opacity(isExpired ? 0.45 : 1)
            if let forecast {
                QuotaForecastRow(
                    forecast: forecast,
                    now: now,
                    fontSize: density.resetCountdownFontSize,
                    displayMode: mode
                )
            } else if let pace {
                UsagePaceRow(pace: pace, now: now, fontSize: density.resetCountdownFontSize)
            }
        }
    }

    @ViewBuilder
    private func bucketBar(
        percent: Double,
        forecast: QuotaPaceForecast?,
        timePaceDisplayed: Double?
    ) -> some View {
        Group {
            if let forecast {
                ForecastQuotaBar(
                    percent: percent,
                    mode: mode,
                    timePacePercent: timePaceDisplayed,
                    forecastProjection: QuotaForecastBarProjection(
                        projectedUsedLowerPercent: forecast.projectedUsedLowerPercent,
                        projectedUsedUpperPercent: forecast.projectedUsedUpperPercent,
                        projectedUsedMedianPercent: forecast.projectedUsedPercent,
                        displayMode: mode
                    ),
                    forecastColor: QuotaForecastPalette.color(for: forecast.verdict),
                    height: density.bucketBarHeight
                )
            } else if let timePaceDisplayed {
                PaceMarkerCapsule(
                    usedPercent: percent,
                    expectedPercent: timePaceDisplayed,
                    mode: mode,
                    height: density.bucketBarHeight
                )
            } else {
                QuotaBarShape(percent: percent, mode: mode, height: density.bucketBarHeight)
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
            now: now,
            allowsPostResetGrace: true
        )
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
