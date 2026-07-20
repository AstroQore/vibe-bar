import SwiftUI
import VibeBarCore

/// "When you use X" card. The top half is the 24-hour burn-rate
/// histogram; the bottom half is the weekday × hour heatmap. Both share
/// one X axis, one `HeatmapGridMetrics` instance, one peak label, and
/// one refresh button.
struct UsageActivityView: View {
    let heatmap: UsageHeatmap
    let density: Theme.Density
    /// Optional title override. The Overview's "all providers" version of
    /// this card uses `"When you use everything"` instead of the default
    /// derived from `heatmap.tool`.
    var titleOverride: String? = nil

    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private var barRowHeight: CGFloat { density.activityBarHeight }

    @State private var measuredGridWidth: CGFloat = 0
    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header
            content
            legend
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

    private var header: some View {
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
    }

    private var toolName: String {
        switch heatmap.tool {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .grok, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return heatmap.tool.menuTitle
        }
    }

    private var peakLabel: String {
        guard let peakH = heatmap.peakHour, let cell = heatmap.peakCell else { return "" }
        let hourStr = UsageHeatmap.formatHourLabel(peakH)
        let cellHourStr = UsageHeatmap.formatHourLabel(cell.hour)
        let dayStr = weekdayLabels[cell.weekday]
        if peakH == cell.hour {
            return "Peak \(hourStr) · \(dayStr)"
        }
        return "Peak \(hourStr) · \(dayStr) \(cellHourStr)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if heatmap.totalTokens == 0 {
            Text("No data yet")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            let metrics = HeatmapGridMetrics.compute(forWidth: measuredGridWidth)
            GeometryReader { proxy in
                let liveMetrics = HeatmapGridMetrics.compute(forWidth: proxy.size.width)
                VStack(alignment: .leading, spacing: liveMetrics.cellSpacing) {
                    barRow(metrics: liveMetrics)
                    hourAxis(metrics: liveMetrics)
                    heatmapGrid(metrics: liveMetrics)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .preference(key: HeatmapGridWidthPreferenceKey.self, value: proxy.size.width)
            }
            .frame(height: contentHeight(for: metrics))
            .onPreferenceChange(HeatmapGridWidthPreferenceKey.self) { width in
                if abs(width - measuredGridWidth) > 0.5 {
                    measuredGridWidth = width
                }
            }
        }
    }

    private func contentHeight(for metrics: HeatmapGridMetrics) -> CGFloat {
        // bar row + spacing + hour axis (8pt) + spacing + 7 cell rows
        barRowHeight
            + metrics.cellSpacing
            + 8
            + metrics.cellSpacing
            + 7 * metrics.cellSide
            + 6 * metrics.cellSpacing
    }

    // MARK: - Bar row

    private func barRow(metrics: HeatmapGridMetrics) -> some View {
        let totals = heatmap.hourTotals
        let maxTotal = totals.max() ?? 0
        return HStack(alignment: .bottom, spacing: metrics.cellSpacing) {
            yAxisTickColumn(maxTotal: maxTotal, metrics: metrics)
            ForEach(0..<24, id: \.self) { hour in
                ZStack(alignment: .bottom) {
                    Color.clear
                    RoundedRectangle(cornerRadius: metrics.cellCornerRadius, style: .continuous)
                        .fill(intensityColor(intensity: barIntensity(value: totals[hour], max: maxTotal)))
                        .frame(width: metrics.cellSide, height: barHeight(value: totals[hour], max: maxTotal))
                }
                .frame(width: metrics.cellSide, height: barRowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(height: barRowHeight)
    }

    private func yAxisTickColumn(maxTotal: Int, metrics: HeatmapGridMetrics) -> some View {
        // Three ticks: max, ~50%, 0. Right-aligned in the 28pt label gutter.
        let ticks = [maxTotal, maxTotal / 2, 0]
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { idx, tick in
                Text(formatTokens(tick))
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                if idx < ticks.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: metrics.labelWidth, height: barRowHeight, alignment: .trailing)
    }

    /// Log-scaled normalized intensity (0…1) so small columns still color.
    private func barIntensity(value: Int, max: Int) -> Double {
        guard value > 0, max > 0 else { return 0 }
        return log1p(Double(value)) / log1p(Double(max))
    }

    /// Pixel height of a single bar. Mirrors `barIntensity` (log-scaled) and
    /// floors any non-zero value at 2 pt so near-zero columns stay visible.
    private func barHeight(value: Int, max: Int) -> CGFloat {
        guard value > 0, max > 0 else { return 0 }
        let normalized = log1p(Double(value)) / log1p(Double(max))
        return CGFloat(Swift.max(2.0, normalized * Double(barRowHeight)))
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 1_000_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        if tokens < 1_000_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
    }

    // MARK: - Hour axis row

    private func hourAxis(metrics: HeatmapGridMetrics) -> some View {
        HStack(spacing: metrics.cellSpacing) {
            Text("")
                .font(.system(size: 8))
                .frame(width: metrics.labelWidth, alignment: .trailing)
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                Text(UsageHeatmap.formatHourLabel(hour))
                    .font(.system(size: 8, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: metrics.hourBlockWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 8)
    }

    // MARK: - Heatmap grid

    private func heatmapGrid(metrics: HeatmapGridMetrics) -> some View {
        let maxCell = heatmap.cells.flatMap { $0 }.max() ?? 0
        return VStack(alignment: .leading, spacing: metrics.cellSpacing) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: metrics.cellSpacing) {
                    Text(weekdayLabels[weekday])
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: metrics.labelWidth, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: metrics.cellCornerRadius, style: .continuous)
                            .fill(cellColor(weekday: weekday, hour: hour, max: maxCell))
                            .frame(width: metrics.cellSide, height: metrics.cellSide)
                            .help(cellTooltip(weekday: weekday, hour: hour))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func cellColor(weekday: Int, hour: Int, max: Int) -> Color {
        let value = heatmap.cells[weekday][hour]
        guard value > 0, max > 0 else { return Color.primary.opacity(0.05) }
        let normalized = log1p(Double(value)) / log1p(Double(max))
        return intensityColor(intensity: normalized)
    }

    private func cellTooltip(weekday: Int, hour: Int) -> String {
        let value = heatmap.cells[weekday][hour]
        let day = weekdayLabels[weekday]
        let hourStr = UsageHeatmap.formatHourLabel(hour)
        let label: String
        if value < 1_000 { label = "\(value) tok" }
        else if value < 1_000_000 { label = String(format: "%.1fk tok", Double(value) / 1_000) }
        else if value < 1_000_000_000 { label = String(format: "%.2fM tok", Double(value) / 1_000_000) }
        else { label = String(format: "%.2fB tok", Double(value) / 1_000_000_000) }
        return "\(day) \(hourStr) · \(label)"
    }

    // MARK: - Legend

    private var legend: some View {
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
}
