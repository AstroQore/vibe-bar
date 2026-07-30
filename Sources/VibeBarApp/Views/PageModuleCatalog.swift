import SwiftUI
import VibeBarCore

/// Colour family a module belongs to, used by the layout editor's accent
/// stripe. Deliberately coarse: the editor is telling the user "this block is
/// the Claude quota card", not re-drawing the card.
enum PageModuleAccent {
    case provider(ToolType)
    case cost
    case neutral

    var color: Color {
        switch self {
        case let .provider(tool): Theme.providerAccent(for: tool)
        case .cost: Color.accentColor
        case .neutral: Color.secondary
        }
    }
}

/// What a module *is*, as a payload-free tag.
///
/// The tag is the contract between the two halves of the registry: the catalog
/// decides which modules a page has (and what they are called, where they
/// default to, what colour they wear), and the page's own `content(for:)`
/// switch turns each tag back into the real card using data it already
/// computed. Keeping the payloads out means the Settings editor can enumerate
/// a page's modules without building — or even being able to build — its
/// views.
enum PageModuleKind: Hashable {
    // Overview
    case overviewQuota(ToolType)
    case overviewQuotaHistoryAll
    case overviewCostAll
    case overviewCost(ToolType)
    case overviewModelRanking
    case overviewYearHeatmap
    case overviewActivityHeatmap
    // Provider detail
    /// Carries `QuotaGroupModule.id` so the page can find the live group again.
    case quotaGroup(String)
    case serviceStatus
    case costHeader
    case costHistory
    case modelRanking
    case yearHeatmap
    case activityHeatmap
    case costEmpty
}

/// One module a page can render, described well enough for the layout editor
/// to draw and arrange it without touching the card itself.
struct PageModuleDescriptor: Identifiable {
    let id: PageLayoutModuleID
    let kind: PageModuleKind
    let displayName: String
    /// Column this module occupies in the page's built-in arrangement. Used to
    /// build the default config, which is also where the resolver drops a
    /// module the saved layout has never seen.
    let defaultColumn: Int
    let accent: PageModuleAccent
    /// Phase the Overview's auto-balancing waterfall places this card in.
    /// Ignored on provider pages, which have no auto mode.
    let masonryPhase: OverviewMasonryPhase
    /// Stand-in height for the editor before this card has ever been rendered.
    let fallbackHeight: Double
}

/// The single registry of page modules.
///
/// Both halves of the feature read this: the popover pages render exactly the
/// descriptors it returns, and the Settings layout editor arranges exactly the
/// same list. There is no second, hand-maintained table of "modules the editor
/// knows about" to drift out of step.
enum PageModuleCatalog {
    // MARK: - Fallback heights

    private enum FallbackHeight {
        static let quota: Double = 260
        static let quotaHistory: Double = 300
        static let cost: Double = 320
        static let analytics: Double = 200
        static let status: Double = 150
        static let placeholder: Double = 90
    }

    // MARK: - Pages

    /// Layout-editable pages, in the order the popover's tab strip shows them.
    /// Driven by the same `OverviewPage` enumeration the tab strip uses, so a
    /// provider hidden from the popover disappears from the editor too.
    static func editablePages(settings: AppSettings) -> [(page: PageLayoutPageID, title: String)] {
        OverviewPage.visiblePages(settings: settings).compactMap { page in
            guard let id = page.layoutPageID else { return nil }
            return (id, page.label)
        }
    }

    // MARK: - Descriptors

    @MainActor
    static func descriptors(
        for page: PageLayoutPageID,
        environment: AppEnvironment,
        settings: AppSettings
    ) -> [PageModuleDescriptor] {
        if page.isOverview {
            return overviewDescriptors(environment: environment, settings: settings)
        }
        guard let tool = page.detailTool else { return [] }
        return detailDescriptors(tool: tool, environment: environment, settings: settings)
    }

