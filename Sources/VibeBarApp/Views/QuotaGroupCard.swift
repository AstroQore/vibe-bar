import SwiftUI
import VibeBarCore

/// One quota group, resolved into everything its card needs to draw itself.
///
/// A "group" is exactly what `QuotaBucketGrouping` already means by one: a
/// contiguous run of rows sharing a heading, including the unnamed run (Claude's
/// 5 Hours + Weekly — "all models") that prints no heading. Splitting the old
/// single Subscription Utilization card into one card per group is a layout
/// change only; the grouping itself still comes from `QuotaBucketGrouping`, so a
/// heading, a card boundary and a history chart can never disagree.
struct QuotaGroupModule: Identifiable {
    /// One live quota row inside the group.
    struct Row: Identifiable {
        let id: String
        /// The tool this bucket actually came from — differs from the module's
        /// page tool only for linked SubProviders (AntiGravity on Google AI).
        let tool: ToolType
        let accountId: String?
        let bucket: QuotaBucket
    }

    /// Layout-engine identity: `"quota-group:<tool>:<groupKey>"`. Stable across
    /// launches and across re-logins — see `QuotaBucketGrouping.moduleID`.
    let id: String
    /// The group's slug on its own, so the layout engine can rebuild this
    /// module's identity through `PageLayoutModuleID.quotaGroup(tool:groupKey:)`
    /// and land on the same string `id` already holds.
    let groupKey: String
    /// The provider page the card is drawn on.
    let pageTool: ToolType
    /// The tool the group's buckets came from.
    let tool: ToolType
    let accountId: String?
    /// The group's heading, `nil` for the unnamed run.
    let title: String?
    /// Whether the quota/model group heading is distinct from its SubProvider
    /// heading. Grok Bot is itself a SubProvider, not a model group.
    let showsGroupTitle: Bool
    /// Account-scoped identity of the group's history chart. Unchanged from the
    /// pre-split card so an existing chart keeps its state.
    let chartKey: String
    let rows: [Row]
    /// Set on the first card of a SubProvider run (ChatGPT Agentic, Claude,
    /// Gemini Web, AntiGravity, Grok, Cursor, or Grok Bot).
    let linkedSectionTitle: String?
    let linkedSectionIconTool: ToolType?
    /// Set on the first card of the page. It inherits the provider header —
    /// brand icon, product name, plan badge, refresh button — that the single
    /// pre-split card carried at the top.
    let showsProviderHeader: Bool

    /// Every bucket in the group, in provider order. This is what the group's
    /// history chart plots.
    var groupBuckets: [QuotaBucket] { rows.map(\.bucket) }
}

/// Resolves a provider page's quota buckets into the per-group card modules the
/// page renders, preserving the pre-split card's ordering exactly: primary
/// buckets first in provider order, then any linked SubProvider's, split wherever
/// `QuotaBucketGrouping.key` changes.
enum QuotaGroupModuleBuilder {
    private struct RawBucket {
        let id: String
        let tool: ToolType
        let accountId: String?
        let bucket: QuotaBucket
    }

