import SwiftUI
import Charts
import VibeBarCore

/// Subscription Utilization sub-page. Every independently resettable quota
/// gets its own pace row — including model-scoped buckets such as Codex Spark
/// and Claude Fable, plus linked product tools such as AntiGravity on Gemini.
/// Each row shows the absolute time-since-reset on a horizontal Swift Charts
/// bar alongside the linear "expected" reference line, making it obvious
/// whether the user is burning faster or slower than the linear pace.
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
                bucket: $0
            )
        }
        let additional = additionalQuotaSeries.map {
            UtilizationBucket(id: $0.id, tool: $0.tool, bucket: $0.bucket)
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
        let used = bucket.usedPercent
        let expected = pace?.expectedUsedPercent ?? 0
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
                if expected > 0 {
                    RuleMark(x: .value("Expected", expected))
                        .foregroundStyle(.primary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        // Annotation moved into the legend row below the chart
                        // — placing it inside Charts caused the popover to clip
                        // when the rule was near the chart edge (esp. at 100%).
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
            .frame(height: 36)
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
            if let pace {
                HStack(spacing: 6) {
                    Text(pace.stageSummary)
                        .font(.system(size: density.subtitleFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if expected > 0 {
                        Text("·")
                            .font(.system(size: density.subtitleFontSize))
                            .foregroundStyle(.tertiary)
                        Text("expected \(Int(expected.rounded()))%")
                            .font(.system(size: density.subtitleFontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(etaText(pace: pace))
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
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