    @MainActor
    private static func overviewDescriptors(
        environment: AppEnvironment,
        settings: AppSettings
    ) -> [PageModuleDescriptor] {
        var result: [PageModuleDescriptor] = []
        // Order below is the order `OverviewWaterfall` hands the cards to
        // `ColumnMasonryLayout`. The planner's quota/cost pairing depends on
        // it, so the two must not diverge.
        for tool in settings.visibleCoreProviderList {
            result.append(
                PageModuleDescriptor(
                    id: .custom("overview-quota:\(tool.rawValue)"),
                    kind: .overviewQuota(tool),
                    displayName: "\(tool.menuTitle) Quota",
                    defaultColumn: 0,
                    accent: .provider(tool),
                    masonryPhase: .quota,
                    fallbackHeight: FallbackHeight.quota
                )
            )
        }
        result.append(
            PageModuleDescriptor(
                id: .quotaHistoryAll,
                kind: .overviewQuotaHistoryAll,
                displayName: "All Providers Quota History",
                defaultColumn: 0,
                accent: .neutral,
                masonryPhase: .quota,
                fallbackHeight: FallbackHeight.quotaHistory
            )
        )
        let hasCostData = self.hasCostData(environment: environment, settings: settings)
        if hasCostData {
            result.append(
                PageModuleDescriptor(
                    id: .costAll,
                    kind: .overviewCostAll,
                    displayName: "All Providers Cost History",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .cost,
                    fallbackHeight: FallbackHeight.cost
                )
            )
        }
        for tool in overviewCostProviders(settings: settings) {
            result.append(
                PageModuleDescriptor(
                    id: .cost(tool: tool),
                    kind: .overviewCost(tool),
                    displayName: "\(tool.menuTitle) Cost",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .cost,
                    fallbackHeight: FallbackHeight.cost
                )
            )
        }
        if settings.isCoreProviderVisible(.gemini) {
            result.append(
                PageModuleDescriptor(
                    id: .cost(tool: .gemini),
                    kind: .overviewCost(.gemini),
                    displayName: "Gemini Cost",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .cost,
                    fallbackHeight: FallbackHeight.cost
                )
            )
        }
        if hasCostData {
            result.append(
                PageModuleDescriptor(
                    id: .custom("model-breakdown:all"),
                    kind: .overviewModelRanking,
                    displayName: "Model Ranking",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .auxiliary,
                    fallbackHeight: FallbackHeight.analytics
                )
            )
            result.append(
                PageModuleDescriptor(
                    id: .custom("heatmap-year:all"),
                    kind: .overviewYearHeatmap,
                    displayName: "Contribution Heatmap",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .auxiliary,
                    fallbackHeight: FallbackHeight.analytics
                )
            )
            result.append(
                PageModuleDescriptor(
                    id: .custom("heatmap-activity:all"),
                    kind: .overviewActivityHeatmap,
                    displayName: "Activity Heatmap",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .auxiliary,
                    fallbackHeight: FallbackHeight.analytics
                )
            )
        }
        return result
    }

    @MainActor
    private static func detailDescriptors(
        tool: ToolType,
        environment: AppEnvironment,
        settings: AppSettings
    ) -> [PageModuleDescriptor] {
        var result: [PageModuleDescriptor] = []
        // Left column: one card per quota group, then service status — the
        // hand-coded order the provider pages have always used.
        for module in quotaGroupModules(tool: tool, environment: environment) {
            result.append(
                PageModuleDescriptor(
                    // `QuotaGroupModule.id` is byte-identical to
                    // `PageLayoutModuleID.quotaGroup(tool:groupKey:)` except
                    // for the `#2` suffix it adds when one heading legitimately
                    // appears twice. Using it verbatim keeps those two cards
                    // distinct instead of letting the config dedupe swallow one.
                    id: PageLayoutModuleID(rawValue: module.id),
                    kind: .quotaGroup(module.id),
                    displayName: quotaGroupDisplayName(module),
                    defaultColumn: 0,
                    accent: .provider(module.tool),
                    masonryPhase: .quota,
                    fallbackHeight: FallbackHeight.quota
                )
            )
        }
        result.append(
            PageModuleDescriptor(
                id: .status,
                kind: .serviceStatus,
                displayName: "Service Status",
                defaultColumn: 0,
                accent: .neutral,
                masonryPhase: .quota,
                fallbackHeight: FallbackHeight.status
            )
        )

        // Right column: cost, then the analytics derived from it.
        let costTitle = tool == .gemini ? "Gemini" : tool.menuTitle
        guard let snapshot = detailCostSnapshot(tool: tool, environment: environment),
              snapshot.jsonlFilesFound > 0
        else {
            result.append(
                PageModuleDescriptor(
                    id: .custom("cost-empty:\(tool.rawValue)"),
                    kind: .costEmpty,
                    displayName: "\(costTitle) Cost — no data",
                    defaultColumn: 1,
                    accent: .cost,
                    masonryPhase: .cost,
                    fallbackHeight: FallbackHeight.placeholder
                )
            )
            return result
        }
        result.append(
            PageModuleDescriptor(
                id: .cost(tool: tool),
                kind: .costHeader,
                displayName: "\(costTitle) Cost",
                defaultColumn: 1,
                accent: .cost,
                masonryPhase: .cost,
                fallbackHeight: FallbackHeight.cost
            )
        )
        result.append(
            PageModuleDescriptor(
                id: .custom("cost-history:\(tool.rawValue)"),
                kind: .costHistory,
                displayName: "\(costTitle) Cost History",
                defaultColumn: 1,
                accent: .cost,
                masonryPhase: .cost,
                fallbackHeight: FallbackHeight.cost
            )
        )
        result.append(
            PageModuleDescriptor(
                id: .modelBreakdown(tool: tool),
                kind: .modelRanking,
                displayName: "Model Ranking",
                defaultColumn: 1,
                accent: .cost,
                masonryPhase: .auxiliary,
                fallbackHeight: FallbackHeight.analytics
            )
        )
        result.append(
            PageModuleDescriptor(
                id: .custom("heatmap-year:\(tool.rawValue)"),
                kind: .yearHeatmap,
                displayName: "Contribution Heatmap",
                defaultColumn: 1,
                accent: .cost,
                masonryPhase: .auxiliary,
                fallbackHeight: FallbackHeight.analytics
            )
        )
        result.append(
            PageModuleDescriptor(
                id: .custom("heatmap-activity:\(tool.rawValue)"),
                kind: .activityHeatmap,
                displayName: "Activity Heatmap",
                defaultColumn: 1,
                accent: .cost,
                masonryPhase: .auxiliary,
                fallbackHeight: FallbackHeight.analytics
            )
        )
        return result
    }

