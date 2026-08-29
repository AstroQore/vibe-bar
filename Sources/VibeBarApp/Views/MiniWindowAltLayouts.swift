import SwiftUI
import VibeBarCore

// MARK: - Shared entry model

/// One selected field with a live bucket, flattened for the alternative mini
/// layouts (ledger / strip / tile / focus / rail). Built in the config's own
/// field order — the order *is* the arrangement.
struct MiniEntry: Identifiable {
    let tool: ToolType
    let field: MenuBarFieldOption
    let bucket: QuotaBucket
    /// Canonical L2 identity (`ToolType.quotaSubProviderName`) — what runs
    /// group by. Renaming two SubProviders identically must not merge them.
    let subProviderName: String
    /// The resolved label a human sees; identity above, display here.
    let subProviderDisplayName: String
    let companyName: String
    /// Resolved L3 quota-group label (custom name applied); nil for a primary
    /// bucket like Gemini Web's "5 Hours".
    let groupLabel: String?
    let customLabel: String?

    var id: String { field.id }

    /// Row label for list-style layouts: the custom label wins; otherwise a
    /// grouped bucket reads "Spark · Weekly" and a primary one reads its
    /// window. Never an invented abbreviation — "WK" is a name the user can
    /// choose, not a default they get.
    var rowLabel: String {
        if let customLabel, !customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customLabel
        }
        if let groupLabel {
            return "\(groupLabel) · \(bucket.title)"
        }
        return bucket.title
    }

    static func entries(
        config: MiniWindowConfig,
        settings: MiniWindowSettings,
        registry: QuotaFieldRegistry,
        quota: (ToolType) -> AccountQuota?
    ) -> [MiniEntry] {
        var quotaByTool: [ToolType: AccountQuota] = [:]
        return config.fieldIds.compactMap { fieldId in
            guard let field = MenuBarFieldCatalog.field(id: fieldId, registry: registry) else { return nil }
            let account: AccountQuota?
            if let cached = quotaByTool[field.tool] {
                account = cached
            } else {
                account = quota(field.tool)
                if let account { quotaByTool[field.tool] = account }
            }
            guard let bucket = account?.bucket(id: field.bucketId) else { return nil }
            let subProviderName = field.tool.quotaSubProviderName(bucketID: field.bucketId)
            // Grouped by the shared quota-axis key, so a primary bucket reads
            // "All · Weekly" here exactly as it sits under the All branch in
            // the regular layout — bare "Weekly" rows were indistinguishable
            // once a SubProvider had more than one group.
            var groupLabel: String?
            if let key = MiniWindowGroupLabelCatalog.namingGroupKey(for: field) {
                groupLabel = settings.resolvedGroupLabel(config: config, key: key)
                    ?? MiniWindowGroupLabelCatalog.defaultLabel(for: key)
                    ?? field.dynamicGroupTitle
                    ?? bucket.groupTitle
            }
            let subProviderKey = MiniWindowGroupLabelCatalog.subProviderKey(tool: field.tool, name: subProviderName)
            return MiniEntry(
                tool: field.tool,
                field: field,
                bucket: bucket,
                subProviderName: subProviderName,
                subProviderDisplayName: settings.resolvedGroupLabel(config: config, key: subProviderKey) ?? subProviderName,
                companyName: field.tool.vendorName,
                groupLabel: groupLabel,
                customLabel: settings.resolvedFieldLabel(config: config, fieldId: field.id)
            )
        }
    }

    /// Consecutive entries sharing one L2 SubProvider, in entry order.
    static func subProviderRuns(_ entries: [MiniEntry]) -> [[MiniEntry]] {
        var runs: [[MiniEntry]] = []
        for entry in entries {
            if let last = runs.last?.last,
               last.tool == entry.tool,
               last.subProviderName == entry.subProviderName {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }

    /// Consecutive entries sharing one L1 company, in entry order.
    static func companyRuns(_ entries: [MiniEntry]) -> [[MiniEntry]] {
        var runs: [[MiniEntry]] = []
        for entry in entries {
            if let last = runs.last?.last, last.companyName == entry.companyName {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }

    /// All entries of each company merged regardless of adjacency, companies
    /// ordered by first appearance. Focus pages on this — an arrangement that
    /// interleaves companies must not create a page per run.
    static func companyGroups(_ entries: [MiniEntry]) -> [[MiniEntry]] {
        var groups: [[MiniEntry]] = []
        var indexByCompany: [String: Int] = [:]
        for entry in entries {
            if let index = indexByCompany[entry.companyName] {
                groups[index].append(entry)
            } else {
                indexByCompany[entry.companyName] = groups.count
                groups.append([entry])
            }
        }
        return groups
    }
}

private func entryPercent(_ entry: MiniEntry, mode: DisplayMode) -> Double {
    entry.bucket.displayPercent(mode, tool: entry.tool)
}

private func entryColor(_ entry: MiniEntry, mode: DisplayMode) -> Color {
    Theme.barColor(percent: entryPercent(entry, mode: mode), mode: mode)
}

/// Remaining percent regardless of the display-mode setting — the layouts use
/// it to decide which bucket is the most critical.
private func remainingPercent(_ entry: MiniEntry) -> Double {
    max(0, 100 - entry.bucket.usedPercent)
}

private struct MiniEmptyHint: View {
    var body: some View {
        Text("No selected fields have live data")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Ledger

/// One row per bucket: label · bar · percent · reset countdown. Fixed width,
/// grows downward, so the panel width no longer depends on how many buckets
/// are selected — the natural shape for a dynamic catalog.
enum MiniLedgerMetrics {
    static let width: CGFloat = 272
    static let horizontalPadding: CGFloat = 14
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let headerHeight: CGFloat = 16
    static let headerGap: CGFloat = 3
    static let rowHeight: CGFloat = 21
    static let groupGap: CGFloat = 7
    static let emptyHeight: CGFloat = 84

    static func size(entries: [MiniEntry]) -> CGSize {
        guard !entries.isEmpty else { return CGSize(width: width, height: emptyHeight) }
        let runs = MiniEntry.subProviderRuns(entries)
        var height = topPadding + bottomPadding
        for (index, run) in runs.enumerated() {
            if index > 0 { height += groupGap }
            height += headerHeight + headerGap + CGFloat(run.count) * rowHeight
        }
        return CGSize(width: width, height: height)
    }
}

struct MiniLedgerLayout: View {
    let entries: [MiniEntry]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniLedgerMetrics.width)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if entries.isEmpty {
            MiniEmptyHint()
                .frame(height: MiniLedgerMetrics.emptyHeight)
        } else {
            let runs = MiniEntry.subProviderRuns(entries)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                    if index > 0 {
                        Spacer().frame(height: MiniLedgerMetrics.groupGap)
                    }
                    header(for: run[0])
                    Spacer().frame(height: MiniLedgerMetrics.headerGap)
                    ForEach(run) { entry in
                        row(entry, now: now)
                    }
                }
            }
            .padding(.horizontal, MiniLedgerMetrics.horizontalPadding)
            .padding(.top, MiniLedgerMetrics.topPadding)
            .padding(.bottom, MiniLedgerMetrics.bottomPadding)
        }
    }

    private func header(for entry: MiniEntry) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(providerAccent(for: entry.tool))
                .frame(width: 5, height: 5)
            Text("\(entry.companyName.uppercased()) · \(entry.subProviderDisplayName.uppercased())")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(height: MiniLedgerMetrics.headerHeight, alignment: .bottomLeading)
    }

    private func row(_ entry: MiniEntry, now: Date) -> some View {
        let mode = settingsStore.displayMode
        let percent = entryPercent(entry, mode: mode)
        let color = entryColor(entry, mode: mode)
        return HStack(spacing: 8) {
            Text(entry.rowLabel)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 88, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, percent / 100))))
                }
            }
            .frame(height: 4)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 34, alignment: .trailing)
            Text(ResetCountdownFormatter.string(from: entry.bucket.resetAt, now: now) ?? "—")
                .font(.system(size: 8.5, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: MiniLedgerMetrics.rowHeight)
        .help("\(providerTitle(for: entry.tool)) · \(entry.bucket.groupTitle ?? entry.subProviderDisplayName) · \(entry.bucket.title)")
    }
}

