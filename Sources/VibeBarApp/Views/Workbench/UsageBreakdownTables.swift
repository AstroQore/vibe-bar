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

    private var sortedProjects: [UsageProjectStat] {
        model.projectStats.sorted { $0.totalTokens > $1.totalTokens }
    }

    private var populatedPeriods: [UsageTrendPoint] {
        Array(model.trend.points.filter { $0.totalTokens > 0 || $0.costMicros != 0 }.reversed())
    }

    /// Hourly over a month is ~720 rows; realizing them all makes the page
    /// scroller diff every one on each pass. The table shows a viewport and
    /// grows on request. Reset when the underlying series identity changes.
    private static let periodPageSize = 120
    @State private var visiblePeriodLimit = UsageBreakdownTables.periodPageSize

    /// The active breakdown's rows, derived once per body pass.
    ///
    /// Each case is a sort or a filter over the whole result set, and the
    /// header count, the empty check, the table and its height each used to
    /// ask the computed property for it again — up to eight derivations of the
    /// same array per pass, on a page whose row count runs into the hundreds.
    private enum BreakdownRows {
        case periods([UsageTrendPoint])
        case requests
        case providers([UsageProviderStat])
        case projects([UsageProjectStat])
        case models([UsageModelStat])
    }

    private var activeRows: BreakdownRows {
        switch model.activeBreakdown {
        case .periods:   .periods(populatedPeriods)
        case .requests:  .requests
        case .providers: .providers(sortedProviders)
        case .projects:  .projects(sortedProjects)
        case .models:    .models(sortedModels)
        }
    }

    var body: some View {
        let rows = activeRows
        CardShell(density: density, spacing: 12) {
            header(rows)
            content(rows)
        }
    }

    // MARK: - Header

    private func header(_ rows: BreakdownRows) -> some View {
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
                            .frame(minWidth: 72, minHeight: 28)
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
                                        lineWidth: Theme.Card.hairlineWidth
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.vibeBar)
                    .contentShape(Rectangle())
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
                    .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: Theme.Card.hairlineWidth)
            )

            Spacer(minLength: 8)

            Text(countSummary(rows))
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

    private func countSummary(_ rows: BreakdownRows) -> String {
        switch rows {
        case .periods(let points):
            return "\(points.count) active \(periodUnit)"
                + (points.count == 1 ? "" : "s")
        case .requests:
            let loaded = model.requestRows.count
            let total = model.requestTotalCount
            return loaded < total
                ? "\(loaded) of \(total) requests"
                : "\(total) request\(total == 1 ? "" : "s")"
        case .providers:
            return "\(model.companyProviderStats.count) compan\(model.companyProviderStats.count == 1 ? "y" : "ies")"
        case .projects:
            return "\(model.projectStats.count) project\(model.projectStats.count == 1 ? "" : "s") · up to 30 d detail"
        case .models:
            return "\(model.modelStats.count) model\(model.modelStats.count == 1 ? "" : "s")"
        }
    }

    // MARK: - Tables

    @ViewBuilder
    private func content(_ rows: BreakdownRows) -> some View {
        switch rows {
        case .periods(let points):
            if points.isEmpty {
                empty("No active periods in this range")
            } else {
                periodsTable(points)
            }
        case .requests:
            if model.requestRows.isEmpty {
                empty("No request-level rows in this range")
            } else {
                requestsTable
            }
        case .providers(let stats):
            if stats.isEmpty {
                empty("No provider totals in this range")
            } else {
                providersTable(stats)
            }
        case .projects(let stats):
            if stats.isEmpty {
                empty("No project-attributed Codex or Claude usage in this range")
            } else {
                projectsTable(stats)
            }
        case .models(let stats):
            if stats.isEmpty {
                empty("No model totals in this range")
            } else {
                modelsTable(stats)
            }
        }
    }

    /// The Period, Provider and Model grids borrow the card's available
    /// width. Their trailing values are never hidden behind a scroller at the
    /// ordinary Workbench width; only their descriptive leading column flexes.
    private func periodsTable(_ points: [UsageTrendPoint]) -> some View {
        GeometryReader { proxy in
            let columns = PeriodColumns(
                title: periodColumnTitle,
                contentWidth: proxy.size.width - UsageTableMetrics.horizontalInset * 2
            )
            VStack(spacing: 0) {
                tableHeader(columns.all)
                LazyVStack(spacing: 0) {
                    ForEach(points.prefix(visiblePeriodLimit), id: \.bucketStart) { point in
                        let label = period(point.bucketStart)
                        PorcelainUsageRow(
                            accessibilityLabel: periodAccessibilityLabel(point, label: label)
                        ) {
                            valueCell(label, columns.period, tooltip: label)
                            numericCell(point.freshInput, columns.input)
                            numericCell(point.output, columns.output)
                            numericCell(point.cacheRead + point.cacheCreation, columns.cache)
                            numericCell(point.totalTokens, columns.tokens, emphasis: true)
                            moneyCell(point.costMicros, columns.cost, emphasis: true)
                        }
                    }
                    if points.count > visiblePeriodLimit {
                        Button {
                            visiblePeriodLimit += Self.periodPageSize
                        } label: {
                            Text("Show \(min(Self.periodPageSize, points.count - visiblePeriodLimit)) more of \(points.count) periods")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.vibeBar)
                    }
                }
            }
        }
        .frame(height: tableHeight(for: visiblePeriodRowCount(points)))
        // Any new result series — bucket size, range, window, or filter
        // change — starts the viewport over; an expanded limit must not
        // carry into a different series.
        .onChange(of: periodSeriesIdentity) { _, _ in
            visiblePeriodLimit = Self.periodPageSize
        }
    }

    /// Cheap identity for the trend series: the controls that replace it
    /// change at least one of these.
    private var periodSeriesIdentity: String {
        let first = model.trend.points.first?.bucketStart.timeIntervalSince1970 ?? 0
        let last = model.trend.points.last?.bucketStart.timeIntervalSince1970 ?? 0
        return "\(model.trend.bucket)|\(model.trend.points.count)|\(first)|\(last)"
    }

    /// Rows the clamped table actually shows, load-more row included. Takes
    /// the already-filtered periods so the height doesn't re-derive them.
    private func visiblePeriodRowCount(_ points: [UsageTrendPoint]) -> Int {
        let shown = min(points.count, visiblePeriodLimit)
        return shown + (points.count > visiblePeriodLimit ? 1 : 0)
    }

    /// Requests intentionally retain a horizontal scroll surface: a request
    /// carries seven useful fields and compressing it would erase the model or
    /// tier.
    ///
    /// Unlike the other three tables this one owns its vertical scrolling too,
    /// clamped to `requestsMaxViewportHeight`. A `LazyVStack` only culls what
    /// its enclosing scroll view clips, and the table used to hand the parent
    /// scroller its full content height — so every loaded row realized, and
    /// the last row's `onAppear` immediately asked for the next page, which
    /// realized more rows, which fired again. Paging is an explicit button
    /// now; nothing chains.
    private var requestsTable: some View {
        GeometryReader { proxy in
            let columns = RequestColumns(tableWidth: proxy.size.width)
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(model.requestRows) { row in
                            let time = timestamp(row.date)
                            let modelName = UsageModelNaming.canonicalDisplayName(row.model)
                            PorcelainUsageRow(
                                accessibilityLabel: requestAccessibilityLabel(
                                    row, time: time, model: modelName
                                )
                            ) {
                                valueCell(time, columns.time, secondary: true)
                                harnessCell(row.harness, columns.harness)
                                valueCell(modelName, columns.model, tooltip: row.model)
                                inputCell(row, columns.input)
                                numericCell(row.output, columns.output)
                                optionalMoneyCell(row.costMicros, columns.cost)
                                valueCell(row.serviceTier ?? "—", columns.tier, secondary: true)
                            }
                        }
                        if model.hasMoreRequests { loadMoreRow }
                    } header: {
                        // Same column spec and the same `UsageTableMetrics`
                        // inset as the rows: a pinned header sits in its own
                        // layout pass, so nothing else keeps the two in step.
                        tableHeader(columns.all)
                            // Opaque: a pinned header floats over the rows it
                            // labels, and flat surfaces cast no shadow to
                            // separate them.
                            .background(WorkbenchPorcelain.overlayFill(for: colorScheme))
                    }
                }
                .frame(width: columns.tableWidth, alignment: .leading)
            }
            .accessibilityLabel("Request usage table")
        }
        .frame(height: requestsViewportHeight)
    }

    /// Explicit paging. An `onAppear` sentinel on the last row cannot tell
    /// "the user scrolled to the end" from "SwiftUI realized the row", and the
    /// second reading walks the whole ledger one 50-row publish at a time.
    private var loadMoreRow: some View {
        let remaining = max(0, model.requestTotalCount - model.requestRows.count)
        return Button {
            model.loadMoreRequests()
        } label: {
            HStack(spacing: 6) {
                if model.isLoadingMore {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(model.isLoadingMore
                    ? "Loading more requests…"
                    : "Load more (\(remaining.formatted(.number.grouping(.automatic))) remaining)")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 33)
            .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar)
        .disabled(model.isLoadingMore)
    }

    /// Enough rows to read a burst of activity without handing SwiftUI a
    /// viewport tall enough to realize a whole page at once.
    private static let requestsMaxViewportHeight: CGFloat = 27 + 34 * 15

    private var requestsViewportHeight: CGFloat {
        let rows = model.requestRows.count + (model.hasMoreRequests ? 1 : 0)
        return min(tableHeight(for: rows), Self.requestsMaxViewportHeight)
    }

    private func providersTable(_ stats: [UsageProviderStat]) -> some View {
        GeometryReader { proxy in
            let columns = ProviderColumns(
                contentWidth: proxy.size.width - UsageTableMetrics.horizontalInset * 2
            )
            VStack(spacing: 0) {
                tableHeader(columns.all)
                LazyVStack(spacing: 0) {
                    ForEach(stats) { stat in
                        let vendor = stat.tool.vendorName
                        PorcelainUsageRow(
                            accessibilityLabel: providerAccessibilityLabel(stat, vendor: vendor)
                        ) {
                            companyCell(stat.tool, name: vendor, columns.provider)
                            countCell(stat.requests, columns.requests)
                            numericCell(stat.totalTokens, columns.tokens, emphasis: true)
                            moneyCell(stat.costMicros, columns.cost, emphasis: true)
                        }
                    }
                }
            }
        }
        .frame(height: tableHeight(for: stats.count))
    }

    private func modelsTable(_ stats: [UsageModelStat]) -> some View {
        GeometryReader { proxy in
            let columns = ModelColumns(
                contentWidth: proxy.size.width - UsageTableMetrics.horizontalInset * 2
            )
            VStack(spacing: 0) {
                tableHeader(columns.all)
                LazyVStack(spacing: 0) {
                    ForEach(stats) { stat in
                        let name = UsageModelNaming.canonicalDisplayName(stat.model)
                        PorcelainUsageRow(
                            accessibilityLabel: modelAccessibilityLabel(stat, name: name)
                        ) {
                            valueCell(name, columns.model, tooltip: stat.model)
                            countCell(stat.requests, columns.requests)
                            numericCell(stat.totalTokens, columns.tokens, emphasis: true)
                            moneyCell(stat.costMicros, columns.cost, emphasis: true)
                            moneyCell(stat.avgCostMicrosPerRequest, columns.average, secondary: true)
                        }
                    }
                }
            }
        }
        .frame(height: tableHeight(for: stats.count))
    }

    private func projectsTable(_ stats: [UsageProjectStat]) -> some View {
        GeometryReader { proxy in
            let columns = ProviderColumns(
                contentWidth: proxy.size.width - UsageTableMetrics.horizontalInset * 2
            )
            VStack(spacing: 0) {
                tableHeader(columns.all)
                LazyVStack(spacing: 0) {
                    ForEach(stats) { stat in
                        PorcelainUsageRow(
                            accessibilityLabel: "\(stat.name), \(stat.requests) requests, "
                                + "\(UsageFormatting.formatTokens(stat.totalTokens)), "
                                + UsageFormatting.formatMicroUSD(stat.costMicros)
                        ) {
                            valueCell(stat.name, columns.provider, tooltip: stat.path)
                            countCell(stat.requests, columns.requests)
                            numericCell(stat.totalTokens, columns.tokens, emphasis: true)
                            moneyCell(stat.costMicros, columns.cost, emphasis: true)
                        }
                    }
                }
            }
        }
        .frame(height: tableHeight(for: stats.count))
    }

    // MARK: - Cells

    /// The header renders straight from the column spec the rows beneath it
    /// use, so a width or an alignment cannot drift between the two.
    private func tableHeader(_ columns: [UsageTableColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Text(column.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.65)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: column.width, alignment: column.frameAlignment)
            }
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

    /// `.help` installs a tracking area, so seven per row across fifty rows
    /// is three hundred and fifty of them for one table. It is opt-in here
    /// and reserved for cells that can truncate — passing the cell's own
    /// visible text back as its tooltip bought nothing.
    private func valueCell(
        _ value: String,
        _ column: UsageTableColumn,
        secondary: Bool = false,
        tooltip: String? = nil
    ) -> some View {
        Text(value)
            .font(bodyFont)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: column.width, alignment: column.frameAlignment)
            .modifier(OptionalHelp(tooltip))
    }

    /// A request row is usage, so it names the harness that produced it, not
    /// the quota SubProvider it bills against (AGENTS.md § 7.1). The badge
    /// still follows the L1 company, matching the Harness Mix card.
    private func harnessCell(_ harness: Harness, _ column: UsageTableColumn) -> some View {
        HStack(spacing: 7) {
            ToolBrandBadge(tool: harness.company, iconSize: 13, containerSize: 16)
            Text(harness.displayName)
                .font(bodyFont)
                .lineLimit(1)
        }
        .frame(width: column.width, alignment: column.frameAlignment)
        .help("\(harness.companyName) · \(harness.displayName)")
    }

    private func companyCell(
        _ tool: ToolType,
        name: String,
        _ column: UsageTableColumn
    ) -> some View {
        HStack(spacing: 7) {
            ToolBrandBadge(tool: tool, iconSize: 13, containerSize: 16)
            Text(name)
                .font(bodyFont)
                .lineLimit(1)
        }
        .frame(width: column.width, alignment: column.frameAlignment)
    }

    /// The one two-line cell in the four tables. Its first line carries the
    /// column's number, which is why the row aligns on `.firstTextBaseline`:
    /// otherwise every single-line cell in the row floats to the midpoint of
    /// this one and nothing lines up with the header above it.
    private func inputCell(_ row: UsageRequestRow, _ column: UsageTableColumn) -> some View {
        VStack(alignment: column.alignment, spacing: 1) {
            Text(UsageFormatting.compactTokens(row.freshInput))
                .font(numericFont)
            if row.cacheRead > 0 || row.cacheCreation > 0 {
                Text("R \(UsageFormatting.compactTokens(row.cacheRead)) · W \(UsageFormatting.compactTokens(row.cacheCreation))")
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: column.width, alignment: column.frameAlignment)
        .help("Fresh input: \(UsageFormatting.formatTokens(row.freshInput))\nCache read: \(UsageFormatting.formatTokens(row.cacheRead))\nCache write: \(UsageFormatting.formatTokens(row.cacheCreation))")
    }

    private func numericCell(
        _ value: Int64,
        _ column: UsageTableColumn,
        emphasis: Bool = false
    ) -> some View {
        Text(UsageFormatting.compactTokens(value))
            .font(numericFont)
            .fontWeight(emphasis ? .semibold : .regular)
            .frame(width: column.width, alignment: column.frameAlignment)
            .help(UsageFormatting.formatTokens(value))
    }

    private func countCell(_ value: Int, _ column: UsageTableColumn) -> some View {
        Text(value.formatted(.number.grouping(.automatic)))
            .font(numericFont)
            .frame(width: column.width, alignment: column.frameAlignment)
    }

    private func moneyCell(
        _ micros: Int64,
        _ column: UsageTableColumn,
        emphasis: Bool = false,
        secondary: Bool = false
    ) -> some View {
        Text(UsageFormatting.formatMicroUSD(micros, precision: secondary ? 4 : 2))
            .font(numericFont)
            .fontWeight(emphasis ? .semibold : .regular)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .frame(width: column.width, alignment: column.frameAlignment)
            .help(UsageFormatting.formatMicroUSD(micros, precision: 6))
    }

    private func optionalMoneyCell(_ micros: Int64?, _ column: UsageTableColumn) -> some View {
        Group {
            if let micros {
                moneyCell(micros, column)
            } else {
                Text("unpriced")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: column.width, alignment: column.frameAlignment)
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
                .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: Theme.Card.hairlineWidth)
        )
        .accessibilityElement(children: .combine)
    }

    /// Header plus 34-point rows. Periods / Providers / Models hand this to
    /// the parent Usage Stats scroller as their real content height; Requests
    /// clamps it into its own viewport so its `LazyVStack` can cull.
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

    private func periodAccessibilityLabel(_ point: UsageTrendPoint, label: String) -> String {
        "\(label), \(UsageFormatting.formatTokens(point.totalTokens)), \(UsageFormatting.formatMicroUSD(point.costMicros))"
    }

    private func requestAccessibilityLabel(
        _ row: UsageRequestRow,
        time: String,
        model: String
    ) -> String {
        "\(time), \(row.harness.displayName), \(model), \(UsageFormatting.formatTokens(row.totalTokens)), \(row.costMicros.map { UsageFormatting.formatMicroUSD($0) } ?? "unpriced")"
    }

    private func providerAccessibilityLabel(_ stat: UsageProviderStat, vendor: String) -> String {
        "\(vendor), \(stat.requests) requests, \(UsageFormatting.formatTokens(stat.totalTokens)), \(UsageFormatting.formatMicroUSD(stat.costMicros))"
    }

    private func modelAccessibilityLabel(_ stat: UsageModelStat, name: String) -> String {
        "\(name), \(stat.requests) requests, \(UsageFormatting.formatTokens(stat.totalTokens)), \(UsageFormatting.formatMicroUSD(stat.costMicros))"
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
            // `.firstTextBaseline`, not the default centre: the Requests
            // table's INPUT cell is two lines, and centring made every
            // single-line cell in that row sit between them instead of on
            // the line the header labels. Single-line rows are unaffected —
            // one shared baseline is the same placement as one shared centre.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
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

/// `.help` unconditionally installs a tracking area, so the cheapest tooltip
/// is the one that is never attached. Whether a given cell has one is decided
/// by its call site and never by its data, so the branch is stable and cannot
/// churn view identity while scrolling.
private struct OptionalHelp: ViewModifier {
    let tooltip: String?

    init(_ tooltip: String?) { self.tooltip = tooltip }

    func body(content: Content) -> some View {
        if let tooltip {
            content.help(tooltip)
        } else {
            content
        }
    }
}

private enum UsageTableMetrics {
    static let horizontalInset: CGFloat = 9
}

// MARK: - Column specs

/// One column of a usage table.
///
/// The header cell and every row cell beneath it read their width and their
/// horizontal alignment from the same value. Seven hand-repeated
/// `.frame(width:alignment:)` pairs per table is how a header and its rows
/// drift apart; one spec consumed twice cannot.
private struct UsageTableColumn: Identifiable {
    let title: String
    let width: CGFloat
    let alignment: HorizontalAlignment

    init(_ title: String, _ width: CGFloat, _ alignment: HorizontalAlignment = .leading) {
        self.title = title
        self.width = width
        self.alignment = alignment
    }

    var id: String { title }

    /// Vertical placement belongs to the row (`.firstTextBaseline`), so a
    /// cell's own frame only carries the horizontal axis.
    var frameAlignment: Alignment {
        Alignment(horizontal: alignment, vertical: .center)
    }
}

private extension Array where Element == UsageTableColumn {
    /// Header and rows are laid out inside the same inset, so a fixed-width
    /// table's scroll surface has to be at least this wide.
    var totalWidth: CGFloat {
        reduce(UsageTableMetrics.horizontalInset * 2) { $0 + $1.width }
    }
}

/// Period, Provider and Model borrow the card's available width: their
/// trailing values keep a width that never hides behind a scroller at the
/// ordinary Workbench width, and only the descriptive leading column flexes.
private struct PeriodColumns {
    let period: UsageTableColumn
    let input = UsageTableColumn("Input", 108, .trailing)
    let output = UsageTableColumn("Output", 108, .trailing)
    let cache = UsageTableColumn("Cache", 108, .trailing)
    let tokens = UsageTableColumn("Tokens", 108, .trailing)
    let cost = UsageTableColumn("Cost", 108, .trailing)

    init(title: String, contentWidth: CGFloat) {
        period = UsageTableColumn(title, Swift.max(170, contentWidth - 5 * 108))
    }

    var all: [UsageTableColumn] { [period, input, output, cache, tokens, cost] }
}

private struct ProviderColumns {
    let provider: UsageTableColumn
    let requests = UsageTableColumn("Requests", 112, .trailing)
    let tokens = UsageTableColumn("Tokens", 132, .trailing)
    let cost = UsageTableColumn("Cost", 120, .trailing)

    init(contentWidth: CGFloat) {
        provider = UsageTableColumn("Provider", Swift.max(180, contentWidth - 112 - 132 - 120))
    }

    var all: [UsageTableColumn] { [provider, requests, tokens, cost] }
}

private struct ModelColumns {
    let model: UsageTableColumn
    let requests = UsageTableColumn("Requests", 112, .trailing)
    let tokens = UsageTableColumn("Tokens", 132, .trailing)
    let cost = UsageTableColumn("Cost", 120, .trailing)
    let average = UsageTableColumn("Avg/req", 128, .trailing)

    init(contentWidth: CGFloat) {
        model = UsageTableColumn("Model", Swift.max(200, contentWidth - 112 - 132 - 120 - 128))
    }

    var all: [UsageTableColumn] { [model, requests, tokens, cost, average] }
}

/// Requests fills the Workbench at ordinary widths and falls back to a
/// horizontal scroller only when the viewport is narrower than its honest
/// seven-column minimum. Descriptive columns absorb the extra room; numeric
/// columns stay stable.
private struct RequestColumns {
    static let minimumContentWidth: CGFloat = 138 + 138 + 220 + 114 + 88 + 96 + 86

    let time: UsageTableColumn
    let harness: UsageTableColumn
    let model: UsageTableColumn
    let input = UsageTableColumn("Input", 114, .trailing)
    let output = UsageTableColumn("Output", 88, .trailing)
    let cost = UsageTableColumn("Cost", 96, .trailing)
    let tier: UsageTableColumn

    init(tableWidth: CGFloat) {
        let contentWidth = max(
            Self.minimumContentWidth,
            tableWidth - UsageTableMetrics.horizontalInset * 2
        )
        let extra = contentWidth - Self.minimumContentWidth
        time = UsageTableColumn("Time", 138 + extra * 0.12)
        harness = UsageTableColumn("Harness", 138 + extra * 0.20)
        model = UsageTableColumn("Model", 220 + extra * 0.50)
        tier = UsageTableColumn("Tier", 86 + extra * 0.18)
    }

    var all: [UsageTableColumn] { [time, harness, model, input, output, cost, tier] }

    var tableWidth: CGFloat { all.totalWidth }
}