    /// - Parameters:
    ///   - pageTool: the provider page being rendered.
    ///   - buckets: the page tool's own live quotas.
    ///   - primaryAccountId: account behind `buckets`, `nil` when signed out.
    ///   - additionalQuotaSeries: linked SubProviders stacked under the page
    ///     tool (AntiGravity on Google AI).
    static func modules(
        pageTool: ToolType,
        buckets: [QuotaBucket],
        primaryAccountId: String?,
        additionalQuotaSeries: [FillTimelineSeries]
    ) -> [QuotaGroupModule] {
        let primary = buckets.map {
            RawBucket(
                id: "primary:\(pageTool.rawValue):\($0.id)",
                tool: pageTool,
                accountId: primaryAccountId,
                bucket: $0
            )
        }
        let additional = additionalQuotaSeries.map {
            RawBucket(id: $0.id, tool: $0.tool, accountId: $0.accountId, bucket: $0.bucket)
        }
        let raw = primary + additional
        guard !raw.isEmpty else { return [] }

        // Groups are runs of adjacent rows sharing a chart key — the same
        // contiguity the pre-split card's heading logic assumed, so the card
        // boundaries land exactly where the headings and charts already did.
        let titles = raw.map {
            QuotaBucketGrouping.title(pageTool: pageTool, itemTool: $0.tool, bucket: $0.bucket)
        }
        let chartKeys = zip(raw, titles).map {
            QuotaBucketGrouping.key(accountId: $0.0.accountId, itemTool: $0.0.tool, title: $0.1)
        }

        var modules: [QuotaGroupModule] = []
        var moduleIDCounts: [String: Int] = [:]
        var seenSectionKeys: Set<String> = []
        var index = 0
        while index < raw.count {
            var end = index
            while end + 1 < raw.count, chartKeys[end + 1] == chartKeys[index] { end += 1 }
            let head = raw[index]
            let title = titles[index]

            // A SubProvider name is printed once on the first card in its run.
            // Grok Bot is a distinct SubProvider even though its quota comes
            // from the Cursor dashboard adapter.
            var linkedSectionTitle: String?
            let resolvedSubProviderTitle = head.tool.quotaSubProviderName(bucketID: head.bucket.id)
            let sectionKey = "\(head.tool.rawValue):\(resolvedSubProviderTitle)"
            if seenSectionKeys.insert(sectionKey).inserted {
                linkedSectionTitle = resolvedSubProviderTitle
            }

            // Two runs can in principle carry the same heading (a heading that
            // reappears after another one). Keep `ForEach` identity unique
            // without perturbing the common single-run id.
            let groupKey = QuotaBucketGrouping.slug(title: title)
            let baseID = QuotaBucketGrouping.moduleID(tool: head.tool, title: title)
            let occurrence = (moduleIDCounts[baseID] ?? 0) + 1
            moduleIDCounts[baseID] = occurrence

            modules.append(
                QuotaGroupModule(
                    id: occurrence == 1 ? baseID : "\(baseID)#\(occurrence)",
                    groupKey: groupKey,
                    pageTool: pageTool,
                    tool: head.tool,
                    accountId: head.accountId,
                    title: title,
                    showsGroupTitle: !(head.tool == .cursor && head.bucket.id == "grok_bot_weekly"),
                    chartKey: chartKeys[index],
                    rows: raw[index...end].map {
                        QuotaGroupModule.Row(
                            id: $0.id,
                            tool: $0.tool,
                            accountId: $0.accountId,
                            bucket: $0.bucket
                        )
                    },
                    linkedSectionTitle: linkedSectionTitle,
                    linkedSectionIconTool: head.tool == .cursor && head.bucket.id == "grok_bot_weekly"
                        ? .grok
                        : head.tool,
                    showsProviderHeader: modules.isEmpty
                )
            )
            index = end + 1
        }
        return modules
    }

    /// The card a page shows when it has no live quota at all — signed out, or
    /// nothing fetched yet. It still carries the provider header and its
    /// refresh button, exactly as the pre-split card did.
    ///
    /// Its identity is the identity of the group that will *replace* it. A
    /// page's first real group is the page tool's own unnamed run, whose
    /// heading is whatever `QuotaBucketGrouping.forcedTitle` imposes — `nil`
    /// for most providers (slug `all`), "Gemini Chat" on the Gemini page (slug
    /// `gemini-chat`). Reading it from that one function rather than hardcoding
    /// `nil` is what keeps a layout arranged while signed out from being
    /// discarded as a stale identifier once buckets arrive.
    static func placeholderModule(pageTool: ToolType, accountId: String?) -> QuotaGroupModule {
        let title = QuotaBucketGrouping.forcedTitle(pageTool: pageTool, itemTool: pageTool)
        return QuotaGroupModule(
            id: QuotaBucketGrouping.moduleID(tool: pageTool, title: title),
            groupKey: QuotaBucketGrouping.slug(title: title),
            pageTool: pageTool,
            tool: pageTool,
            accountId: accountId,
            title: title,
            showsGroupTitle: true,
            chartKey: QuotaBucketGrouping.key(accountId: nil, itemTool: pageTool, title: title),
            rows: [],
            linkedSectionTitle: pageTool.quotaSubProviderName(),
            linkedSectionIconTool: pageTool,
            showsProviderHeader: true
        )
    }

}

