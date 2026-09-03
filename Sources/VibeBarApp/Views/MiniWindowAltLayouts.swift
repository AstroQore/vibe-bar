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

    /// The bucket-level name: a custom label renames exactly this level.
    var bucketDisplayName: String {
        if let customLabel, !customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customLabel
        }
        return QuotaGroupLabelLocalizer.display(bucket.title)
    }

    /// Row label for list-style layouts: always the quota-axis path, with a
    /// custom label renaming the bucket level only — "All · Weekly" stays
    /// "All · <custom>" rather than collapsing to the custom text. Years of
    /// stored field labels literally say "Weekly"; letting them swallow the
    /// group made every row identical.
    var rowLabel: String {
        if let groupLabel {
            return "\(QuotaGroupLabelLocalizer.display(groupLabel)) · \(bucketDisplayName)"
        }
        return bucketDisplayName
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

    /// Consecutive entries of one SubProvider run sharing an L3 group label,
    /// in entry order — the level list layouts print as a subheader.
    static func groupRuns(_ run: [MiniEntry]) -> [(label: String?, entries: [MiniEntry])] {
        var runs: [(label: String?, entries: [MiniEntry])] = []
        for entry in run {
            if let last = runs.last, last.label == entry.groupLabel {
                runs[runs.count - 1].entries.append(entry)
            } else {
                runs.append((entry.groupLabel, [entry]))
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
        Text(L10n.Quota.miniNoLiveData)
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
    static let width: CGFloat = 284
    static let horizontalPadding: CGFloat = 14
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let companyHeaderHeight: CGFloat = 16
    static let subHeaderHeight: CGFloat = 15
    static let headerGap: CGFloat = 3
    static let groupHeaderHeight: CGFloat = 14
    static let rowHeight: CGFloat = 21
    static let companyGap: CGFloat = 8
    static let emptyHeight: CGFloat = 84
    /// Tier indents: the SubProvider header steps in under its company, and
    /// group headers plus bucket rows share one deeper step — a header must
    /// never sit further right than its own children, and rows keeping one
    /// indent keeps every bar starting at the same x.
    static let subIndent: CGFloat = 10
    static let rowIndent: CGFloat = 20
    static let rowLabelWidth: CGFloat = 76

    static func size(entries: [MiniEntry]) -> CGSize {
        guard !entries.isEmpty else { return CGSize(width: width, height: emptyHeight) }
        var height = topPadding + bottomPadding
        for (index, company) in MiniEntry.companyRuns(entries).enumerated() {
            if index > 0 { height += companyGap }
            height += companyHeaderHeight
            for run in MiniEntry.subProviderRuns(company) {
                height += subHeaderHeight + headerGap + CGFloat(run.count) * rowHeight
                for group in MiniEntry.groupRuns(run) where group.label != nil {
                    height += groupHeaderHeight
                }
            }
        }
        return CGSize(width: width, height: height)
    }
}

struct MiniLedgerLayout: View {
    let entries: [MiniEntry]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        // One clock for the layout, on the app-wide phase anchor: a moving
        // `.now` anchor re-phased the tick on every body pass, so no two
        // surfaces ever asked `QuotaService.paceForecast` the same question.
        StableClock(interval: 30) { tickDate in
            content(now: tickDate)
        }
        .frame(width: MiniLedgerMetrics.width)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if entries.isEmpty {
            MiniEmptyHint()
                .frame(height: MiniLedgerMetrics.emptyHeight)
        } else {
            let companies = MiniEntry.companyRuns(entries)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(companies.enumerated()), id: \.offset) { index, company in
                    if index > 0 {
                        Spacer().frame(height: MiniLedgerMetrics.companyGap)
                    }
                    companyHeader(for: company[0])
                    ForEach(Array(MiniEntry.subProviderRuns(company).enumerated()), id: \.offset) { _, run in
                        subProviderHeader(for: run[0])
                        Spacer().frame(height: MiniLedgerMetrics.headerGap)
                        ForEach(Array(MiniEntry.groupRuns(run).enumerated()), id: \.offset) { _, group in
                            if let label = group.label {
                                groupHeader(label)
                            }
                            ForEach(group.entries) { entry in
                                row(entry, now: now)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, MiniLedgerMetrics.horizontalPadding)
            .padding(.top, MiniLedgerMetrics.topPadding)
            .padding(.bottom, MiniLedgerMetrics.bottomPadding)
        }
    }

    /// L1: the company alone. The SubProvider gets its own tier below —
    /// "SPACEXAI · CURSOR" one-liners jammed two levels into one header.
    private func companyHeader(for entry: MiniEntry) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(providerAccent(for: entry.tool))
                .frame(width: 5, height: 5)
            Text(entry.companyName.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.82))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(height: MiniLedgerMetrics.companyHeaderHeight, alignment: .bottomLeading)
    }

    private func subProviderHeader(for entry: MiniEntry) -> some View {
        Text(entry.subProviderDisplayName.uppercased())
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .tracking(0.8)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.leading, MiniLedgerMetrics.subIndent)
            .frame(height: MiniLedgerMetrics.subHeaderHeight, alignment: .bottomLeading)
    }

    private func groupHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .tracking(0.9)
            .lineLimit(1)
            .padding(.leading, MiniLedgerMetrics.rowIndent)
            .frame(height: MiniLedgerMetrics.groupHeaderHeight, alignment: .bottomLeading)
    }

    private func row(_ entry: MiniEntry, now: Date) -> some View {
        let mode = settingsStore.displayMode
        let percent = entryPercent(entry, mode: mode)
        let color = entryColor(entry, mode: mode)
        return HStack(spacing: 8) {
            Text(entry.bucketDisplayName)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: MiniLedgerMetrics.rowLabelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, percent / 100))))
                }
            }
            .frame(height: 4)
            Text(L10n.Common.percent(value: Int(percent.rounded())))
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
        .padding(.leading, MiniLedgerMetrics.rowIndent)
        .frame(height: MiniLedgerMetrics.rowHeight)
        .help(miniEntryHelp(entry))
    }
}

