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
    @EnvironmentObject var quotaService: QuotaService
    @State private var expandedForecastIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Subscription Utilization")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                Text(toolDisplayName)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
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
    }

    /// Keep live utilization and reset-cycle history on the same complete
    /// quota set. Previously this path discarded every bucket with a
    /// `groupTitle`, which made Spark and Fable disappear even though their
    /// history tabs were already present.
    private var utilizationBuckets: [UtilizationBucket] {
        let primary = buckets.map {
            UtilizationBucket(
                id: "primary:\(tool.rawValue):\($0.id)",
                tool: tool,
                accountId: environment.account(for: tool)?.id,
                bucket: $0
            )
        }
        let additional = additionalQuotaSeries.map {
            UtilizationBucket(id: $0.id, tool: $0.tool, accountId: $0.accountId, bucket: $0.bucket)
        }
        return primary + additional
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
        let timeExpected = pace?.expectedUsedPercent
        let forecastExpected = forecast?.projectedUsedPercent
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(rowTitle(for: item))
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
                forecastExpected: forecastExpected,
                forecastColor: forecast.map { QuotaForecastPalette.color(for: $0.verdict) }
            )
            Text(SubscriptionWindowProgress.summary(
                usedPercent: bucket.usedPercent,
                resetAt: bucket.resetAt,
                rawWindowSeconds: bucket.rawWindowSeconds,
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
                    showGuidance: true
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
                percent: used,
                mode: .used,
                timePacePercent: pace?.expectedUsedPercent,
                forecastLowerPercent: forecast.projectedUsedLowerPercent,
                forecastUpperPercent: forecast.projectedUsedUpperPercent,
                forecastMedianPercent: forecast.projectedUsedPercent,
                forecastColor: QuotaForecastPalette.color(for: forecast.verdict),
                height: barHeight
            )
        } else if let pace {
            PaceMarkerCapsule(
                usedPercent: used,
                expectedPercent: pace.expectedUsedPercent,
                mode: .used,
                height: barHeight
            )
        } else {
            QuotaBarShape(percent: used, mode: .used, height: barHeight)
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
                actualUsedLegend
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
                actualUsedLegend
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
                value: "\(Int(timeExpected.rounded()))%"
            )
        }
        if let forecastExpected, let forecastColor {
            referenceLegendItem(
                color: forecastColor,
                markerStyle: .forecast,
                label: "Forecast at reset",
                value: "\(Int(forecastExpected.rounded()))%"
            )
        }
    }

    private var actualUsedLegend: some View {
        Text("bar = actual used")
            .font(.system(size: max(8, density.subtitleFontSize - 1)))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: true, vertical: false)
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
                                .fixedSize(horizontal: false, vertical: true)
                            Text(metric.value)
                                .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(metric.detail)
                                .font(.system(size: max(8, density.subtitleFontSize - 1)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
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

    private func forecastMetrics(
        forecast: QuotaPaceForecast,
        pace: UsagePace?
    ) -> [ForecastMetric] {
        let diagnostics = forecast.diagnostics
        let timePaceValue = pace.map { "\(whole($0.expectedUsedPercent))% expected now" } ?? "Unavailable"
        let timePaceDetail = pace.map { "\($0.stageSummary) by wall clock" } ?? "Needs reset time and window length"
        let recentValue = diagnostics.recentProjectionUsedPercent
            .map { "\(whole($0))% used at reset" } ?? "Learning"
        let recentDetail = diagnostics.recentSampleCount > 0
            ? "\(diagnostics.recentSampleCount) recent intervals"
            : "Needs at least two useful observations"
        let historyValue = diagnostics.historicalProjectionUsedPercent
            .map { "\(whole($0))% used at reset" } ?? "No comparison yet"
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
        let range = forecast.projectedUsedLowerPercent...forecast.projectedUsedUpperPercent
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
                value: "\(whole(forecast.plannedUsedPercent))% used",
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
                value: "\(whole(forecast.projectedUsedPercent))% used",
                detail: "\(whole(forecast.projectedRemainingPercent))% expected left"
            ),
            ForecastMetric(
                id: "range",
                label: "Forecast range",
                value: "\(whole(range.lowerBound))–\(whole(range.upperBound))% used",
                detail: "uncertainty interval"
            ),
            ForecastMetric(
                id: "target",
                label: "Safety target",
                value: "\(whole(forecast.targetRemainingPercent))% left",
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
                value: "\(whole(diagnostics.behavioralProjectionUsedPercent))% used at reset",
                detail: "used when stronger evidence is sparse"
            ),
        ]
    }

    private func whole(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private func rowTitle(for item: UtilizationBucket) -> String {
        var parts: [String] = []
        if item.tool != tool {
            parts.append(item.tool.toolName)
        }
        if let groupTitle = item.bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupTitle.isEmpty {
            parts.append(groupTitle)
        }
        parts.append(item.bucket.title)
        return parts.joined(separator: " · ")
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

    private var toolDisplayName: String {
        tool.displayName
    }
}
