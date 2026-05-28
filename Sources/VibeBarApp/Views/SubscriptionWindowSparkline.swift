import SwiftUI
import VibeBarCore

/// Compact horizontal strip showing the fill rate of past reset
/// windows for one quota bucket. Each bar is a `SubscriptionWindowSample`;
/// the rightmost bar is the in-progress window when `currentResetAt`
/// matches a sample, or a synthesized faded bar built from
/// `currentUsedPercent` when no live sample exists yet.
///
/// Reads its data from `QuotaService.historyByAccountBucket` through
/// the parent view; this view is purely visual.
struct SubscriptionWindowSparkline: View {
    /// Newest-first samples for the bucket (already sorted by
    /// `windowEnd`).
    let samples: [SubscriptionWindowSample]
    let currentResetAt: Date?
    let currentUsedPercent: Double
    let mode: DisplayMode
    let density: Theme.Density

    private static let barWidth: CGFloat = 8
    private static let barSpacing: CGFloat = 3
    private static let maxBars: Int = 20
    private static let minVisibleHeight: CGFloat = 2

    var body: some View {
        let bars = renderableBars()
        if bars.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fill history")
                    .font(.system(size: max(9, density.subtitleFontSize - 2)))
                    .foregroundStyle(.tertiary)
                HStack(spacing: Self.barSpacing) {
                    ForEach(bars) { bar in
                        SparklineBar(bar: bar, mode: mode, barWidth: Self.barWidth)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: barHeight, alignment: .bottom)
            }
            .padding(.top, 2)
            .accessibilityLabel(accessibilitySummary(bars: bars))
        }
    }

    private var barHeight: CGFloat {
        max(26, density.bucketBarHeight * 1.4)
    }

    private func renderableBars() -> [BarSlot] {
        var slots: [BarSlot] = []
        // Track which samples we already promoted into the "current"
        // slot so we don't double-render them.
        var consumedCurrentSampleID: String?

        if let currentResetAt {
            // Prefer a live sample matching the in-progress windowEnd
            // (so the bar inherits real peak/last numbers and hover
            // shows accurate counts). Fall back to a synthesized bar
            // from currentUsedPercent when no sample exists yet.
            if let liveSample = samples.first(where: { $0.windowEnd == currentResetAt }) {
                slots.append(BarSlot(
                    id: liveSample.id,
                    windowEnd: liveSample.windowEnd,
                    windowStart: liveSample.windowStart,
                    rawWindowSeconds: liveSample.rawWindowSeconds,
                    peak: liveSample.peakUsedPercent,
                    last: liveSample.lastUsedPercent,
                    observationCount: liveSample.observationCount,
                    isCurrent: true
                ))
                consumedCurrentSampleID = liveSample.id
            } else {
                slots.append(BarSlot(
                    id: "synthetic-current-\(currentResetAt.timeIntervalSinceReferenceDate)",
                    windowEnd: currentResetAt,
                    windowStart: nil,
                    rawWindowSeconds: nil,
                    peak: currentUsedPercent,
                    last: currentUsedPercent,
                    observationCount: 0,
                    isCurrent: true
                ))
            }
        }

        for sample in samples where sample.id != consumedCurrentSampleID {
            slots.append(BarSlot(
                id: sample.id,
                windowEnd: sample.windowEnd,
                windowStart: sample.windowStart,
                rawWindowSeconds: sample.rawWindowSeconds,
                peak: sample.peakUsedPercent,
                last: sample.lastUsedPercent,
                observationCount: sample.observationCount,
                isCurrent: false
            ))
        }

        if slots.count > Self.maxBars {
            slots = Array(slots.prefix(Self.maxBars))
        }
        return slots.reversed()  // oldest left, newest (current) right
    }

    private func accessibilitySummary(bars: [BarSlot]) -> String {
        guard let newest = bars.last else { return "Subscription fill history" }
        let percent = displayValue(for: newest)
        let label = mode == .remaining ? "left" : "used"
        return "Subscription fill history. Current window \(Int(percent.rounded()))% \(label)."
    }

    private func displayValue(for bar: BarSlot) -> Double {
        switch mode {
        case .used:      return bar.peak
        case .remaining: return max(0, 100 - bar.peak)
        }
    }
}

// MARK: - Bar slot

extension SubscriptionWindowSparkline {
    fileprivate struct BarSlot: Identifiable, Hashable {
        let id: String
        let windowEnd: Date
        let windowStart: Date?
        let rawWindowSeconds: Int?
        let peak: Double
        let last: Double
        let observationCount: Int
        let isCurrent: Bool
    }
}