// MARK: - Strip

/// A one-line HUD: each SubProvider shows its most critical bucket only.
/// Hovering a chip lists every selected bucket of that SubProvider. Three
/// densities, chosen per window: roomy (number beside its label), two-line
/// (number over its label), narrow (dot and number only).
enum MiniStripMetrics {
    static let dividerThickness: CGFloat = 1
    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 26
    static let emptyWidth: CGFloat = 200

    /// One cell per selected bucket in every density — the strip mirrors the
    /// menu bar's own styles (single line / two rows / compact), so nothing
    /// is summarized away behind a "worst bucket" chip anymore.
    static func chipWidth(_ density: MiniStripDensity) -> CGFloat {
        switch density {
        case .roomy:   return 132
        case .twoLine: return pairedColumnWidth
        case .narrow:  return 96
        }
    }

    static func cellFontSize(_ density: MiniStripDensity) -> CGFloat {
        density == .narrow ? 9.5 : 11.5
    }

    /// Two-line density mirrors the menu bar's two-row layout: entries pair
    /// into stacked columns, every cell carrying its full label — so the
    /// column must fit "Claude + GPT Weekly 100%"-class text, scaled down
    /// rather than abbreviated.
    static let pairedColumnWidth: CGFloat = 128
    static let pairedColumnSpacing: CGFloat = 12
    static let pairedRowSpacing: CGFloat = 2