    private static func quotaGroupDisplayName(_ module: QuotaGroupModule) -> String {
        let scope = module.title ?? "All Models"
        // A linked product's groups (AntiGravity under Gemini) say whose they
        // are; the page tool's own groups do not need repeating.
        guard module.tool != module.pageTool else { return scope }
        return "\(module.tool.toolName) · \(scope)"
    }

    // MARK: - Shared page data

    /// The quota-group cards a provider page draws, including the signed-out
    /// placeholder. Shared by the pages and by the editor so a group that
    /// appears mid-session (a bucket arriving after a refresh) shows up in both
    /// at the same moment.
    @MainActor
    static func quotaGroupModules(
        tool: ToolType,
        environment: AppEnvironment
    ) -> [QuotaGroupModule] {
        let buckets: [QuotaBucket]
        let accountId: String?
        var additional: [FillTimelineSeries] = []
        if tool == .gemini {
            let geminiAccount = environment.accountStore
                .accounts(for: .gemini)
                .sorted { $0.id < $1.id }
                .first
            accountId = geminiAccount?.id
            buckets = geminiAccount.flatMap {
                environment.quotaService.cachedQuota(for: $0.id)?.buckets
            } ?? []
            if let antigravity = environment.account(for: .antigravity) {
                additional = (environment.quotaService.cachedQuota(for: antigravity.id)?.buckets ?? [])
                    .map { FillTimelineSeries(tool: .antigravity, accountId: antigravity.id, bucket: $0) }
            }
        } else {
            accountId = environment.account(for: tool)?.id
            buckets = environment.quota(for: tool)?.buckets ?? []
        }
        let modules = QuotaGroupModuleBuilder.modules(
            pageTool: tool,
            buckets: buckets,
            primaryAccountId: accountId,
            additionalQuotaSeries: additional
        )
        guard modules.isEmpty else { return modules }
        return [QuotaGroupModuleBuilder.placeholderModule(pageTool: tool, accountId: accountId)]
    }

    /// Tools whose refresh button the provider-header quota card pumps.
    static func quotaRefreshTools(for tool: ToolType) -> [ToolType] {
        tool == .gemini ? ToolType.googleAIPair : [tool]
    }

    /// Cost snapshot behind a provider page. Gemini's page shows the combined
    /// Gemini + AntiGravity total under one "Gemini" label.
    @MainActor
    static func detailCostSnapshot(
        tool: ToolType,
        environment: AppEnvironment
    ) -> CostSnapshot? {
        guard tool == .gemini else { return environment.costService.snapshot(for: tool) }
        return googleAICostSnapshot(environment: environment)
    }

    /// Combined Gemini + AntiGravity cost, surfaced as the single "Gemini"
    /// (Google AI) platform.
    ///
    /// Routed through the service's memo rather than combining here: combining
    /// re-rebases both providers and re-buckets ~720 hourly keys, and this is
    /// asked for from the module catalog, the Overview's Gemini card, and the
    /// Gemini page — all within one render pass.
    @MainActor
    static func googleAICostSnapshot(environment: AppEnvironment) -> CostSnapshot {
        environment.costService.combinedSnapshot(
            of: ToolType.googleAIPair,
            labelledAs: .antigravity
        )
    }

