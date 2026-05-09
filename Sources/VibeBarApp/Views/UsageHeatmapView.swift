import SwiftUI
import VibeBarCore

/// Weekday × hour heatmap — answers "when do I use this provider the most?".
/// Each cell is colored by token count (log-scaled so a quiet 2 AM still
/// registers if the user works late). Hovering shows the day/hour and total.
struct UsageHeatmapView: View {
    let heatmap: UsageHeatmap
    let density: Theme.Density
    /// Optional title override. The Overview's "all providers" version of this
    /// card needs "When you use everything" instead of the default
    /// `When you use \(toolName)` derived from `heatmap.tool`.
    var titleOverride: String? = nil

    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    @State private var measuredGridWidth: CGFloat = 0
    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(titleOverride ?? "When you use \(toolName)")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if heatmap.totalTokens > 0 {
                    Text(peakLabel)
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.secondary)
                }
                SectionRefreshButton(isRefreshing: false) {
                    environment.refreshCostUsage()
                }
                .padding(.leading, 4)
            }
            grid
            HStack(spacing: 6) {
                Text("Quiet")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                ForEach(0..<6, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(intensityColor(intensity: Double(step) / 5.0))
                        .frame(width: 16, height: 8)
                }
                Text("Heavy")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                Spacer()
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

    private var toolName: String {
        // Heatmap is only rendered for primary providers (those with
        // local cost data); misc providers don't reach this view. Use
        // `menuTitle` as a defensive fallback.
        switch heatmap.tool {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan:
            return heatmap.tool.menuTitle
        }
    }

    private var grid: some View {
        let max = heatmap.cells.flatMap { $0 }.max() ?? 0
        let metrics = gridMetrics(for: measuredGridWidth)
        return GeometryReader { proxy in
            let liveMetrics = gridMetrics(for: proxy.size.width)
            VStack(alignment: .leading, spacing: cellSpacing) {
                HStack(spacing: cellSpacing) {
                    Text("")
                        .font(.system(size: 8))
                        .frame(width: liveMetrics.labelWidth, alignment: .trailing)
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(hourLabel(hour))
                            .font(.system(size: 8, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: liveMetrics.hourBlockWidth, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: cellSpacing) {
                        Text(weekdayLabels[weekday])
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: liveMetrics.labelWidth, alignment: .trailing)
                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: liveMetrics.cellCornerRadius, style: .continuous)
                                .fill(cellColor(weekday: weekday, hour: hour, max: max))
                                .frame(width: liveMetrics.cellSide, height: liveMetrics.cellSide)
                                .help(cellTooltip(weekday: weekday, hour: hour))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .preference(key: HeatmapGridWidthPreferenceKey.self, value: proxy.size.width)
        }
        .frame(height: gridHeight(for: metrics))
        .onPreferenceChange(HeatmapGridWidthPreferenceKey.self) { width in
            if abs(width - measuredGridWidth) > 0.5 {
                measuredGridWidth = width
            }
        }
    }

    private var cellSpacing: CGFloat { 2 }

    private func gridHeight(for metrics: HeatmapGridMetrics) -> CGFloat {
        8 + cellSpacing + 7 * metrics.cellSide + 6 * cellSpacing
    }

    private func gridMetrics(for measuredWidth: CGFloat) -> HeatmapGridMetrics {
        let labelWidth: CGFloat = 28
        let fallbackWidth: CGFloat = 520
        let availableWidth = measuredWidth > 1 ? measuredWidth : fallbackWidth
        let usableWidth = max(0, availableWidth - labelWidth - cellSpacing * 24)
        let rawSide = usableWidth / 24
        // Keep the grid strictly within the card. The first layout pass can
        // happen before GeometryReader has a real width; use a conservative
        // fallback so a nested popover cannot inflate itself and then keep
        // measuring the inflated width.
        let cellSide = min(max(rawSide, 9), 30)
        return HeatmapGridMetrics(
            labelWidth: labelWidth,
            cellSide: cellSide,
            cellSpacing: cellSpacing
        )
    }

    private func cellColor(weekday: Int, hour: Int, max: Int) -> Color {
        let value = heatmap.cells[weekday][hour]
        guard value > 0, max > 0 else { return Color.primary.opacity(0.05) }
        // Log-ish scaling so light hours don't disappear.
        let normalized = log1p(Double(value)) / log1p(Double(max))
        return intensityColor(intensity: normalized)
    }

    private func intensityColor(intensity: Double) -> Color {
        let clamped = min(max(intensity, 0), 1)
        // Blend from a faint blue to a warm orange.
        let r = 0.42 + (0.97 - 0.42) * clamped
        let g = 0.60 - (0.60 - 0.55) * clamped
        let b = 0.97 - (0.97 - 0.20) * clamped
        return Color(red: r, green: g, blue: b).opacity(0.35 + 0.65 * clamped)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12am"
        case 12: return "12pm"
        case 6, 18: return "\(hour > 12 ? hour - 12 : hour)\(hour >= 12 ? "pm" : "am")"
        default: return "\(hour)"
        }
    }

    private func cellTooltip(weekday: Int, hour: Int) -> String {
        let value = heatmap.cells[weekday][hour]
        let day = weekdayLabels[weekday]
        let label: String
        if value < 1_000 { label = "\(value) tok" }
        else if value < 1_000_000 { label = String(format: "%.1fk tok", Double(value) / 1_000) }
        else { label = String(format: "%.2fM tok", Double(value) / 1_000_000) }
        return "\(day) \(hourLabel(hour)) · \(label)"
    }

    private var peakLabel: String {
        var bestValue = 0
        var bestDay = 0
        var bestHour = 0
        for (d, row) in heatmap.cells.enumerated() {
            for (h, v) in row.enumerated() where v > bestValue {
                bestValue = v
                bestDay = d
                bestHour = h
            }
        }
        if bestValue == 0 { return "" }
        return "Peak: \(weekdayLabels[bestDay]) \(hourLabel(bestHour))"
    }
}

private struct HeatmapGridMetrics {
    let labelWidth: CGFloat
    let cellSide: CGFloat
    let cellSpacing: CGFloat

    var hourBlockWidth: CGFloat {
        cellSide * 6 + cellSpacing * 5
    }

    var cellCornerRadius: CGFloat {
        min(2.5, max(1.5, cellSide * 0.16))
    }
}

private struct HeatmapGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
