import SwiftUI
import VibeBarCore

/// One independently resettable quota shown in Fill History. The account id
/// is part of the identity because the Gemini page combines Gemini Web and
/// AntiGravity, whose bucket ids can otherwise overlap.
struct FillTimelineSeries: Identifiable {
    let tool: ToolType
    let accountId: String
    let bucket: QuotaBucket

    var id: String { "\(tool.rawValue):\(accountId):\(bucket.id)" }
}

/// Reset-cycle utilization history. Each bar is one subscription cycle and
/// answers the useful question: how much quota was still unused when the
/// provider refilled it? The final outlined bar is the active cycle.
struct FillTimelineChart: View {
    let series: FillTimelineSeries
    let mode: DisplayMode
    let density: Theme.Density
    let targetPercent: Double?

    @EnvironmentObject var quotaService: QuotaService
    @State private var hoveredIndex: Int?

    private static let maxCycles = 12

    private var barSpacing: CGFloat {
        switch density.profile {
        case .compact: 2
        case .regular: 3
        case .spacious: 4
        }
    }

    private var chartHeight: CGFloat {
        switch density.profile {
        case .compact: 40
        case .regular: 52
        case .spacious: 66
        }
    }

    var body: some View {
        let cycles = visibleCycles(series: series)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Reset history")
                    .font(.system(size: max(9, density.subtitleFontSize - 2), weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text("Each bar is one quota cycle")
                    .font(.system(size: max(7.5, density.subtitleFontSize - 4)))
                    .foregroundStyle(.quaternary)
            }
            earlyRefillMarks(cycles, tool: series.tool)
            cycleStrip(cycles, tool: series.tool, targetPercent: targetPercent)
            Text(caption(cycles))
                .font(.system(size: max(8, density.subtitleFontSize - 3), design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            earlyRefillNote(cycles)
            axis(cycles)
        }
        .padding(.top, 4)
    }

    private func visibleCycles(series: FillTimelineSeries) -> [SubscriptionWindowSample] {
        let key = SubscriptionHistoryKey(accountId: series.accountId, bucketId: series.bucket.id)
        let samples = quotaService.historyByAccountBucket[key] ?? []
        return Array(samples.sorted { cycleDate($0) < cycleDate($1) }.suffix(Self.maxCycles))
    }

    @ViewBuilder
    private func cycleStrip(
        _ cycles: [SubscriptionWindowSample],
        tool: ToolType,
        targetPercent: Double?
    ) -> some View {
        if cycles.isEmpty {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.barTrack.opacity(0.45))
                .overlay {
                    Text("Waiting for the first quota observation")
                        .font(.system(size: max(8, density.subtitleFontSize - 3)))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: chartHeight)
        } else {
            GeometryReader { geo in
                let count = cycles.count
                let barWidth = max(5, (geo.size.width - CGFloat(count - 1) * barSpacing) / CGFloat(count))
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(Array(cycles.enumerated()), id: \.offset) { index, cycle in
                            cycleBar(cycle, tool: tool, isHovered: hoveredIndex == index)
                                .frame(width: barWidth, height: geo.size.height)
                        }
                    }
                    if let targetPercent, targetPercent > 3, targetPercent < 97 {
                        Path { path in
                            let y = geo.size.height * (1 - targetPercent / 100)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(
                            Color.primary.opacity(0.34),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredIndex = min(max(0, Int(location.x / (barWidth + barSpacing))), count - 1)
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
            .frame(height: chartHeight)
        }
    }

    private func cycleBar(_ cycle: SubscriptionWindowSample, tool: ToolType, isHovered: Bool) -> some View {
        let percent = displayedPercent(cycle)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.barTrack.opacity(isHovered ? 0.95 : 0.62))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.providerAccent(for: tool).opacity(isHovered ? 1 : 0.86))
                .frame(maxHeight: .infinity)
                .scaleEffect(x: 1, y: max(0.04, percent / 100), anchor: .bottom)
        }
        .overlay {
            if !cycle.isCompleted {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Theme.providerAccent(for: tool).opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
    }

    /// Dots over the cycles that refilled before their window was up.
    ///
    /// Above the bars rather than inside them: a cycle that spent all of its
    /// quota fills its track to the top, where a marker would be the same
    /// colour as the fill under it.
    @ViewBuilder
    private func earlyRefillMarks(
        _ cycles: [SubscriptionWindowSample],
        tool: ToolType
    ) -> some View {
        if cycles.contains(where: \.refilledEarly) {
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(Array(cycles.enumerated()), id: \.offset) { _, cycle in
                    Circle()
                        .fill(Theme.providerAccent(for: tool).opacity(cycle.refilledEarly ? 0.8 : 0))
                        .frame(width: 3, height: 3)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private func earlyRefillNote(_ cycles: [SubscriptionWindowSample]) -> some View {
        let early = cycles.filter(\.refilledEarly).count
        if early > 0 {
            Text(
                early == 1
                    ? "1 cycle refilled before the window was up"
                    : "\(early) cycles refilled before the window was up"
            )
            .font(.system(size: max(7.5, density.subtitleFontSize - 4), design: .rounded))
            .foregroundStyle(.quaternary)
        }
    }

    /// What the provider did to the clock, when it did anything unusual. The
    /// two early shapes mean opposite things, so the caption says which.
    private func resetDescription(_ cycle: SubscriptionWindowSample) -> String {
        switch cycle.resetKind {
        case .earlyClockRestarted: " · refilled early, next window restarted"
        case .earlyClockUnchanged: " · refilled early, next reset unchanged"
        case .earlyUnclear: " · refilled early, onto a different schedule"
        case .onSchedule, .unobserved, nil: ""
        }
    }

    private func caption(_ cycles: [SubscriptionWindowSample]) -> String {
        guard !cycles.isEmpty else {
            return "A cycle is recorded when the quota refills"
        }
        let index = hoveredIndex.map { min(max(0, $0), cycles.count - 1) } ?? cycles.count - 1
        let cycle = cycles[index]
        let used = Int(cycle.peakUsedPercent.rounded())
        let left = Int(cycle.remainingPercentAtReset.rounded())
        if let completedAt = cycle.completedAt {
            let samplingGap = completedAt.timeIntervalSince(cycle.lastSeenAt)
            let gapText: String
            if samplingGap >= 60,
               let duration = ResetCountdownFormatter.string(from: completedAt, now: cycle.lastSeenAt) {
                gapText = " · last seen \(duration) before reset"
            } else {
                gapText = ""
            }
            return "\(Self.timestampFormatter.string(from: completedAt)) reset · \(used)% used · \(left)% left\(resetDescription(cycle))\(gapText)"
        }
        return "Current cycle · \(used)% used so far · \(left)% left"
    }

    @ViewBuilder
    private func axis(_ cycles: [SubscriptionWindowSample]) -> some View {
        if !cycles.isEmpty {
            HStack {
                Text(axisLabel(cycles[0]))
                Spacer()
                if cycles.count > 2 {
                    Text(axisLabel(cycles[cycles.count / 2]))
                    Spacer()
                }
                Text(cycles.last?.isCompleted == false ? "Current" : axisLabel(cycles[cycles.count - 1]))
            }
            .font(.system(size: max(7.5, density.subtitleFontSize - 4), design: .rounded))
            .foregroundStyle(.tertiary)
        }
    }

    private func displayedPercent(_ cycle: SubscriptionWindowSample) -> Double {
        switch mode {
        case .used: cycle.peakUsedPercent
        case .remaining: cycle.remainingPercentAtReset
        }
    }

    private func cycleDate(_ cycle: SubscriptionWindowSample) -> Date {
        cycle.completedAt ?? cycle.lastSeenAt
    }

    private func axisLabel(_ cycle: SubscriptionWindowSample) -> String {
        Self.dayFormatter.string(from: cycleDate(cycle))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d 'at' HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