    /// Cost providers rendered as their own per-provider card on the Overview.
    /// Google AI is rendered separately (combined Gemini + AntiGravity), so it
    /// is not listed here.
    static func overviewCostProviders(settings: AppSettings) -> [ToolType] {
        settings.visibleCoreProviderList.filter { tool in
            tool == .codex || tool == .claude || tool == .grok
        }
    }

    /// Every cross-provider rollup the Overview's "all providers" cards need,
    /// as one memoized value: the per-provider snapshots, the combined daily
    /// history, heatmap, model ranking and combined snapshot.
    ///
    /// One call per render pass, and the answer is cached in
    /// `CostUsageService` until the next cost refresh or the next local day.
    /// The Overview used to derive these four separate times per `body` — once
    /// inside the module catalog, once for the context, once for the
    /// all-providers cost card and once for the Gemini card — each of which
    /// re-rebased every provider's whole daily history.
    @MainActor
    static func overviewRollup(
        environment: AppEnvironment,
        settings: AppSettings
    ) -> CostRollup {
        environment.costService.rollup(
            individualTools: overviewCostProviders(settings: settings),
            // The Gemini group is labelled `.antigravity` for the same reason
            // `googleAICostSnapshot` is: AntiGravity is the live Google usage
            // source, and both call sites must land on the same cached snapshot.
            groups: settings.isCoreProviderVisible(.gemini)
                ? [CostSnapshotGroup(label: .antigravity, tools: ToolType.googleAIPair)]
                : [],
            labelledAs: .codex
        )
    }

    /// Whether the Overview has any cost data at all.
    ///
    /// Answered from raw file counts, never from a rollup: `jsonlFilesFound`
    /// survives rebasing and combining untouched, so the question that decides
    /// whether the cost and analytics modules exist costs a handful of
    /// dictionary lookups instead of a full cross-provider combine.
    @MainActor
    static func hasCostData(environment: AppEnvironment, settings: AppSettings) -> Bool {
        var tools = overviewCostProviders(settings: settings)
        if settings.isCoreProviderVisible(.gemini) {
            tools.append(contentsOf: ToolType.googleAIPair)
        }
        return environment.costService.hasJSONLFiles(in: tools)
    }

    // MARK: - Default configuration

    /// The page's built-in arrangement, i.e. what a user who never opens the
    /// editor sees.
    ///
    /// Provider pages have a hand-coded split, so their default is simply the
    /// descriptors' own `defaultColumn`. The Overview has no hand-coded split —
    /// it auto-balances — so its default is what the balancer would produce
    /// from the last measured heights, computed with the same Core planner the
    /// live waterfall uses. That keeps the editor's "before you touched it"
    /// picture honest instead of showing an arrangement the popover never had.
    static func defaultConfig(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor],
        measuredHeights: [PageLayoutModuleID: Double],
        spacing: Double
    ) -> PageLayoutConfig {
        guard page.isOverview else {
            var columns = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
            for descriptor in descriptors {
                let column = min(max(0, descriptor.defaultColumn), PageLayoutConfig.columnCount - 1)
                columns[column].append(descriptor.id)
            }
            return PageLayoutConfig(ratio: defaultRatio(for: page), columns: columns)
        }

        let items = descriptors.map { descriptor in
            OverviewMasonryPlanner.Item(
                id: descriptor.id.rawValue,
                height: measuredHeights[descriptor.id] ?? descriptor.fallbackHeight,
                phase: descriptor.masonryPhase.corePhase
            )
        }
        let plan = OverviewMasonryPlanner.plan(items: items, columns: 2, spacing: spacing)
        var columns = [[(module: PageLayoutModuleID, y: Double)]](
            repeating: [],
            count: PageLayoutConfig.columnCount
        )
        for descriptor in descriptors {
            guard let position = plan.positions[descriptor.id.rawValue] else {
                columns[0].append((descriptor.id, .greatestFiniteMagnitude))
                continue
            }
            let column = min(max(0, position.column), PageLayoutConfig.columnCount - 1)
            columns[column].append((descriptor.id, position.y))
        }
        return PageLayoutConfig(
            ratio: defaultRatio(for: page),
            columns: columns.map { column in
                column.sorted { $0.y < $1.y }.map(\.module)
            }
        )
    }

    /// Width split a page falls back to. Provider pages are narrow-left by
    /// design; the Overview balances two equal columns.
    static func defaultRatio(for page: PageLayoutPageID) -> PageColumnRatio {
        page.isOverview ? .equal : .narrowWide
    }
}