// MARK: - Strip

/// A menu-bar-style HUD, one cell per selected bucket; past `maxRowWidth`
/// it wraps into further bands. Three densities, chosen per window: roomy,
/// two-line (menu bar's paired columns), narrow (compact size).
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
    /// The strip never outgrows the screen: past this width it wraps into
    /// further bands at full cell width — cells shrunk to stay on one line
    /// went unreadable first.
    static let maxRowWidth: CGFloat = 1180

    /// How many ideal-width cells fit one band.
    static func cellsPerBand(count: Int, ideal: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let available = maxRowWidth - leadingPadding - trailingPadding
        return max(1, min(count, Int((available + spacing) / (ideal + spacing))))
    }

    static func size(entries: [MiniEntry], density: MiniStripDensity) -> CGSize {
        guard !entries.isEmpty else { return CGSize(width: emptyWidth, height: rowHeight(density)) }
        let cellCount = density == .twoLine ? (entries.count + 1) / 2 : entries.count
        let cellSpacing = density == .twoLine ? pairedColumnSpacing : chipSpacing(density)
        let cellWidth = chipWidth(density)
        let perBand = cellsPerBand(count: cellCount, ideal: cellWidth, spacing: cellSpacing)
        let bands = (cellCount + perBand - 1) / perBand
        let width = leadingPadding + trailingPadding
            + CGFloat(perBand) * cellWidth
            + CGFloat(max(0, perBand - 1)) * cellSpacing
        let height = CGFloat(bands) * rowHeight(density)
            + CGFloat(max(0, bands - 1)) * rowGap
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
                let cellWidth = MiniStripMetrics.chipWidth(density)
                let perBand = MiniStripMetrics.cellsPerBand(
                    count: entries.count,
                    ideal: cellWidth,
                    spacing: MiniStripMetrics.chipSpacing(density)
                )
                VStack(alignment: .leading, spacing: MiniStripMetrics.rowGap) {
                    ForEach(Array(entries.chunked(into: perBand).enumerated()), id: \.offset) { _, band in
                        HStack(spacing: MiniStripMetrics.chipSpacing(density)) {
                            ForEach(band) { entry in
                                lineCell(entry, width: cellWidth)
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
        let perBand = MiniStripMetrics.cellsPerBand(
            count: pairs.count,
            ideal: MiniStripMetrics.pairedColumnWidth,
            spacing: MiniStripMetrics.pairedColumnSpacing
        )
        return VStack(alignment: .leading, spacing: MiniStripMetrics.rowGap) {
            ForEach(Array(pairs.chunked(into: perBand).enumerated()), id: \.offset) { _, band in
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
            Text(L10n.Common.percent(value: Int(percent.rounded())))
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .help(
            L10n.Quota.miniRowHelp(
                subProvider: entry.subProviderDisplayName,
                row: entry.rowLabel,
                percent: Int(percent.rounded())
            )
        )
    }

    /// The menu bar's single-line style, one cell per bucket: full label
    /// beside its colored number. Narrow is the compact variant — the same
    /// pieces at the menu bar's small size.
    private func lineCell(_ entry: MiniEntry, width: CGFloat) -> some View {
        let mode = settingsStore.displayMode
        let percent = entryPercent(entry, mode: mode)
        let color = entryColor(entry, mode: mode)
        let size = MiniStripMetrics.cellFontSize(density)
        return HStack(spacing: 5) {
            Text(entry.rowLabel)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(L10n.Common.percent(value: Int(percent.rounded())))
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(width: width, alignment: .leading)
        .help(
            L10n.Quota.miniRowHelp(
                subProvider: entry.subProviderDisplayName,
                row: entry.rowLabel,
                percent: Int(percent.rounded())
            )
        )
    }
}

// MARK: - Tiles

/// A fixed grid, one tile per bucket: provenance caption (company +
/// SubProvider), the bucket path, big number, thin bar, and a severity
/// stripe on the leading edge.
enum MiniTileMetrics {
    static let tileWidth: CGFloat = 120
    static let tileHeight: CGFloat = 62
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
                VStack(alignment: .leading, spacing: 2) {
                    // Both parent tiers in one caption, two-tone so the
                    // levels still read apart: company faint, SubProvider
                    // stronger — a bare "All · Weekly" said nothing about
                    // whose quota the tile was.
                    HStack(spacing: 4) {
                        Circle()
                            .fill(providerAccent(for: entry.tool))
                            .frame(width: 5, height: 5)
                        (Text(entry.companyName.uppercased())
                            .foregroundStyle(.tertiary)
                         + Text("  ")
                         + Text(entry.subProviderDisplayName.uppercased())
                            .foregroundStyle(.secondary))
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                    Text(entry.rowLabel)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        Text(L10n.Common.percent(value: Int(percent.rounded())))
                            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
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
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
            }
            .padding(.leading, 4)
        }
        .frame(width: MiniTileMetrics.tileWidth, height: MiniTileMetrics.tileHeight)
        .help(miniTileHelp(entry))
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
        StableClock(interval: 30) { tickDate in
            content(now: tickDate)
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
                Text(miniFocusPath(headline))
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
                    Text(L10n.Common.percent(value: Int(percent.rounded())))
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
                        Text(
                            L10n.Quota.miniPageIndicator(
                                index: index + 1, total: pages.count
                            )
                        )
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
                        .help(L10n.Quota.miniNextProvider)
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
                    Text(
                        L10n.Common.percent(
                            value: Int(entryPercent(entry, mode: mode).rounded())
                        )
                    )
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
        return L10n.Quota.miniResets(countdown: countdown)
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
        StableClock(interval: 60) { tickDate in
            content(now: tickDate)
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
            Text(L10n.Quota.miniRailTitle(days: Int(MiniRailMetrics.horizonDays)))
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(1.6)
                .padding(.top, 12)
            if events.isEmpty {
                Text(L10n.Quota.miniRailEmpty)
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
            Text(L10n.Quota.upcomingGain(gain: Int(event.gainPercent.rounded())))
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

/// Provider · group · bucket for a mini entry's tooltip, with the generic
/// window words translated and every name left as its owner spells it.
private func miniEntryHelp(_ entry: MiniEntry) -> String {
    let group = QuotaGroupLabelLocalizer.display(
        entry.bucket.groupTitle ?? entry.subProviderDisplayName
    )
    let title = QuotaGroupLabelLocalizer.display(entry.bucket.title)
    return "\(providerTitle(for: entry.tool)) · \(group) · \(title)"
}

/// Provider · row · bucket for a tile's tooltip. A named helper rather than an
/// interpolation at the call site: the join happens once, and every part that
/// can be a generic window word goes through the localizer on the way.
private func miniTileHelp(_ entry: MiniEntry) -> String {
    let title = QuotaGroupLabelLocalizer.display(entry.bucket.title)
    return "\(providerTitle(for: entry.tool)) · \(entry.rowLabel) · \(title)"
}

/// SubProvider · row, upper-cased, for the focus layout's path line. The
/// case change is applied to the resolved labels, never to a catalog key.
private func miniFocusPath(_ entry: MiniEntry) -> String {
    "\(entry.subProviderDisplayName.uppercased()) · \(entry.rowLabel.uppercased())"
}