private extension SubscriptionWindowSample {
    /// Stable identifier used by the sparkline ForEach. Bucket id + the
    /// window end timestamp fully identifies a window across runs.
    var id: String {
        "\(accountId)|\(bucketId)|\(Int(windowEnd.timeIntervalSinceReferenceDate))"
    }
}

// MARK: - Single bar with hover popover

private struct SparklineBar: View {
    let bar: SubscriptionWindowSparkline.BarSlot
    let mode: DisplayMode
    let barWidth: CGFloat

    @State private var hovering = false

    private static let minVisibleHeight: CGFloat = 2

    var body: some View {
        let percent = displayValue
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.barColor(percent: bar.peak, mode: mode))
                    .opacity(bar.isCurrent ? 0.5 : 1.0)
                    .frame(height: barFillHeight(in: geo.size.height, percent: percent))
            }
        }
        .frame(width: barWidth)
        .background(
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.barTrack)
                .opacity(0.6)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: $hovering, arrowEdge: .top) {
            tooltip
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
        }
    }

    private var displayValue: Double {
        switch mode {
        case .used:      return bar.peak
        case .remaining: return max(0, 100 - bar.peak)
        }
    }

    private func barFillHeight(in total: CGFloat, percent: Double) -> CGFloat {
        guard total > 0 else { return Self.minVisibleHeight }
        let raw = total * CGFloat(percent / 100)
        return max(Self.minVisibleHeight, min(total, raw))
    }

    @ViewBuilder
    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("peak")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(formatPercent(bar.peak))
                    .font(.caption.monospacedDigit())
                    .fontWeight(.semibold)
            }
            HStack(spacing: 8) {
                Text("last")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(formatPercent(bar.last))
                    .font(.caption.monospacedDigit())
            }
            Divider()
            Text(windowSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if bar.observationCount > 0 {
                Text("observed \(bar.observationCount)×")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if bar.isCurrent {
                Text("in progress")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatPercent(_ value: Double) -> String {
        switch mode {
        case .used:      return "\(Int(value.rounded()))%"
        case .remaining: return "\(Int((100 - value).rounded()))% left"
        }
    }

    private var windowSummary: String {
        let endStr = SparklineBar.dateFormatter.string(from: bar.windowEnd)
        if let start = bar.windowStart {
            let startStr = SparklineBar.dateFormatter.string(from: start)
            return "\(startStr) → \(endStr)"
        }
        return "ends \(endStr)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// MARK: - Previews

private enum SubscriptionWindowSparklinePreviewFixtures {
    static func samples(
        tool: ToolType,
        peaks: [Double],
        lasts: [Double]
    ) -> [SubscriptionWindowSample] {
        let now = Date()
        return zip(peaks, lasts).enumerated().map { (offset, pair) in
            let (peak, last) = pair
            let i = offset + 1
            return SubscriptionWindowSample(
                accountId: "acct",
                tool: tool,
                bucketId: "weekly",
                windowEnd: now.addingTimeInterval(-Double(i) * 7 * 86_400),
                windowStart: now.addingTimeInterval(-Double(i + 1) * 7 * 86_400),
                rawWindowSeconds: 604_800,
                peakUsedPercent: peak,
                lastUsedPercent: last,
                observationCount: 30,
                firstSeenAt: now,
                lastSeenAt: now
            )
        }
    }
}

#Preview("Mixed history") {
    SubscriptionWindowSparkline(
        samples: SubscriptionWindowSparklinePreviewFixtures.samples(
            tool: .claude,
            peaks: [80, 100, 5, 55, 90],
            lasts: [78, 100, 5, 50, 88]
        ),
        currentResetAt: Date().addingTimeInterval(3 * 86_400),
        currentUsedPercent: 32,
        mode: .used,
        density: Theme.density(for: .regular)
    )
    .padding()
    .frame(width: 240)
}

#Preview("Empty + current only") {
    SubscriptionWindowSparkline(
        samples: [],
        currentResetAt: Date().addingTimeInterval(3 * 86_400),
        currentUsedPercent: 18,
        mode: .used,
        density: Theme.density(for: .regular)
    )
    .padding()
    .frame(width: 240)
}

#Preview("Remaining mode") {
    SubscriptionWindowSparkline(
        samples: SubscriptionWindowSparklinePreviewFixtures.samples(
            tool: .codex,
            peaks: [70, 95, 40, 60],
            lasts: [70, 95, 40, 60]
        ),
        currentResetAt: Date().addingTimeInterval(2 * 86_400),
        currentUsedPercent: 22,
        mode: .remaining,
        density: Theme.density(for: .regular)
    )
    .padding()
    .frame(width: 240)
}
