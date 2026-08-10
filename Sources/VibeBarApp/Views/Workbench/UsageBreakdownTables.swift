import SwiftUI
import VibeBarCore

/// The bottom half of the Usage Stats page: the same range, read four ways.
///
/// The selector is intentionally drawn in Vibe Bar's own card vocabulary
/// rather than using AppKit's default segmented control. Periods exposes the
/// exact buckets behind the chart, so a visual and its table can be reconciled
/// without switching to another page.
struct UsageBreakdownTables: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: Tab = .periods

    enum Tab: String, CaseIterable, Identifiable {
        case periods
        case requests
        case providers
        case models

        var id: String { rawValue }

        var title: String {
            switch self {
            case .periods:   "Periods"
            case .requests:  "Requests"
            case .providers: "Providers"
            case .models:    "Models"
            }
        }

        var systemImage: String {
            switch self {
            case .periods:   "calendar.day.timeline.leading"
            case .requests:  "list.bullet.rectangle"
            case .providers: "square.grid.2x2"
            case .models:    "cpu"
            }
        }
    }

    private var tableHeight: CGFloat {
        switch density.profile {
        case .compact:  340
        case .regular:  400
        case .spacious: 460
        }
    }

    private var sortedProviders: [UsageProviderStat] {
        model.providerStats.sorted { $0.costMicros > $1.costMicros }
    }

    private var sortedModels: [UsageModelStat] {
        model.modelStats.sorted { $0.costMicros > $1.costMicros }
    }

    private var populatedPeriods: [UsageTrendPoint] {
        Array(model.trend.points.filter { $0.totalTokens > 0 || $0.costMicros != 0 }.reversed())
    }

    var body: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            header
            content
                .frame(height: tableHeight)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { value in
                    let selected = tab == value
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { tab = value }
                    } label: {
                        Label(value.title, systemImage: value.systemImage)
                            .font(.system(size: max(10, density.segmentedFontSize - 1), weight: .semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                selected ? Color.accentColor.opacity(0.38) : Color.clear,
                                lineWidth: 0.7
                            )
                    )
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
            Spacer(minLength: 8)
            Text(countSummary)
                .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if model.isLoadingMore {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var countSummary: String {
        switch tab {
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
            return "\(model.providerStats.count) provider\(model.providerStats.count == 1 ? "" : "s")"
        case .models:
            return "\(model.modelStats.count) model\(model.modelStats.count == 1 ? "" : "s")"
        }
    }

    // MARK: - Tables

    @ViewBuilder
    private var content: some View {
        switch tab {
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

    private var periodsTable: some View {
        Table(populatedPeriods) {
            TableColumn(periodColumnTitle) { point in
                Text(period(point.bucketStart))
                    .font(bodyFont)
            }
            .width(min: 130, ideal: 190)

            TableColumn("Input") { point in
                Text(UsageFormatting.compactTokens(point.freshInput))
                    .font(numericFont)
            }
            .width(min: 82, ideal: 104)
            .alignment(.trailing)

            TableColumn("Output") { point in
                Text(UsageFormatting.compactTokens(point.output))
                    .font(numericFont)
            }
            .width(min: 82, ideal: 104)
            .alignment(.trailing)

            TableColumn("Cache") { point in
                Text(UsageFormatting.compactTokens(point.cacheRead + point.cacheCreation))
                    .font(numericFont)
            }
            .width(min: 82, ideal: 104)
            .alignment(.trailing)

            TableColumn("Tokens") { point in
                Text(UsageFormatting.compactTokens(point.totalTokens))
                    .font(numericFont)
            }
            .width(min: 88, ideal: 112)
            .alignment(.trailing)

            TableColumn("Cost") { point in
                Text(UsageFormatting.formatMicroUSD(point.costMicros))
                    .font(numericFont)
            }
            .width(min: 88, ideal: 112)
            .alignment(.trailing)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var requestsTable: some View {
        Table(model.requestRows) {
            TableColumn("Time") { row in
                Text(timestamp(row.date))
                    .font(numericFont)
                    .foregroundStyle(.secondary)
                    // The Table is the page's only lazy surface, so paging is
                    // driven from the last realized row rather than from a
                    // scroll offset the card never sees.
                    .onAppear { loadMoreIfLast(row) }
            }
            .width(min: 112, ideal: 132)

            TableColumn("Provider") { row in
                providerCell(row.tool)
            }
            .width(min: 118, ideal: 148)

            TableColumn("Model") { row in
                Text(row.model)
                    .font(bodyFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.model)
            }
            .width(min: 130, ideal: 190)

            TableColumn("Input") { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(UsageFormatting.compactTokens(row.freshInput))
                        .font(numericFont)
                    if row.cacheRead > 0 || row.cacheCreation > 0 {
                        Text("R \(UsageFormatting.compactTokens(row.cacheRead))"
                            + " · W \(UsageFormatting.compactTokens(row.cacheCreation))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 86, ideal: 104)
            .alignment(.trailing)

            TableColumn("Output") { row in
                Text(UsageFormatting.compactTokens(row.output))
                    .font(numericFont)
            }
            .width(min: 68, ideal: 82)
            .alignment(.trailing)

            TableColumn("Cost") { row in
                if let micros = row.costMicros {
                    Text(UsageFormatting.formatMicroUSD(micros))
                        .font(numericFont)
                } else {
                    Text("unpriced")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 72, ideal: 88)
            .alignment(.trailing)

            TableColumn("Tier") { row in
                Text(row.serviceTier ?? "—")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 62, ideal: 78)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var providersTable: some View {
        Table(sortedProviders) {
            TableColumn("Provider") { stat in
                providerCell(stat.tool)
            }
            .width(min: 150, ideal: 220)

            TableColumn("Requests") { stat in
                Text(stat.requests.formatted(.number.grouping(.automatic)))
                    .font(numericFont)
            }
            .width(min: 80, ideal: 100)
            .alignment(.trailing)

            TableColumn("Tokens") { stat in
                Text(UsageFormatting.compactTokens(stat.totalTokens))
                    .font(numericFont)
            }
            .width(min: 84, ideal: 110)
            .alignment(.trailing)

            TableColumn("Cost") { stat in
                Text(UsageFormatting.formatMicroUSD(stat.costMicros))
                    .font(numericFont)
            }
            .width(min: 84, ideal: 110)
            .alignment(.trailing)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var modelsTable: some View {
        Table(sortedModels) {
            TableColumn("Model") { stat in
                Text(stat.model)
                    .font(bodyFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(stat.model)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Requests") { stat in
                Text(stat.requests.formatted(.number.grouping(.automatic)))
                    .font(numericFont)
            }
            .width(min: 80, ideal: 98)
            .alignment(.trailing)

            TableColumn("Tokens") { stat in
                Text(UsageFormatting.compactTokens(stat.totalTokens))
                    .font(numericFont)
            }
            .width(min: 84, ideal: 104)
            .alignment(.trailing)

            TableColumn("Cost") { stat in
                Text(UsageFormatting.formatMicroUSD(stat.costMicros))
                    .font(numericFont)
            }
            .width(min: 84, ideal: 104)
            .alignment(.trailing)

            TableColumn("Avg/req") { stat in
                Text(UsageFormatting.formatMicroUSD(stat.avgCostMicrosPerRequest, precision: 4))
                    .font(numericFont)
                    .foregroundStyle(.secondary)
            }
            .width(min: 88, ideal: 108)
            .alignment(.trailing)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Cells

    private func providerCell(_ tool: ToolType) -> some View {
        HStack(spacing: 6) {
            ToolBrandBadge(tool: tool, iconSize: 13, containerSize: 16)
            Text(tool.menuTitle)
                .font(bodyFont)
                .lineLimit(1)
        }
        .help(tool.displayName)
    }

    private func empty(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadMoreIfLast(_ row: UsageRequestRow) {
        guard row.id == model.requestRows.last?.id else { return }
        model.loadMoreRequests()
    }

    private var bodyFont: Font {
        .system(size: max(10, density.subtitleFontSize))
    }

    private var numericFont: Font {
        .system(size: max(10, density.subtitleFontSize), design: .rounded).monospacedDigit()
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

    /// Cached: the requests table formats one of these per visible row, and
    /// building a `DateFormatter` per cell is the expensive half of scrolling.
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