/// One quota group as a self-contained card module.
///
/// Fixed internal order: group header → the group's bucket rows (bar, pace and
/// forecast markers, verdict, forecast disclosure) → each row's "Reset history"
/// strip → the group's quota-history chart. Everything below the header is the
/// content the pre-split Subscription Utilization card drew inline; only the
/// card boundary is new.
struct QuotaGroupCard: View {
    let module: QuotaGroupModule
    let mode: DisplayMode
    let density: Theme.Density
    let now: Date
    /// Tools the header's refresh button pumps. Only the provider-header card
    /// draws that button, so only it needs these.
    var refreshTools: [ToolType] = []
    /// Drawn instead of the rows when the page has no live quota at all.
    var emptyMessage: String?

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService
    @State private var expandedForecastIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header
            if let emptyMessage {
                Text(emptyMessage)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(module.rows) { row in
                    self.row(for: row)
                }
                groupHistoryChart
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

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            if module.showsProviderHeader {
                HStack(alignment: .center, spacing: 8) {
                    ProviderSectionTitle(
                        tool: module.pageTool,
                        title: module.pageTool.vendorName,
                        subtitle: nil,
                        titleFontSize: density.titleFontSize,
                        subtitleFontSize: density.subtitleFontSize,
                        iconSize: 16,
                        badgeSize: 24
                    )
                    Spacer(minLength: 4)
                    SectionRefreshButton(isRefreshing: isRefreshing) {
                        for refreshTool in refreshTools {
                            environment.refresh(refreshTool)
                        }
                    }
                }
            }
            if let linkedSectionTitle = module.linkedSectionTitle {
                // The pre-split card separated a linked SubProvider's rows with a
                // divider; the card boundary does that now, so only the name
                // and brand icon survive.
                HStack(alignment: .center, spacing: 6) {
                    ToolBrandIconView(tool: module.linkedSectionIconTool ?? module.tool, size: 13)
                        .opacity(0.85)
                    Text(linkedSectionTitle)
                        .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let subProviderPlanBadge {
                        PlanBadgeView(
                            text: subProviderPlanBadge,
                            fontSize: max(9, density.subtitleFontSize - 1)
                        )
                    }
                }
            }
            if let warning = providerFreshnessWarning {
                Label(warning.label, systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(warning.help)
            }
            if module.showsGroupTitle, let title = module.title {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                }
            }
        }
    }

    private var isRefreshing: Bool {
        refreshTools.contains { refreshTool in
            guard let id = environment.account(for: refreshTool)?.id else { return false }
            return quotaService.inFlightAccountIds.contains(id)
        }
    }

    private var providerFreshnessWarning: QuotaFreshnessLabel.Description? {
        guard module.showsProviderHeader || module.linkedSectionTitle != nil,
              let accountId = module.accountId
        else { return nil }
        return QuotaFreshnessLabel.describe(
            lastSuccessAt: quotaService.lastUpdatedByAccount[accountId],
            lastAttemptAt: quotaService.lastAttemptedByAccount[accountId],
            errorMessage: quotaService.lastErrorByAccount[accountId]?.userFacingMessage,
            staleAfter: TimeInterval(max(300, settingsStore.settings.refreshIntervalSeconds * 2)),
            now: now
        )
    }

    private var subProviderPlanBadge: String? {
        let account = environment.account(for: module.tool)
        let quotaPlan = account.flatMap { quotaService.cachedQuota(for: $0.id)?.plan }
            ?? environment.quota(for: module.tool)?.plan
        let label = settingsStore.settings.planBadgeLabel(
            for: module.tool,
            quotaPlan: quotaPlan,
            accountPlan: account?.plan
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return label?.isEmpty == false ? label : nil
    }

    // MARK: - Group history chart

    @ViewBuilder
    private var groupHistoryChart: some View {
        if let accountId = module.accountId, !module.rows.isEmpty {
            // `.equatable()` is load-bearing, not an optimisation: this card is
            // re-proposed every 30 seconds by the `TimelineView` the rows above
            // need for their countdowns, and the chart reads no clock of its
            // own. Without it every tick would re-segment and re-thin thousands
            // of marks — and could land mid-pan.
            QuotaHistoryChartView(
                tool: module.tool,
                accountId: accountId,
                group: QuotaBucketGroup(
                    id: module.chartKey,
                    title: module.title,
                    buckets: module.groupBuckets
                ),
                fillPointsByBucket: fillPointsByBucket(
                    accountId: accountId,
                    buckets: module.groupBuckets
                ),
                density: density,
                isEmbedded: true
            )
            .equatable()
        }
    }

    /// The chart's fill lanes, read here instead of inside the chart.
    ///
    /// This card already observes `QuotaService`, so pulling the lanes out here
    /// costs nothing extra — while an `@EnvironmentObject` read *inside* the
    /// `.equatable()` chart invalidated it directly on every service publish,
    /// straight past the diff that is supposed to keep a refresh from
    /// re-segmenting thousands of marks.
    private func fillPointsByBucket(
        accountId: String,
        buckets: [QuotaBucket]
    ) -> [String: [FillTimelinePoint]] {
        var lanes: [String: [FillTimelinePoint]] = [:]
        for bucket in buckets {
            let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucket.id)
            if let points = quotaService.observationsByAccountBucket[key] {
                lanes[bucket.id] = points
            }
        }
        return lanes
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: QuotaGroupModule.Row) -> some View {
        let bucket = item.bucket
        let pace = UsagePace.compute(bucket: bucket, now: now, allowsPostResetGrace: true)
        let forecast = paceForecast(for: item)
        let used = bucket.displayPercent(.used, tool: item.tool)
        let timeExpected = pace.map { displayedPercent(fromUsed: $0.expectedUsedPercent) }
        let forecastProjection = forecast.map {
            QuotaForecastBarProjection(
                projectedUsedLowerPercent: $0.projectedUsedLowerPercent,
                projectedUsedUpperPercent: $0.projectedUsedUpperPercent,
                projectedUsedMedianPercent: $0.projectedUsedPercent,
                displayMode: mode
            )
        }
        // A window that already rolled over is showing the previous cycle's
        // fill. Say so on the reset line and pull the percentage and bar back
        // to secondary, so a stale 100% cannot pass for a live one.
        let resetStatus = ResetCountdownFormatter.resetStatus(resetAt: bucket.resetAt, now: now)
        let isExpired = resetStatus?.isExpired ?? false
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                if let resetStatus {
                    // One size and one scale floor for every provider — the
                    // per-tool bump and the 0.80 shrink made visually
                    // different caption sizes from row to row.
                    Text(resetStatus.label)
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .layoutPriority(1)
                }
                Spacer(minLength: 6)
                Text(percentLabel(used: used))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isExpired ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            quotaReferenceBar(used: used, pace: pace, forecast: forecast)
                .opacity(isExpired ? 0.45 : 1)
            percentageAxis
            referenceLegend(
                timeExpected: timeExpected,
                forecastExpected: forecastProjection?.medianPercent,
                forecastColor: forecast.map { QuotaForecastPalette.color(for: $0.verdict) }
            )
            Text(SubscriptionWindowProgress.summary(
                usedPercent: used,
                resetAt: bucket.resetAt,
                rawWindowSeconds: bucket.rawWindowSeconds,
                displayMode: mode,
                now: now
            ))
                .font(.system(size: density.subtitleFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let forecast {
                QuotaForecastRow(
                    forecast: forecast,
                    now: now,
                    fontSize: density.subtitleFontSize,
                    showGuidance: true,
                    displayMode: mode
                )
            } else if let pace {
                HStack(spacing: 6) {
                    Text(pace.stageSummary)
                        .font(.system(size: density.subtitleFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(etaText(pace: pace))
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            if let series = historySeries(for: item) {
                FillTimelineChart(
                    series: series,
                    mode: mode,
                    density: density,
                    targetPercent: forecast.map(displayedTarget)
                )
            }
            if let forecast {
                forecastExplanation(itemID: item.id, forecast: forecast, pace: pace)
            }
        }
    }

    @ViewBuilder
    private func quotaReferenceBar(
        used: Double,
        pace: UsagePace?,
        forecast: QuotaPaceForecast?
    ) -> some View {
        let barHeight = max(10, density.bucketBarHeight)
        if let forecast {
            ForecastQuotaBar(
                percent: displayedPercent(fromUsed: used),
                mode: mode,
                timePacePercent: pace.map { displayedPercent(fromUsed: $0.expectedUsedPercent) },
                forecastProjection: QuotaForecastBarProjection(
                    projectedUsedLowerPercent: forecast.projectedUsedLowerPercent,
                    projectedUsedUpperPercent: forecast.projectedUsedUpperPercent,
                    projectedUsedMedianPercent: forecast.projectedUsedPercent,
                    displayMode: mode
                ),
                forecastColor: QuotaForecastPalette.color(for: forecast.verdict),
                height: barHeight
            )
        } else if let pace {
            PaceMarkerCapsule(
                usedPercent: displayedPercent(fromUsed: used),
                expectedPercent: displayedPercent(fromUsed: pace.expectedUsedPercent),
                mode: mode,
                height: barHeight
            )
        } else {
            QuotaBarShape(percent: displayedPercent(fromUsed: used), mode: mode, height: barHeight)
        }
    }

    private var percentageAxis: some View {
        HStack(spacing: 0) {
            ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                Text(L10n.Common.percent(value: value))
                    .font(.system(size: max(8, density.subtitleFontSize - 3), design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
                if value < 100 {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func paceForecast(for item: QuotaGroupModule.Row) -> QuotaPaceForecast? {
        guard let accountId = item.accountId else { return nil }
        let snapshot = environment.costService.snapshot(for: item.tool)
        return quotaService.paceForecast(
            accountId: accountId,
            bucket: item.bucket,
            activityHeatmap: snapshot?.heatmap,
            dailyActivity: snapshot?.dailyHistory ?? [],
            now: now,
            allowsPostResetGrace: true
        )
    }

    @ViewBuilder
    private func referenceLegend(
        timeExpected: Double?,
        forecastExpected: Double?,
        forecastColor: Color?
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                referenceItems(
                    timeExpected: timeExpected,
                    forecastExpected: forecastExpected,
                    forecastColor: forecastColor
                )
                Spacer(minLength: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        referenceItems(
                            timeExpected: timeExpected,
                            forecastExpected: forecastExpected,
                            forecastColor: forecastColor
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        referenceItems(
                            timeExpected: timeExpected,
                            forecastExpected: forecastExpected,
                            forecastColor: forecastColor
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func referenceItems(
        timeExpected: Double?,
        forecastExpected: Double?,
        forecastColor: Color?
    ) -> some View {
        if let timeExpected {
            referenceLegendItem(
                color: .secondary,
                markerStyle: .timePace,
                label: L10n.Quota.forecastMetricTimePace,
                value: modeValue(percent: Int(timeExpected.rounded()))
            )
        }
        if let forecastExpected, let forecastColor {
            referenceLegendItem(
                color: forecastColor,
                markerStyle: .forecast,
                label: L10n.Quota.forecastMetricForecastAtReset,
                value: modeValue(percent: Int(forecastExpected.rounded()))
            )
        }
    }

    private enum ReferenceMarkerStyle {
        case timePace
        case forecast
    }

    private func referenceLegendItem(
        color: Color,
        markerStyle: ReferenceMarkerStyle,
        label: String,
        value: String
    ) -> some View {
        HStack(spacing: 5) {
            referenceMarker(style: markerStyle, color: color)
            Text(L10n.Quota.forecastLegendItem(label: label, value: value))
                .font(.system(size: max(8, density.subtitleFontSize - 1), weight: .medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func referenceMarker(style: ReferenceMarkerStyle, color: Color) -> some View {
        switch style {
        case .timePace:
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 5, height: 12)
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(color.opacity(0.78))
                    .frame(width: 2.4, height: 11)
            }
            .frame(width: 5, height: 12)
        case .forecast:
            ZStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 5, height: 12)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: 11)
            }
            .frame(width: 5, height: 12)
        }
    }

    // MARK: - Forecast disclosure

    private struct ForecastMetric: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String
    }

    private func forecastExplanation(
        itemID: String,
        forecast: QuotaPaceForecast,
        pace: UsagePace?
    ) -> some View {
        let metrics = forecastMetrics(forecast: forecast, pace: pace)
        let isExpanded = expandedForecastIDs.contains(itemID)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isExpanded {
                        expandedForecastIDs.remove(itemID)
                    } else {
                        expandedForecastIDs.insert(itemID)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.Quota.forecastExplainTitle)
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.vibeBar)
            .accessibilityLabel(
                isExpanded
                    ? L10n.Quota.forecastExplainHide
                    : L10n.Quota.forecastExplainShow
            )

            if isExpanded {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 126), spacing: 7)],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.label.uppercased())
                                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Text(metric.value)
                                .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.88)
                            Text(metric.detail)
                                .font(.system(size: max(8, density.subtitleFontSize - 1)))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: forecastMetricCardHeight,
                            maxHeight: forecastMetricCardHeight,
                            alignment: .topLeading
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                    }
                }
                Text(L10n.Quota.forecastExplainFooter)
                    .font(.system(size: max(8, density.subtitleFontSize - 1)))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 2)
    }

    private var forecastMetricCardHeight: CGFloat {
        switch density.profile {
        case .compact: 72
        case .regular: 76
        case .spacious: 84
        }
    }

    private func forecastMetrics(
        forecast: QuotaPaceForecast,
        pace: UsagePace?
    ) -> [ForecastMetric] {
        let diagnostics = forecast.diagnostics
        let timePaceValue = pace
            .map { atNow(quotaValue(fromUsed: $0.expectedUsedPercent)) }
            ?? L10n.Quota.forecastMetricUnavailable
        let timePaceDetail = pace
            .map { L10n.Quota.forecastMetricTimePaceDetail(stage: $0.stageSummary) }
            ?? L10n.Quota.forecastMetricTimePaceMissing
        let recentValue = diagnostics.recentProjectionUsedPercent
            .map { atReset(quotaValue(fromUsed: $0)) }
            ?? L10n.Quota.forecastConfidenceLearning
        let recentDetail = diagnostics.recentSampleCount > 0
            ? L10n.Quota.forecastMetricRecentIntervals(count: diagnostics.recentSampleCount)
            : L10n.Quota.forecastMetricRecentMissing
        let historyValue = diagnostics.historicalProjectionUsedPercent
            .map { atReset(quotaValue(fromUsed: $0)) }
            ?? L10n.Quota.forecastMetricNoComparison
        let historyDetail = diagnostics.comparableCycleCount > 0
            ? L10n.Quota.forecastMetricComparableCycles(count: diagnostics.comparableCycleCount)
            : L10n.Quota.forecastMetricCyclesPending
        let activityDetail = diagnostics.activityCoveragePercent > 0
            ? L10n.Quota.forecastMetricActivityWeighted
            : L10n.Quota.forecastMetricActivityFallback
        let trendValue = diagnostics.hasActivityTrendBaseline
            ? L10n.Quota.forecastMetricTrendMultiplier(
                multiplier: diagnostics.activityTrendMultiplier.formatted(
                    .number.precision(.fractionLength(2)).locale(AppLocale.current)
                )
            )
            : L10n.Quota.forecastMetricTrendMissing
        let trendDetail = diagnostics.hasActivityTrendBaseline
            ? L10n.Quota.forecastMetricTrendDetail
            : L10n.Quota.forecastMetricTrendDetailMissing
        let range = mode == .used
            ? forecast.projectedUsedLowerPercent...forecast.projectedUsedUpperPercent
            : forecast.projectedRemainingRange
        let unused = whole(forecast.potentialUnusedPercent)

        return [
            ForecastMetric(
                id: "time",
                label: L10n.Quota.forecastMetricTimePace,
                value: timePaceValue,
                detail: timePaceDetail
            ),
            ForecastMetric(
                id: "plan",
                label: L10n.Quota.forecastMetricPlan,
                value: quotaValue(fromUsed: forecast.plannedUsedPercent),
                detail: L10n.Quota.forecastMetricPlanDetail(
                    target: whole(forecast.targetRemainingPercent)
                )
            ),
            ForecastMetric(
                id: "recent",
                label: L10n.Quota.forecastMetricRecentBurn,
                value: recentValue,
                detail: recentDetail
            ),
            ForecastMetric(
                id: "history",
                label: L10n.Quota.resetHistoryTitle,
                value: historyValue,
                detail: historyDetail
            ),
            ForecastMetric(
                id: "activity",
                label: L10n.Quota.forecastMetricActivityTiming,
                value: L10n.Quota.forecastMetricElapsed(
                    percent: whole(diagnostics.behavioralProgressPercent)
                ),
                detail: activityDetail
            ),
            ForecastMetric(
                id: "trend",
                label: L10n.Quota.forecastMetricRecentTrend,
                value: trendValue,
                detail: trendDetail
            ),
            ForecastMetric(
                id: "forecast",
                label: L10n.Quota.forecastMetricForecastAtReset,
                value: quotaValue(fromUsed: forecast.projectedUsedPercent),
                detail: mode == .used
                    ? L10n.Quota.forecastMetricExpectedLeft(
                        percent: whole(forecast.projectedRemainingPercent)
                    )
                    : L10n.Quota.forecastMetricExpectedUsed(
                        percent: whole(forecast.projectedUsedPercent)
                    )
            ),
            ForecastMetric(
                id: "range",
                label: L10n.Quota.forecastMetricForecastRange,
                value: mode == .used
                    ? L10n.Quota.forecastMetricRangeUsed(
                        lower: whole(range.lowerBound), upper: whole(range.upperBound)
                    )
                    : L10n.Quota.forecastMetricRangeLeft(
                        lower: whole(range.lowerBound), upper: whole(range.upperBound)
                    ),
                detail: L10n.Quota.forecastMetricUncertaintyInterval
            ),
            ForecastMetric(
                id: "target",
                label: L10n.Quota.forecastMetricSafetyTarget,
                value: mode == .remaining
                    ? L10n.Quota.forecastValueLeft(
                        percent: whole(forecast.targetRemainingPercent)
                    )
                    : L10n.Quota.forecastValueUsed(
                        percent: whole(100 - forecast.targetRemainingPercent)
                    ),
                detail: unused >= 3
                    ? L10n.Quota.forecastMetricAboveTarget(percent: unused)
                    : L10n.Quota.forecastMetricInsideTarget
            ),
            ForecastMetric(
                id: "evidence",
                label: L10n.Quota.forecastMetricEvidence,
                value: L10n.Quota.forecastMetricEvidenceValue(
                    observations: forecast.currentObservationCount,
                    cycles: forecast.completedCycleCount
                ),
                detail: L10n.Quota.forecastMetricEvidenceDetail(
                    confidence: forecast.confidenceLabel,
                    score: whole(forecast.confidenceScore * 100)
                )
            ),
            ForecastMetric(
                id: "coverage",
                label: L10n.Quota.forecastMetricCoverage,
                value: L10n.Quota.forecastMetricCoverageValue(
                    observations: whole(diagnostics.observationCoveragePercent),
                    history: whole(diagnostics.historyCoveragePercent)
                ),
                detail: L10n.Quota.forecastMetricCoverageDetail(
                    fresh: whole(diagnostics.freshnessPercent),
                    habits: whole(diagnostics.activityCoveragePercent)
                )
            ),
            ForecastMetric(
                id: "behavior",
                label: L10n.Quota.forecastMetricBehaviorFallback,
                value: atReset(
                    quotaValue(fromUsed: diagnostics.behavioralProjectionUsedPercent)
                ),
                detail: L10n.Quota.forecastMetricBehaviorDetail
            ),
        ]
    }

    // MARK: - Formatting

    private func whole(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private func displayedPercent(fromUsed used: Double) -> Double {
        switch mode {
        case .used: used
        case .remaining: max(0, 100 - used)
        }
    }

    private func quotaValue(fromUsed used: Double) -> String {
        modeValue(percent: whole(displayedPercent(fromUsed: used)))
    }

    /// "42% used" / "42% left", in whichever direction the card is showing.
    private func modeValue(percent: Int) -> String {
        switch mode {
        case .used: L10n.Quota.forecastValueUsed(percent: percent)
        case .remaining: L10n.Quota.forecastValueLeft(percent: percent)
        }
    }

    private func atReset(_ value: String) -> String {
        L10n.Quota.forecastValueAtReset(value: value)
    }

    private func atNow(_ value: String) -> String {
        L10n.Quota.forecastValueExpectedNow(value: value)
    }

    private func historySeries(for item: QuotaGroupModule.Row) -> FillTimelineSeries? {
        guard let accountId = item.accountId else { return nil }
        return FillTimelineSeries(tool: item.tool, accountId: accountId, bucket: item.bucket)
    }

    private func displayedTarget(_ forecast: QuotaPaceForecast) -> Double {
        switch mode {
        case .used: 100 - forecast.targetRemainingPercent
        case .remaining: forecast.targetRemainingPercent
        }
    }

    private func percentLabel(used: Double) -> String {
        modeValue(percent: whole(displayedPercent(fromUsed: used)))
    }

    private func etaText(pace: UsagePace) -> String {
        if pace.willLastToReset { return L10n.Quota.paceLastsUntilReset }
        guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "—" }
        let target = now.addingTimeInterval(etaSeconds)
        return ResetCountdownFormatter.string(from: target, now: now)
            .map { L10n.Quota.paceRunsOutIn(countdown: $0) } ?? "—"
    }
}
