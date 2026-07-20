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
    let series: [FillTimelineSeries]
    let mode: DisplayMode
    let density: Theme.Density
    let now: Date

    @EnvironmentObject var quotaService: QuotaService
    @State private var selectedBucketId: String?
    @State private var hoveredIndex: Int?

    private static let barSpacing: CGFloat = 3
    private static let maxCycles = 12
    private static let chartHeight: CGFloat = 48

    var body: some View {
        let tabs = availableTabs
        if tabs.isEmpty {
            EmptyView()
        } else {
            let activeSeriesId = selectedBucketId.flatMap { id in
                tabs.contains(where: { $0.id == id }) ? id : nil
            } ?? tabs[0].id
            let activeSeries = tabs.first(where: { $0.id == activeSeriesId })!.series
            let cycles = visibleCycles(series: activeSeries)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Utilization by reset")
                        .font(.system(size: max(9, density.subtitleFontSize - 2)))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text("Each bar is one quota cycle")
                        .font(.system(size: max(7.5, density.subtitleFontSize - 4)))
                        .foregroundStyle(.quaternary)
                }
                if tabs.count > 1 {
                    GeometryReader { geometry in
                        let tabFontSize = max(8.5, density.subtitleFontSize - 2)
                        let minimumContentWidth = tabs.reduce(CGFloat.zero) { width, tab in
                            width + max(64, CGFloat(tab.label.count) * tabFontSize * 0.58 + 24)
                        } + CGFloat(max(0, tabs.count - 1)) * 2 + 4
                        let contentWidth = max(geometry.size.width, minimumContentWidth)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach(tabs, id: \.id) { tab in
                                    let isSelected = tab.id == activeSeriesId
                                    Button {
                                        selectedBucketId = tab.id
                                        hoveredIndex = nil
                                    } label: {
                                        Text(tab.label)
                                            .font(.system(
                                                size: tabFontSize,
                                                weight: .semibold,
                                                design: .rounded
                                            ))
                                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 9)
                                            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                                            .background {
                                                if isSelected {
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .fill(Color.accentColor)
                                                }
                                            }
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .focusable(false)
                                    .accessibilityLabel("Show \(tab.label) utilization history")
                                }
                            }
                            .padding(2)
                            .frame(width: contentWidth)
                        }
                    }
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                cycleStrip(cycles, tool: activeSeries.tool)
                Text(caption(cycles))
                    .font(.system(size: max(8, density.subtitleFontSize - 3), design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                axis(cycles)
            }
            .padding(.top, 2)
        }
    }

    private var availableTabs: [(id: String, label: String, series: FillTimelineSeries)] {
        let toolCount = Set(series.map(\.tool)).count
        return series.map { item in
            (item.id, Self.tabLabel(for: item, includeTool: toolCount > 1), item)
        }
    }

    private static func tabLabel(for series: FillTimelineSeries, includeTool: Bool) -> String {
        let bucket = series.bucket
        let window: String
        switch bucket.rawWindowSeconds {
        case 18_000: window = "5 Hours"
        case 604_800: window = "Weekly"
        case 2_592_000: window = "Monthly"
        default:
            switch bucket.shortLabel.lowercased() {
            case "5h", "5 hr", "5 hrs": window = "5 Hours"
            case "wk", "1w": window = "Weekly"
            case "mo", "1m": window = "Monthly"
            default: window = bucket.title
            }
        }
        let group = bucket.groupTitle?.replacingOccurrences(of: " Models", with: "")
        let owner = group ?? (includeTool ? series.tool.toolName : nil)
        return owner.map { "\($0) · \(window)" } ?? window
    }

    private func visibleCycles(series: FillTimelineSeries) -> [SubscriptionWindowSample] {
        let key = SubscriptionHistoryKey(accountId: series.accountId, bucketId: series.bucket.id)
        let samples = quotaService.historyByAccountBucket[key] ?? []
        return Array(samples.sorted { cycleDate($0) < cycleDate($1) }.suffix(Self.maxCycles))
    }

    @ViewBuilder
    private func cycleStrip(_ cycles: [SubscriptionWindowSample], tool: ToolType) -> some View {
        if cycles.isEmpty {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.barTrack.opacity(0.45))
                .overlay {
                    Text("Waiting for the first quota observation")
                        .font(.system(size: max(8, density.subtitleFontSize - 3)))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: Self.chartHeight)
        } else {
            GeometryReader { geo in
                let count = cycles.count
                let barWidth = max(5, (geo.size.width - CGFloat(count - 1) * Self.barSpacing) / CGFloat(count))
                HStack(alignment: .bottom, spacing: Self.barSpacing) {
                    ForEach(Array(cycles.enumerated()), id: \.offset) { index, cycle in
                        cycleBar(cycle, tool: tool, isHovered: hoveredIndex == index)
                            .frame(width: barWidth, height: geo.size.height)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredIndex = min(max(0, Int(location.x / (barWidth + Self.barSpacing))), count - 1)
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
            .frame(height: Self.chartHeight)
        }
    }

    private func cycleBar(_ cycle: SubscriptionWindowSample, tool: ToolType, isHovered: Bool) -> some View {
        let percent = displayedPercent(cycle)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.barTrack.opacity(isHovered ? 0.95 : 0.62))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Self.accent(for: tool).opacity(isHovered ? 1 : 0.86))
                .frame(maxHeight: .infinity)
                .scaleEffect(x: 1, y: max(0.04, percent / 100), anchor: .bottom)
        }
        .overlay {
            if !cycle.isCompleted {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Self.accent(for: tool).opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
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
            return "\(Self.timestampFormatter.string(from: completedAt)) reset · \(used)% used · \(left)% left"
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

    private static func accent(for tool: ToolType) -> Color {
        switch tool {
        case .codex: Color(red: 0.30, green: 0.78, blue: 0.74)
        case .claude: Color(red: 0.93, green: 0.40, blue: 0.40)
        case .gemini, .antigravity: Color(red: 0.34, green: 0.62, blue: 0.96)
        case .grok: Color(red: 0.45, green: 0.45, blue: 0.50)
        default: Color(red: 0.45, green: 0.55, blue: 0.65)
        }
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
