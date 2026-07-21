import SwiftUI
import VibeBarCore

/// Subscription Utilization sub-page. Every independently resettable quota
/// gets its own pace row — including model-scoped buckets such as Codex Spark
/// and Claude Fable, plus linked product tools such as AntiGravity on Gemini.
/// The detailed view keeps both reference systems visible: the legacy
/// wall-clock pace and the personal activity-aware plan. It also exposes the
/// component projections, evidence coverage, confidence, target, and final
/// forecast so the verdict is inspectable rather than a black box.
struct SubscriptionUtilizationView: View {
    let tool: ToolType
    let buckets: [QuotaBucket]
    let mode: DisplayMode
    let density: Theme.Density
    let now: Date
    var additionalQuotaSeries: [FillTimelineSeries] = []

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var quotaService: QuotaService
    @State private var expandedForecastIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .center, spacing: 8) {
                ProviderSectionTitle(
                    tool: tool,
                    title: tool.menuTitle,
                    subtitle: providerSubtitle,
                    titleFontSize: density.titleFontSize,
                    subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16,
                    badgeSize: 24
                )
                Spacer(minLength: 4)
                if let providerPlanBadge {
                    PlanBadgeView(
                        text: providerPlanBadge,
                        fontSize: max(9, density.subtitleFontSize - 1)
                    )
                }
                SectionRefreshButton(isRefreshing: isRefreshing) {
                    for refreshTool in refreshTools {
                        environment.refresh(refreshTool)
                    }
                }
            }
            if utilizationBuckets.isEmpty {
                Text("No utilization data — try refreshing.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(utilizationBuckets) { item in
                    row(for: item)
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

    /// One live quota row. The tool is retained so linked-product quotas can
    /// be labelled and refreshed independently (Gemini Web + AntiGravity).
    private struct UtilizationBucket: Identifiable {
        let id: String
        let tool: ToolType
        let accountId: String?
        let bucket: QuotaBucket
        let sectionTitle: String?
        let startsSection: Bool
        let groupTitle: String?
        let startsGroup: Bool
    }

    /// Keep live utilization and reset-cycle history on the same complete
    /// quota set. Previously this path discarded every bucket with a
    /// `groupTitle`, which made Spark and Fable disappear even though their
    /// history tabs were already present.
    private var utilizationBuckets: [UtilizationBucket] {
        struct RawBucket {
            let id: String
            let tool: ToolType
            let accountId: String?
            let bucket: QuotaBucket
        }

        let primary = buckets.map {
            RawBucket(
                id: "primary:\(tool.rawValue):\($0.id)",
                tool: tool,
                accountId: environment.account(for: tool)?.id,
                bucket: $0
            )
        }
        let additional = additionalQuotaSeries.map {
            RawBucket(id: $0.id, tool: $0.tool, accountId: $0.accountId, bucket: $0.bucket)
        }
        var previousSectionKey: String?
        var previousGroupKey: String?
        return (primary + additional).map { item in
            let sectionTitle = linkedSectionTitle(for: item.tool)
            let sectionKey = sectionTitle.map { "\(item.tool.rawValue):\($0)" }
            let startsSection = sectionKey != nil && sectionKey != previousSectionKey
            if startsSection {
                previousSectionKey = sectionKey
                previousGroupKey = nil
            }
            let groupTitle = quotaGroupTitle(for: item.tool, bucket: item.bucket)
            let groupKey = groupTitle.map { "\(item.tool.rawValue):\($0)" }
            let startsGroup = groupKey != nil && groupKey != previousGroupKey
            if groupKey != nil { previousGroupKey = groupKey }
            return UtilizationBucket(
                id: item.id,
                tool: item.tool,
                accountId: item.accountId,
                bucket: item.bucket,
                sectionTitle: sectionTitle,
                startsSection: startsSection,
                groupTitle: groupTitle,
                startsGroup: startsGroup
            )
        }
    }

    private var isRefreshing: Bool {
        refreshTools.contains { refreshTool in
            guard let id = environment.account(for: refreshTool)?.id else { return false }
            return quotaService.inFlightAccountIds.contains(id)
        }
    }

    private var refreshTools: [ToolType] {
        var seen: Set<ToolType> = []
        let productTools = tool == .gemini ? ToolType.googleAIPair : [tool]
        return (productTools + additionalQuotaSeries.map(\.tool)).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func row(for item: UtilizationBucket) -> some View {
        let bucket = item.bucket
        let pace = UsagePace.compute(bucket: bucket, now: now)
        let forecast = paceForecast(for: item)
        let used = bucket.usedPercent
        let timeExpected = pace.map { displayedPercent(fromUsed: $0.expectedUsedPercent) }
        let forecastProjection = forecast.map {
            QuotaForecastBarProjection(
                projectedUsedLowerPercent: $0.projectedUsedLowerPercent,
                projectedUsedUpperPercent: $0.projectedUsedUpperPercent,
                projectedUsedMedianPercent: $0.projectedUsedPercent,
                displayMode: mode
            )
        }
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            if item.startsSection, let sectionTitle = item.sectionTitle {
                linkedProviderSection(tool: item.tool, title: sectionTitle)
            }
            if item.startsGroup, let groupTitle = item.groupTitle {
                Text(groupTitle)
                    .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .padding(.top, item.startsSection ? 1 : 5)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                if let resetAt = bucket.resetAt,
                   let reset = ResetCountdownFormatter.stringWithAbsoluteTime(from: resetAt, now: now) {
                    Text("resets in \(reset)")
                        .font(.system(size: resetCountdownFontSize(for: item.tool)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(item.tool == .antigravity ? 0.92 : 0.80)
                        .layoutPriority(item.tool == .antigravity ? 1 : 0)
                }
                Spacer(minLength: 6)
                Text(percentLabel(used: used))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            quotaReferenceBar(used: used, pace: pace, forecast: forecast)
            percentageAxis
            referenceLegend(
                timeExpected: timeExpected,
                forecastExpected: forecastProjection?.medianPercent,
                forecastColor: forecast.map { QuotaForecastPalette.color(for: $0.verdict) }
            )
            Text(SubscriptionWindowProgress.summary(
                usedPercent: bucket.usedPercent,
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

    private func resetCountdownFontSize(for tool: ToolType) -> CGFloat {
        tool == .antigravity
            ? max(density.subtitleFontSize, density.resetCountdownFontSize + 1)
            : density.resetCountdownFontSize
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
                Text("\(value)%")
                    .font(.system(size: max(8, density.subtitleFontSize - 3), design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
                if value < 100 {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func paceForecast(for item: UtilizationBucket) -> QuotaPaceForecast? {
        guard let accountId = item.accountId else { return nil }
        let snapshot = environment.costService.snapshot(for: item.tool)
        return quotaService.paceForecast(
            accountId: accountId,
            bucket: item.bucket,
            activityHeatmap: snapshot?.heatmap,
            dailyActivity: snapshot?.dailyHistory ?? [],
            now: now
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
                label: "Time-only pace",
                value: "\(Int(timeExpected.rounded()))% \(mode == .remaining ? "left" : "used")"
            )
        }
        if let forecastExpected, let forecastColor {
            referenceLegendItem(
                color: forecastColor,
                markerStyle: .forecast,
                label: "Forecast at reset",
                value: "\(Int(forecastExpected.rounded()))% \(mode == .remaining ? "left" : "used")"
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
            Text("\(label) \(value)")
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
                    Text("How this forecast was calculated")
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide forecast calculation" : "Show forecast calculation")

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
                Text("Quota observations drive consumption. Token history only weights when you tend to work; it is never converted into quota usage.")
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
        let timePaceValue = pace.map { quotaValue(fromUsed: $0.expectedUsedPercent, suffix: "expected now") } ?? "Unavailable"
        let timePaceDetail = pace.map { "\($0.stageSummary) by wall clock" } ?? "Needs reset time and window length"
        let recentValue = diagnostics.recentProjectionUsedPercent
            .map { quotaValue(fromUsed: $0, suffix: "at reset") } ?? "Learning"
        let recentDetail = diagnostics.recentSampleCount > 0
            ? "\(diagnostics.recentSampleCount) recent intervals"
            : "Needs at least two useful observations"
        let historyValue = diagnostics.historicalProjectionUsedPercent
            .map { quotaValue(fromUsed: $0, suffix: "at reset") } ?? "No comparison yet"
        let historyDetail = diagnostics.comparableCycleCount > 0
            ? "\(diagnostics.comparableCycleCount) comparable reset cycles"
            : "Completed cycles will appear here"
        let activityDetail = diagnostics.activityCoveragePercent > 0
            ? "weekday and hour weighted"
            : "wall-clock fallback until habits exist"
        let trendValue = diagnostics.hasActivityTrendBaseline
            ? String(format: "%.2f× activity", diagnostics.activityTrendMultiplier)
            : "No baseline yet"
        let trendDetail = diagnostics.hasActivityTrendBaseline
            ? "last 7 days versus prior 21 days"
            : "needs prior daily activity"
        let range = mode == .used
            ? forecast.projectedUsedLowerPercent...forecast.projectedUsedUpperPercent
            : forecast.projectedRemainingRange
        let unused = whole(forecast.potentialUnusedPercent)

        return [
            ForecastMetric(
                id: "time",
                label: "Time-only pace",
                value: timePaceValue,
                detail: timePaceDetail
            ),
            ForecastMetric(
                id: "plan",
                label: "Personal plan now",
                value: quotaValue(fromUsed: forecast.plannedUsedPercent),
                detail: "activity timing + \(whole(forecast.targetRemainingPercent))% safety target"
            ),
            ForecastMetric(
                id: "recent",
                label: "Recent burn",
                value: recentValue,
                detail: recentDetail
            ),
            ForecastMetric(
                id: "history",
                label: "Reset history",
                value: historyValue,
                detail: historyDetail
            ),
            ForecastMetric(
                id: "activity",
                label: "Activity timing",
                value: "\(whole(diagnostics.behavioralProgressPercent))% elapsed",
                detail: activityDetail
            ),
            ForecastMetric(
                id: "trend",
                label: "Recent trend",
                value: trendValue,
                detail: trendDetail
            ),
            ForecastMetric(
                id: "forecast",
                label: "Forecast at reset",
                value: quotaValue(fromUsed: forecast.projectedUsedPercent),
                detail: mode == .used
                    ? "\(whole(forecast.projectedRemainingPercent))% expected left"
                    : "\(whole(forecast.projectedUsedPercent))% expected used"
            ),
            ForecastMetric(
                id: "range",
                label: "Forecast range",
                value: "\(whole(range.lowerBound))–\(whole(range.upperBound))% \(mode == .used ? "used" : "left")",
                detail: "uncertainty interval"
            ),
            ForecastMetric(
                id: "target",
                label: "Safety target",
                value: mode == .remaining
                    ? "\(whole(forecast.targetRemainingPercent))% left"
                    : "\(whole(100 - forecast.targetRemainingPercent))% used",
                detail: unused >= 3 ? "\(unused)% capacity above target" : "inside the target range"
            ),
            ForecastMetric(
                id: "evidence",
                label: "Evidence",
                value: "\(forecast.currentObservationCount) obs · \(forecast.completedCycleCount) cycles",
                detail: "\(forecast.confidenceLabel) · score \(whole(forecast.confidenceScore * 100))%"
            ),
            ForecastMetric(
                id: "coverage",
                label: "Coverage",
                value: "obs \(whole(diagnostics.observationCoveragePercent))% · history \(whole(diagnostics.historyCoveragePercent))%",
                detail: "fresh \(whole(diagnostics.freshnessPercent))% · habits \(whole(diagnostics.activityCoveragePercent))%"
            ),
            ForecastMetric(
                id: "behavior",
                label: "Behavior fallback",
                value: quotaValue(fromUsed: diagnostics.behavioralProjectionUsedPercent, suffix: "at reset"),
                detail: "used when stronger evidence is sparse"
            ),
        ]
    }

    private func whole(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private func displayedPercent(fromUsed used: Double) -> Double {
        switch mode {
        case .used: used
        case .remaining: max(0, 100 - used)
        }
    }

    private func quotaValue(fromUsed used: Double, suffix: String? = nil) -> String {
        let base = "\(whole(displayedPercent(fromUsed: used)))% \(mode == .used ? "used" : "left")"
        guard let suffix else { return base }
        return "\(base) \(suffix)"
    }

    private func historySeries(for item: UtilizationBucket) -> FillTimelineSeries? {
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
        switch mode {
        case .used:      return "\(Int(used.rounded()))% used"
        case .remaining: return "\(Int((100 - used).rounded()))% left"
        }
    }

    private func etaText(pace: UsagePace) -> String {
        if pace.willLastToReset { return "lasts until reset" }
        guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "—" }
        let target = now.addingTimeInterval(etaSeconds)
        return ResetCountdownFormatter.string(from: target, now: now).map { "runs out in \($0)" } ?? "—"
    }

    private var providerSubtitle: String {
        tool == .gemini ? tool.statusProviderName : tool.subtitle
    }

    private var providerPlanBadge: String? {
        let account = environment.account(for: tool)
        let quotaPlan = account.flatMap { quotaService.cachedQuota(for: $0.id)?.plan }
            ?? environment.quota(for: tool)?.plan
        let label = settingsStore.settings.planBadgeLabel(
            for: tool,
            quotaPlan: quotaPlan,
            accountPlan: account?.plan
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return label?.isEmpty == false ? label : nil
    }

    private func linkedSectionTitle(for itemTool: ToolType) -> String? {
        guard itemTool != tool else { return nil }
        return itemTool.toolName
    }

    private func quotaGroupTitle(for itemTool: ToolType, bucket: QuotaBucket) -> String? {
        if let title = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if tool == .gemini, itemTool == .gemini {
            return "Gemini Chat"
        }
        return nil
    }

    private func linkedProviderSection(tool linkedTool: ToolType, title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .opacity(0.18)
                .padding(.top, 3)
            HStack(alignment: .center, spacing: 6) {
                ToolBrandIconView(tool: linkedTool, size: 13)
                    .opacity(0.85)
                Text(title)
                    .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
        }
    }
}
