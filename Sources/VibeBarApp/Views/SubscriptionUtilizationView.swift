import SwiftUI
import Charts
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
            if utilizationBuckets.isEmpty && historySeries.isEmpty {
                Text("No utilization data — try refreshing.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(utilizationBuckets) { item in
                    row(for: item)
                }
                if !historySeries.isEmpty {
                    FillTimelineChart(
                        series: historySeries,
                        mode: mode,
                        density: density,
                        now: now
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

    /// Every bucket participates in reset-cycle history, including per-model
    /// dimensions and additional accounts combined into the same product page.
    private var historySeries: [FillTimelineSeries] {
        let primary: [FillTimelineSeries]
        if let accountId = environment.account(for: tool)?.id {
            primary = buckets.map { FillTimelineSeries(tool: tool, accountId: accountId, bucket: $0) }
        } else {
            primary = []
        }
        return primary + additionalQuotaSeries
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
        let personalExpected = forecast?.plannedUsedPercent
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(rowTitle(for: item))
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(percentLabel(used: used))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Chart {
                BarMark(
                    xStart: .value("Start", 0),
                    xEnd: .value("Used", min(100, used)),
                    y: .value("Bucket", bucket.title)
                )
                .foregroundStyle(Theme.barColor(percent: used, mode: .used))
                .cornerRadius(3)
                if let timeExpected, timeExpected > 0 {
                    RuleMark(x: .value("Time-only pace", timeExpected))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
                }
                if let personalExpected, personalExpected > 0 {
                    RuleMark(x: .value("Personal plan", personalExpected))
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                    AxisValueLabel {
                        if let raw = value.as(Int.self) {
                            Text("\(raw)%")
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: density.utilizationBarHeight)
            referenceLegend(
                timeExpected: timeExpected,
                personalExpected: personalExpected
            )
            Text(SubscriptionWindowProgress.summary(
                usedPercent: bucket.usedPercent,
                resetAt: bucket.resetAt,
                rawWindowSeconds: bucket.rawWindowSeconds,
                now: now
            ))
                .font(.system(size: density.subtitleFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let forecast {
                QuotaForecastRow(
                    forecast: forecast,
                    now: now,
                    fontSize: density.subtitleFontSize,
                    showGuidance: true
                )
                forecastExplanation(forecast: forecast, pace: pace)
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
    private func referenceLegend(timeExpected: Double?, personalExpected: Double?) -> some View {
        HStack(spacing: 14) {
            if let timeExpected {
                referenceLegendItem(
                    color: .secondary,
                    label: "Time-only pace",
                    value: "\(Int(timeExpected.rounded()))%"
                )
            }
            if let personalExpected {
                referenceLegendItem(
                    color: .accentColor,
                    label: "Personal plan",
                    value: "\(Int(personalExpected.rounded()))%"
                )
            }
            Spacer(minLength: 4)
            Text("bar = actual used")
                .font(.system(size: max(8, density.subtitleFontSize - 1)))
                .foregroundStyle(.tertiary)
        }
        .lineLimit(1)
    }

    private func referenceLegendItem(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Capsule(style: .continuous)
                .fill(color)
                .frame(width: 14, height: 2)
            Text("\(label) \(value)")
                .font(.system(size: max(8, density.subtitleFontSize - 1), weight: .medium))
                .foregroundStyle(color)
        }
    }

    private struct ForecastMetric: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String
    }

    private func forecastExplanation(
        forecast: QuotaPaceForecast,
        pace: UsagePace?
    ) -> some View {
        let metrics = forecastMetrics(forecast: forecast, pace: pace)
        return VStack(alignment: .leading, spacing: 7) {
            Text("How this forecast was calculated")
                .font(.system(size: density.subtitleFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(metric.detail)
                            .font(.system(size: max(8, density.subtitleFontSize - 1)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
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