    static func chipSpacing(_ density: MiniStripDensity) -> CGFloat {
        switch density {
        case .roomy:   return 8
        case .twoLine: return 6
        case .narrow:  return 4
        }
    }

    static func companySpacing(_ density: MiniStripDensity) -> CGFloat {
        density == .narrow ? 7 : 9
    }

    /// Height of one strip band.
    static func rowHeight(_ density: MiniStripDensity) -> CGFloat {
        switch density {
        case .roomy:   return 40
        case .twoLine: return 54
        case .narrow:  return 32
        }
    }

    static let rowGap: CGFloat = 2
    /// The strip never outgrows the screen: past this width, cells wrap into
    /// further bands. A default selection can hold twenty-plus fields, and an
    /// unwrapped run of 132-pt cells would put most of the panel off screen.
    static let maxRowWidth: CGFloat = 1180

    /// Cells per band, and how many bands `count` cells need.
    static func gridPlan(count: Int, cellWidth: CGFloat, cellSpacing: CGFloat) -> (perRow: Int, rows: Int) {
        let available = maxRowWidth - leadingPadding - trailingPadding
        let perRow = max(1, Int((available + cellSpacing) / (cellWidth + cellSpacing)))
        let rows = Int(ceil(Double(count) / Double(perRow)))
        return (perRow, rows)
    }

    static func size(entries: [MiniEntry], density: MiniStripDensity) -> CGSize {
        guard !entries.isEmpty else { return CGSize(width: emptyWidth, height: rowHeight(density)) }
        let cellCount = density == .twoLine ? (entries.count + 1) / 2 : entries.count
        let cellWidth = chipWidth(density)
        let cellSpacing = density == .twoLine ? pairedColumnSpacing : chipSpacing(density)
        let plan = gridPlan(count: cellCount, cellWidth: cellWidth, cellSpacing: cellSpacing)
        let cellsInWidestRow = min(cellCount, plan.perRow)
        let width = leadingPadding + trailingPadding
            + CGFloat(cellsInWidestRow) * cellWidth
            + CGFloat(max(0, cellsInWidestRow - 1)) * cellSpacing
        let height = CGFloat(plan.rows) * rowHeight(density)
            + CGFloat(max(0, plan.rows - 1)) * rowGap
        return CGSize(width: width, height: height)
    }
}

