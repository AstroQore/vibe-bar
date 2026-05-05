import SwiftUI
import Charts
import VibeBarCore

/// Subscription Utilization sub-page. For each main bucket (5h / weekly),
/// shows the absolute time-since-reset on a horizontal Swift Charts bar
/// alongside the linear "expected" reference line — making it obvious
/// whether the user is burning faster or slower than the linear pace.
struct SubscriptionUtilizationView: View {
    let tool: ToolType
    let buckets: [QuotaBucket]
    let mode: DisplayMode
    let density: Theme.Density
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Subscription utilization")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                Text(toolDisplayName)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            if relevantBuckets.isEmpty {
                Text("No utilization data — try refreshing.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(relevantBuckets) { bucket in
                    row(for: bucket)
                }
            }
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    /// Pick the headline buckets only (no per-model groups).
    private var relevantBuckets: [QuotaBucket] {
        buckets.filter { $0.groupTitle == nil }
    }

    @ViewBuilder
    private func row(for bucket: QuotaBucket) -> some View {
        let pace = UsagePace.compute(bucket: bucket, now: now)
        let used = bucket.usedPercent
        let expected = pace?.expectedUsedPercent ?? 0
        VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
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
            if let pace {
                HStack(spacing: 6) {
                    Text(pace.stageSummary)
                        .font(.system(size: density.subtitleFontSize, weight: .medium))
                        .foregroundStyle(.primary)
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
