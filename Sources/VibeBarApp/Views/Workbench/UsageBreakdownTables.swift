import SwiftUI
import VibeBarCore

/// The bottom half of the Usage Stats page: the same range, read four ways.
///
/// This deliberately does not use SwiftUI's `Table`. AppKit owns too much of
/// that control's chrome and column sizing, which makes the Workbench surface
/// look unlike the rest of Porcelain and clips its trailing numeric columns.
struct UsageBreakdownTables: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var sortedProviders: [UsageProviderStat] {
        model.companyProviderStats.sorted { $0.costMicros > $1.costMicros }
    }

    private var sortedModels: [UsageModelStat] {
        model.modelStats.sorted { $0.costMicros > $1.costMicros }
    }

    private var populatedPeriods: [UsageTrendPoint] {
        Array(model.trend.points.filter { $0.totalTokens > 0 || $0.costMicros != 0 }.reversed())
    }

    var body: some View {
        CardShell(density: density, spacing: 12) {
            header
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(UsageStatsViewModel.Breakdown.allCases) { value in
                    let selected = model.activeBreakdown == value
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            model.setActiveBreakdown(value)
                        }
                    } label: {
                        Text(value.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 11)
                            .frame(minHeight: 27)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected
                                        ? WorkbenchPorcelain.selectedNavigationFill(for: colorScheme)
                                        : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        selected
                                            ? WorkbenchPorcelain.hairline(for: colorScheme)
                                            : Color.clear,
                                        lineWidth: 0.7
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(value.title)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(WorkbenchPorcelain.fieldFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: 0.7)
            )

            Spacer(minLength: 8)

            Text(countSummary)
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if model.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading more requests")
            }
        }
    }

    private var countSummary: String {
        switch model.activeBreakdown {
        case .periods:
            return "\(populatedPeriods.count) active \(periodUnit)"
                + (populatedPeriods.count == 1 ? "" : "s")
        case .requests:
            let loaded = model.requestRows.count
            let total = model.requestTotalCount
            return loaded < total
                ? "\(loaded) of \(total) requests"
                : "\(total) request\(total == 1 ? "" : "s")"
        case .providers:
            return "\(model.companyProviderStats.count) compan\(model.companyProviderStats.count == 1 ? "y" : "ies")"
        case .models:
            return "\(model.modelStats.count) model\(model.modelStats.count == 1 ? "" : "s")"
        }
    }

    // MARK: - Tables

    @ViewBuilder
    private var content: some View {
        switch model.activeBreakdown {
        case .periods:
            if populatedPeriods.isEmpty {
                empty("No active periods in this range")
            } else {
                periodsTable
            }
        case .requests:
            if model.requestRows.isEmpty {
                empty("No request-level rows in this range")
            } else {
                requestsTable
            }
        case .providers:
            if sortedProviders.isEmpty {
                empty("No provider totals in this range")
            } else {
                providersTable
            }
        case .models:
            if sortedModels.isEmpty {
                empty("No model totals in this range")
            } else {
                modelsTable
            }
        }
    }

    /// The Period, Provider and Model grids borrow the card's available
    /// width. Their trailing values are never hidden behind a scroller at the
    /// ordinary Workbench width; only their descriptive leading column flexes.
    private var periodsTable: some View {
        GeometryReader { proxy in
            let contentWidth = proxy.size.width - UsageTableMetrics.horizontalInset * 2
            let periodWidth = max(170, contentWidth - 5 * 108)
            VStack(spacing: 0) {
                tableHeader {
                    headerCell(periodColumnTitle, width: periodWidth)
                    headerCell("Input", width: 108, alignment: .trailing)
                    headerCell("Output", width: 108, alignment: .trailing)
                    headerCell("Cache", width: 108, alignment: .trailing)
                    headerCell("Tokens", width: 108, alignment: .trailing)
                    headerCell("Cost", width: 108, alignment: .trailing)
                }
                LazyVStack(spacing: 0) {
                    ForEach(populatedPeriods, id: \.bucketStart) { point in
                        PorcelainUsageRow(accessibilityLabel: periodAccessibilityLabel(point)) {
                            valueCell(period(point.bucketStart), width: periodWidth, tooltip: period(point.bucketStart))
                            numericCell(point.freshInput, width: 108)
                            numericCell(point.output, width: 108)
                            numericCell(point.cacheRead + point.cacheCreation, width: 108)
                            numericCell(point.totalTokens, width: 108, emphasis: true)
                            moneyCell(point.costMicros, width: 108, emphasis: true)
                        }
                    }
                }
            }
        }
        .frame(height: tableHeight(for: populatedPeriods.count))
    }

    /// Requests intentionally retain a horizontal scroll surface: a request
    /// carries seven useful fields and compressing it would erase the model or
    /// tier. The last realized row remains the paging trigger.
    private var requestsTable: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                tableHeader {
                    headerCell("Time", width: 138)
                    headerCell("SubProvider", width: 138)
                    headerCell("Model", width: 220)
                    headerCell("Input", width: 114, alignment: .trailing)
                    headerCell("Output", width: 88, alignment: .trailing)
                    headerCell("Cost", width: 96, alignment: .trailing)
                    headerCell("Tier", width: 86)
                }
                LazyVStack(spacing: 0) {
                    ForEach(model.requestRows) { row in
                        PorcelainUsageRow(accessibilityLabel: requestAccessibilityLabel(row)) {
                            valueCell(timestamp(row.date), width: 138, secondary: true, tooltip: timestamp(row.date))
                            subProviderCell(row.tool, width: 138)
                            valueCell(
                                UsageModelNaming.canonicalDisplayName(row.model),
                                width: 220,
                                tooltip: row.model
                            )
                            inputCell(row, width: 114)
                            numericCell(row.output, width: 88)
                            optionalMoneyCell(row.costMicros, width: 96)
                            valueCell(row.serviceTier ?? "—", width: 86, secondary: true, tooltip: row.serviceTier)
                        }
                        .onAppear { loadMoreIfLast(row) }
                    }
                }
            }
            .frame(minWidth: 898, alignment: .leading)
        }
        .accessibilityLabel("Request usage table")
        .frame(height: tableHeight(for: model.requestRows.count))
    }

    private var providersTable: some View {
        GeometryReader { proxy in
            let contentWidth = proxy.size.width - UsageTableMetrics.horizontalInset * 2
            let providerWidth = max(180, contentWidth - 112 - 132 - 120)
            VStack(spacing: 0) {
                tableHeader {
                    headerCell("Provider", width: providerWidth)
                    headerCell("Requests", width: 112, alignment: .trailing)
                    headerCell("Tokens", width: 132, alignment: .trailing)
                    headerCell("Cost", width: 120, alignment: .trailing)
                }
                LazyVStack(spacing: 0) {
                    ForEach(sortedProviders) { stat in
                        PorcelainUsageRow(accessibilityLabel: providerAccessibilityLabel(stat)) {
                            companyCell(stat.tool, width: providerWidth)
                            countCell(stat.requests, width: 112)
                            numericCell(stat.totalTokens, width: 132, emphasis: true)
                            moneyCell(stat.costMicros, width: 120, emphasis: true)
                        }
                    }
                }
            }
        }
        .frame(height: tableHeight(for: sortedProviders.count))
    }

    private var modelsTable: some View {
        GeometryReader { proxy in
            let contentWidth = proxy.size.width - UsageTableMetrics.horizontalInset * 2
            let modelWidth = max(200, contentWidth - 112 - 132 - 120 - 128)
            VStack(spacing: 0) {
                tableHeader {
                    headerCell("Model", width: modelWidth)
                    headerCell("Requests", width: 112, alignment: .trailing)
                    headerCell("Tokens", width: 132, alignment: .trailing)
                    headerCell("Cost", width: 120, alignment: .trailing)
                    headerCell("Avg/req", width: 128, alignment: .trailing)
                }
                LazyVStack(spacing: 0) {
                    ForEach(sortedModels) { stat in
                        PorcelainUsageRow(accessibilityLabel: modelAccessibilityLabel(stat)) {
                            valueCell(
                                UsageModelNaming.canonicalDisplayName(stat.model),
                                width: modelWidth,
                                tooltip: stat.model
                            )
                            countCell(stat.requests, width: 112)
                            numericCell(stat.totalTokens, width: 132, emphasis: true)
                            moneyCell(stat.costMicros, width: 120, emphasis: true)
                            moneyCell(stat.avgCostMicrosPerRequest, width: 128, secondary: true)
                        }
                    }
                }
            }
        }
        .frame(height: tableHeight(for: sortedModels.count))
    }

    // MARK: - Cells

    private func tableHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .frame(minHeight: 27)
        .padding(.horizontal, UsageTableMetrics.horizontalInset)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WorkbenchPorcelain.hairline(for: colorScheme))
                .frame(height: 0.7)
        }
        .accessibilityHidden(true)
    }

    private func headerCell(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.65)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func valueCell(
        _ value: String,
        width: CGFloat,
        secondary: Bool = false,
        tooltip: String? = nil
    ) -> some View {
        Text(value)
            .font(bodyFont)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .help(tooltip ?? value)
    }

    private func subProviderCell(_ tool: ToolType, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            ToolBrandBadge(tool: tool, iconSize: 13, containerSize: 16)
            Text(tool.productName)
                .font(bodyFont)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .help("\(tool.vendorName) · \(tool.productName)")
    }

    private func companyCell(_ tool: ToolType, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            ToolBrandBadge(tool: tool, iconSize: 13, containerSize: 16)
            Text(tool.vendorName)
                .font(bodyFont)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .help(tool.vendorName)
    }

    private func inputCell(_ row: UsageRequestRow, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(UsageFormatting.compactTokens(row.freshInput))
                .font(numericFont)
            if row.cacheRead > 0 || row.cacheCreation > 0 {
                Text("R \(UsageFormatting.compactTokens(row.cacheRead)) · W \(UsageFormatting.compactTokens(row.cacheCreation))")
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .trailing)
        .help("Fresh input: \(UsageFormatting.formatTokens(row.freshInput))\nCache read: \(UsageFormatting.formatTokens(row.cacheRead))\nCache write: \(UsageFormatting.formatTokens(row.cacheCreation))")
    }

    private func numericCell(
        _ value: Int64,
        width: CGFloat,
        emphasis: Bool = false
    ) -> some View {
        Text(UsageFormatting.compactTokens(value))
            .font(numericFont)
            .fontWeight(emphasis ? .semibold : .regular)
            .frame(width: width, alignment: .trailing)
            .help(UsageFormatting.formatTokens(value))
    }

    private func countCell(_ value: Int, width: CGFloat) -> some View {
        Text(value.formatted(.number.grouping(.automatic)))
            .font(numericFont)
            .frame(width: width, alignment: .trailing)
            .help("\(value.formatted(.number.grouping(.automatic))) requests")
    }

    private func moneyCell(
        _ micros: Int64,
        width: CGFloat,
        emphasis: Bool = false,
        secondary: Bool = false
    ) -> some View {
        Text(UsageFormatting.formatMicroUSD(micros, precision: secondary ? 4 : 2))
            .font(numericFont)
            .fontWeight(emphasis ? .semibold : .regular)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .frame(width: width, alignment: .trailing)
            .help(UsageFormatting.formatMicroUSD(micros, precision: 6))
    }

    private func optionalMoneyCell(_ micros: Int64?, width: CGFloat) -> some View {
        Group {
            if let micros {
                moneyCell(micros, width: width)
            } else {
                Text("unpriced")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: width, alignment: .trailing)
                    .help("No price was available for this request")
            }
        }
    }

    private func empty(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WorkbenchPorcelain.fieldFill(for: colorScheme).opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: 0.7)
        )
        .accessibilityElement(children: .combine)
    }

    private func loadMoreIfLast(_ row: UsageRequestRow) {
        guard row.id == model.requestRows.last?.id else { return }
        model.loadMoreRequests()
    }

    /// Header plus 34-point rows, instead of a density-dependent empty pane.
    /// The parent Usage Stats scroller owns vertical scrolling, so this is
    /// deliberately the real content height rather than a fixed viewport.
    private func tableHeight(for rowCount: Int) -> CGFloat {
        CGFloat(max(rowCount, 1)) * 34 + 27
    }

    private var bodyFont: Font {
        .system(size: 11)
    }

    private var numericFont: Font {
        .system(size: 11, weight: .regular, design: .rounded).monospacedDigit()
    }

    private func timestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    private func period(_ date: Date) -> String {
        let formatter: DateFormatter
        switch model.trend.bucket {
        case .hour: formatter = Self.periodHourFormatter
        case .day: formatter = Self.periodDayFormatter
        case .week: formatter = Self.periodWeekFormatter
        }
        return formatter.string(from: date)
    }

    private var periodUnit: String {
        switch model.trend.bucket {
        case .hour: "hour"
        case .day: "day"
        case .week: "week"
        }
    }

    private var periodColumnTitle: String {
        switch model.trend.bucket {
        case .hour: "Hour"
        case .day: "Day"
        case .week: "Week of"
        }
    }

    private func periodAccessibilityLabel(_ point: UsageTrendPoint) -> String {
        "\(period(point.bucketStart)), \(UsageFormatting.formatTokens(point.totalTokens)), \(UsageFormatting.formatMicroUSD(point.costMicros))"
    }

    private func requestAccessibilityLabel(_ row: UsageRequestRow) -> String {
        "\(timestamp(row.date)), \(row.tool.productName), \(UsageModelNaming.canonicalDisplayName(row.model)), \(UsageFormatting.formatTokens(row.totalTokens)), \(row.costMicros.map { UsageFormatting.formatMicroUSD($0) } ?? "unpriced")"
    }

    private func providerAccessibilityLabel(_ stat: UsageProviderStat) -> String {
        "\(stat.tool.vendorName), \(stat.requests) requests, \(UsageFormatting.formatTokens(stat.totalTokens)), \(UsageFormatting.formatMicroUSD(stat.costMicros))"
    }

    private func modelAccessibilityLabel(_ stat: UsageModelStat) -> String {
        "\(UsageModelNaming.canonicalDisplayName(stat.model)), \(stat.requests) requests, \(UsageFormatting.formatTokens(stat.totalTokens)), \(UsageFormatting.formatMicroUSD(stat.costMicros))"
    }

    /// Cached: request rows can be formatted while scrolling a long ledger.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMd HH:mm:ss")
        return formatter
    }()

    private static let periodHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdHHmm")
        return formatter
    }()

    private static let periodDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter
    }()

    private static let periodWeekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}

/// A compact row with a restrained hover treatment. Keeping the divider with
/// its row makes all four tables line up identically without AppKit table
/// selection chrome or alternating system backgrounds.
private struct PorcelainUsageRow<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content()
            }
            .frame(minHeight: 33)
            .padding(.horizontal, UsageTableMetrics.horizontalInset)
            .background(isHovered ? WorkbenchPorcelain.hoverFill(for: colorScheme) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }

            Rectangle()
                .fill(WorkbenchPorcelain.hairline(for: colorScheme).opacity(0.72))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
}

private enum UsageTableMetrics {
    static let horizontalInset: CGFloat = 9
}