struct MiniStripLayout: View {
    let entries: [MiniEntry]
    let density: MiniStripDensity

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Group {
            if entries.isEmpty {
                MiniEmptyHint()
                    .frame(width: MiniStripMetrics.emptyWidth)
            } else if density == .twoLine {
                pairedColumns
            } else {
                let plan = MiniStripMetrics.gridPlan(
                    count: entries.count,
                    cellWidth: MiniStripMetrics.chipWidth(density),
                    cellSpacing: MiniStripMetrics.chipSpacing(density)
                )
                VStack(alignment: .leading, spacing: MiniStripMetrics.rowGap) {
                    ForEach(Array(entries.chunked(into: plan.perRow).enumerated()), id: \.offset) { _, band in
                        HStack(spacing: MiniStripMetrics.chipSpacing(density)) {
                            ForEach(band) { entry in
                                lineCell(entry)
                            }
                        }
                        .frame(height: MiniStripMetrics.rowHeight(density))
                    }
                }
                .padding(.leading, MiniStripMetrics.leadingPadding)
                .padding(.trailing, MiniStripMetrics.trailingPadding)
            }
        }
    }

    /// The menu bar's two-row layout, as a mini window: entries pair into
    /// stacked columns in window order — every entry gets a cell, label
    /// beside its colored number, nothing summarized away.
    private var pairedColumns: some View {
        let mode = settingsStore.displayMode
        let pairs = stride(from: 0, to: entries.count, by: 2).map { index in
            (top: entries[index], bottom: index + 1 < entries.count ? entries[index + 1] : nil)
        }
        let plan = MiniStripMetrics.gridPlan(
            count: pairs.count,
            cellWidth: MiniStripMetrics.pairedColumnWidth,
            cellSpacing: MiniStripMetrics.pairedColumnSpacing
        )
        return VStack(alignment: .leading, spacing: MiniStripMetrics.rowGap) {
            ForEach(Array(pairs.chunked(into: plan.perRow).enumerated()), id: \.offset) { _, band in
                HStack(spacing: MiniStripMetrics.pairedColumnSpacing) {
                    ForEach(Array(band.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: MiniStripMetrics.pairedRowSpacing) {
                            pairedCell(pair.top, mode: mode)
                            if let bottom = pair.bottom {
                                pairedCell(bottom, mode: mode)
                            }
                        }
                        .frame(width: MiniStripMetrics.pairedColumnWidth, alignment: .leading)
                    }
                }
                .frame(height: MiniStripMetrics.rowHeight(.twoLine))
            }
        }
        .padding(.leading, MiniStripMetrics.leadingPadding)
        .padding(.trailing, MiniStripMetrics.trailingPadding)
    }

    private func pairedCell(_ entry: MiniEntry, mode: DisplayMode) -> some View {
        let percent = entryPercent(entry, mode: mode)
        let color = entryColor(entry, mode: mode)
        return HStack(spacing: 5) {
            Text(entry.rowLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .help("\(entry.subProviderDisplayName) — \(entry.rowLabel): \(Int(percent.rounded()))%")
    }

    /// The menu bar's single-line style, one cell per bucket: full label
    /// beside its colored number. Narrow is the compact variant — the same
    /// pieces at the menu bar's small size.
    private func lineCell(_ entry: MiniEntry) -> some View {
        let mode = settingsStore.displayMode
        let percent = entryPercent(entry, mode: mode)
        let color = entryColor(entry, mode: mode)
        let size = MiniStripMetrics.cellFontSize(density)
        return HStack(spacing: 5) {
            Text(entry.rowLabel)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(width: MiniStripMetrics.chipWidth(density), alignment: .leading)
        .help("\(entry.subProviderDisplayName) — \(entry.rowLabel): \(Int(percent.rounded()))%")
    }
}

// MARK: - Tiles

/// A fixed grid, one tile per bucket: big number, thin bar, and a severity
/// stripe on the leading edge.
enum MiniTileMetrics {
    static let tileWidth: CGFloat = 106
    static let tileHeight: CGFloat = 56
    static let spacing: CGFloat = 7
    static let columns = 4
    static let horizontalPadding: CGFloat = 12
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let emptySize = CGSize(width: 240, height: 90)

    static func size(entries: [MiniEntry]) -> CGSize {
        guard !entries.isEmpty else { return emptySize }
        let columnCount = min(columns, max(1, entries.count))
        let rows = Int(ceil(Double(entries.count) / Double(columnCount)))
        let width = CGFloat(columnCount) * tileWidth
            + CGFloat(max(0, columnCount - 1)) * spacing
            + 2 * horizontalPadding
        let height = CGFloat(rows) * tileHeight
            + CGFloat(max(0, rows - 1)) * spacing
            + topPadding + bottomPadding
        return CGSize(width: width, height: height)
    }
}

struct MiniTileLayout: View {
    let entries: [MiniEntry]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Group {
            if entries.isEmpty {
                MiniEmptyHint()
                    .frame(width: MiniTileMetrics.emptySize.width, height: MiniTileMetrics.emptySize.height)
            } else {
                let columnCount = min(MiniTileMetrics.columns, max(1, entries.count))
                let rows = entries.chunked(into: columnCount)
                VStack(alignment: .leading, spacing: MiniTileMetrics.spacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: MiniTileMetrics.spacing) {
                            ForEach(row) { entry in
                                tile(entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, MiniTileMetrics.horizontalPadding)
                .padding(.top, MiniTileMetrics.topPadding)
                .padding(.bottom, MiniTileMetrics.bottomPadding)
            }
        }
    }

    private func tile(_ entry: MiniEntry) -> some View {
        let mode = settingsStore.displayMode
        let percent = entryPercent(entry, mode: mode)
        let color = entryColor(entry, mode: mode)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(providerAccent(for: entry.tool))
                            .frame(width: 5, height: 5)
                        Text(entry.rowLabel)
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule()
                                .fill(color)
                                .frame(width: max(2, proxy.size.width * min(1, max(0, percent / 100))))
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
            }
            .padding(.leading, 4)
        }
        .frame(width: MiniTileMetrics.tileWidth, height: MiniTileMetrics.tileHeight)
        .help("\(providerTitle(for: entry.tool)) · \(entry.rowLabel) · \(entry.bucket.title)")
    }
}

// MARK: - Focus

/// One company at a time, large. The chevron (or the pager dots) cycles
/// through the companies that have live entries.
enum MiniFocusMetrics {
    static let size = CGSize(width: 252, height: 210)
    static let ringSize: CGFloat = 84
    static let ringLineWidth: CGFloat = 7
}

struct MiniFocusLayout: View {
    let entries: [MiniEntry]

    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    @State private var pageIndex = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniFocusMetrics.size.width, height: MiniFocusMetrics.size.height)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // One page per selected bucket, in the window's own order — Focus
        // shows exactly the quotas the user picked, not a per-company
        // "most critical" of its own choosing.
        let pages = entries
        if pages.isEmpty {
            MiniEmptyHint()
        } else {
            let index = min(pageIndex, pages.count - 1)
            let headline = pages[index]
            let page = entries.filter {
                $0.tool == headline.tool && $0.subProviderName == headline.subProviderName
            }
            let mode = settingsStore.displayMode
            let percent = entryPercent(headline, mode: mode)
            let color = entryColor(headline, mode: mode)
            let forecast = miniQuotaForecast(
                tool: headline.tool,
                bucket: headline.bucket,
                environment: environment,
                quotaService: quotaService,
                now: now
            )
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(providerAccent(for: headline.tool))
                        .frame(width: 5, height: 5)
                    Text(headline.companyName.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.86))
                }
                Text("\(headline.subProviderDisplayName.uppercased()) · \(headline.rowLabel.uppercased())")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 210)
                RingGauge(
                    percent: percent,
                    expected: forecast.map { miniForecastPlan($0, mode: mode) },
                    color: color,
                    markerColor: miniForecastColor(forecast),
                    size: MiniFocusMetrics.ringSize,
                    lineWidth: MiniFocusMetrics.ringLineWidth
                ) {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color)
                }
                .padding(.top, 2)
                otherBucketsLine(page: page, headline: headline, mode: mode)
                Text(forecast.map { miniForecastLine($0, now: now) } ?? resetLine(headline, now: now))
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(miniForecastColor(forecast))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if pages.count <= 8 {
                        ForEach(0..<pages.count, id: \.self) { dot in
                            Circle()
                                .fill(
                                    dot == index
                                        ? providerAccent(for: pages[dot].tool)
                                        : Color.primary.opacity(0.18)
                                )
                                .frame(width: 5, height: 5)
                                .contentShape(Circle().inset(by: -4))
                                .onTapGesture { pageIndex = dot }
                        }
                    } else {
                        Text("\(index + 1)/\(pages.count)")
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if pages.count > 1 {
                        Button {
                            pageIndex = (index + 1) % pages.count
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.vibeBar)
                        .help("Next provider")
                    }
                }
                .padding(.top, 3)
            }
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func otherBucketsLine(page: [MiniEntry], headline: MiniEntry, mode: DisplayMode) -> some View {
        let others = page.filter { $0.id != headline.id }.prefix(3)
        return HStack(spacing: 6) {
            ForEach(Array(others)) { entry in
                HStack(spacing: 2) {
                    Text(entry.rowLabel)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("\(Int(entryPercent(entry, mode: mode).rounded()))%")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(entryColor(entry, mode: mode))
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: 224)
        .padding(.top, 2)
    }

    private func resetLine(_ entry: MiniEntry, now: Date) -> String {
        guard let countdown = ResetCountdownFormatter.string(from: entry.bucket.resetAt, now: now) else {
            return " "
        }
        return "resets \(countdown)"
    }
}

// MARK: - Rail

/// The next seven days as the same refill lane the popover's Upcoming Resets
/// card draws: each selected bucket that refills inside the horizon is a slim
/// column standing on a time axis — height says how much comes back, colour
/// says how tight the bucket is right now — with the next few refills listed
/// underneath in full words.
enum MiniRailMetrics {
    static let size = CGSize(width: 584, height: 196)
    static let railWidth: CGFloat = 536
    static let horizonDays: Double = 7
    static let laneHeight: CGFloat = 64
    static let legendRows = 4
}

struct MiniRailLayout: View {
    let entries: [MiniEntry]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .frame(width: MiniRailMetrics.size.width, height: MiniRailMetrics.size.height)
    }

    /// The window's selected buckets as refill events, resolved labels and
    /// all. The tool raw value stands in for the account id — the mini layer
    /// folds accounts away, and the pair (tool, bucket) is unique here.
    private func events(now: Date) -> [UpcomingResetEvent] {
        entries.compactMap { entry -> UpcomingResetEvent? in
            guard let resetAt = entry.bucket.resetAt,
                  resetAt > now,
                  resetAt.timeIntervalSince(now) <= MiniRailMetrics.horizonDays * 86_400,
                  entry.bucket.usedPercent >= 1
            else { return nil }
            return UpcomingResetEvent(
                tool: entry.tool,
                accountId: entry.tool.rawValue,
                accountLabel: nil,
                subProviderName: entry.subProviderDisplayName,
                groupTitle: entry.groupLabel,
                bucketId: entry.bucket.id,
                bucketTitle: entry.customLabel ?? entry.bucket.title,
                remainingPercent: max(0, 100 - entry.bucket.usedPercent),
                gainPercent: entry.bucket.usedPercent,
                resetAt: resetAt
            )
        }
        .sorted { $0.resetAt < $1.resetAt }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let events = events(now: now)
        VStack(spacing: 4) {
            Text("QUOTA RESETS · NEXT \(Int(MiniRailMetrics.horizonDays)) DAYS")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.6)
                .padding(.top, 12)
            if events.isEmpty {
                Text("Nothing selected refills in the next seven days.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                ResetLaneView(
                    events: events,
                    now: now,
                    horizonDays: MiniRailMetrics.horizonDays,
                    laneHeight: MiniRailMetrics.laneHeight
                )
                .frame(width: MiniRailMetrics.railWidth)
                VStack(spacing: 0) {
                    ForEach(Array(events.prefix(MiniRailMetrics.legendRows))) { event in
                        legendRow(event, now: now)
                    }
                }
                .frame(width: MiniRailMetrics.railWidth)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private func legendRow(_ event: UpcomingResetEvent, now: Date) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.providerAccent(for: event.tool))
                .frame(width: 5, height: 5)
            Text(event.label)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Text("+\(Int(event.gainPercent.rounded()))%")
                .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.barColor(percent: event.remainingPercent, mode: .remaining))
            Text(ResetCountdownFormatter.string(from: event.resetAt, now: now) ?? "—")
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 17)
        .help(event.label)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
