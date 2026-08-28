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
    let subProviderName: String
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
            let isGrouped = MiniQuotaWindowView.hasQuotaGroup(bucket, tool: field.tool, bucketId: field.bucketId)
            var groupLabel: String?
            if isGrouped {
                let key = MiniWindowGroupLabelCatalog.groupKey(tool: field.tool, bucketId: field.bucketId)
                groupLabel = settings.resolvedGroupLabel(config: config, key: key)
                    ?? MiniWindowGroupLabelCatalog.defaultLabel(for: key)
                    ?? bucket.groupTitle
            }
            let subProviderKey = MiniWindowGroupLabelCatalog.subProviderKey(tool: field.tool, name: subProviderName)
            return MiniEntry(
                tool: field.tool,
                field: field,
                bucket: bucket,
                subProviderName: settings.resolvedGroupLabel(config: config, key: subProviderKey) ?? subProviderName,
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

private func shortCompany(_ tool: ToolType) -> String {
    switch tool {
    case .codex:       return "GPT"
    case .claude:      return "CLD"
    case .gemini:      return "GEM"
    case .antigravity: return "AG"
    case .grok:        return "GRK"
    case .cursor:      return "CUR"
    default:           return providerTitle(for: tool)
    }
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
            Text("\(entry.companyName.uppercased()) · \(entry.subProviderName.uppercased())")
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
        .help("\(providerTitle(for: entry.tool)) · \(entry.bucket.groupTitle ?? entry.subProviderName) · \(entry.bucket.title)")
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

    static func chipWidth(_ density: MiniStripDensity) -> CGFloat {
        switch density {
        case .roomy:   return 104
        case .twoLine: return 62
        case .narrow:  return 40
        }
    }

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

    static func height(_ density: MiniStripDensity) -> CGFloat {
        switch density {
        case .roomy:   return 44
        case .twoLine: return 54
        case .narrow:  return 40
        }
    }

    static func size(entries: [MiniEntry], density: MiniStripDensity) -> CGSize {
        guard !entries.isEmpty else { return CGSize(width: emptyWidth, height: height(density)) }
        let companies = MiniEntry.companyRuns(entries)
        var width = leadingPadding + trailingPadding
        for (index, company) in companies.enumerated() {
            if index > 0 { width += 2 * companySpacing(density) + dividerThickness }
            let chips = MiniEntry.subProviderRuns(company).count
            width += CGFloat(chips) * chipWidth(density)
                + CGFloat(max(0, chips - 1)) * chipSpacing(density)
        }
        return CGSize(width: width, height: height(density))
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
            } else {
                let companies = MiniEntry.companyRuns(entries)
                HStack(spacing: 0) {
                    ForEach(Array(companies.enumerated()), id: \.offset) { index, company in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: MiniStripMetrics.dividerThickness, height: 18)
                                .padding(.horizontal, MiniStripMetrics.companySpacing(density))
                        }
                        HStack(spacing: MiniStripMetrics.chipSpacing(density)) {
                            ForEach(Array(MiniEntry.subProviderRuns(company).enumerated()), id: \.offset) { _, run in
                                chip(for: run)
                            }
                        }
                    }
                }
                .padding(.leading, MiniStripMetrics.leadingPadding)
                .padding(.trailing, MiniStripMetrics.trailingPadding)
            }
        }
        .frame(height: MiniStripMetrics.height(density))
    }

    /// The chip shows the run's most critical bucket — least remaining wins.
    @ViewBuilder
    private func chip(for run: [MiniEntry]) -> some View {
        let mode = settingsStore.displayMode
        let worst = run.min { remainingPercent($0) < remainingPercent($1) } ?? run[0]
        let percent = entryPercent(worst, mode: mode)
        let color = entryColor(worst, mode: mode)
        Group {
            switch density {
            case .roomy:
                HStack(spacing: 5) {
                    brandDot(worst)
                    number(percent, color: color, size: 13)
                    Text(worst.rowLabel)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: MiniStripMetrics.chipWidth(density), alignment: .leading)
            case .twoLine:
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        brandDot(worst)
                        number(percent, color: color, size: 13)
                    }
                    Text(worst.rowLabel)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: MiniStripMetrics.chipWidth(density))
            case .narrow:
                HStack(spacing: 4) {
                    brandDot(worst)
                    number(percent, color: color, size: 12)
                }
                .frame(width: MiniStripMetrics.chipWidth(density), alignment: .leading)
            }
        }
        .help(helpText(for: run))
    }

    private func brandDot(_ entry: MiniEntry) -> some View {
        Circle()
            .fill(providerAccent(for: entry.tool))
            .frame(width: 6, height: 6)
    }

    private func number(_ percent: Double, color: Color, size: CGFloat) -> some View {
        Text("\(Int(percent.rounded()))")
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
    }

    private func helpText(for run: [MiniEntry]) -> String {
        let mode = settingsStore.displayMode
        let lines = run.map { entry in
            "\(entry.rowLabel): \(Int(entryPercent(entry, mode: mode).rounded()))%"
        }
        return "\(run[0].subProviderName) — \(lines.joined(separator: " · "))"
    }
}

// MARK: - Tiles

/// A fixed grid, one tile per bucket: big number, thin bar, and a severity
/// stripe on the leading edge.
enum MiniTileMetrics {
    static let tileWidth: CGFloat = 92
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
                    HStack(spacing: 3) {
                        Text(shortCompany(entry.tool))
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                            .foregroundStyle(providerAccent(for: entry.tool))
                        Text(entry.rowLabel)
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
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
        let pages = MiniEntry.companyGroups(entries)
        if pages.isEmpty {
            MiniEmptyHint()
        } else {
            let index = min(pageIndex, pages.count - 1)
            let page = pages[index]
            let mode = settingsStore.displayMode
            // The headline is the page's most critical bucket, so the big
            // number is always the one that needs attention.
            let headline = page.min { remainingPercent($0) < remainingPercent($1) } ?? page[0]
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
                    Text(page[0].companyName.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.86))
                }
                Text("\(headline.subProviderName.uppercased()) · \(headline.rowLabel.uppercased())")
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
                    ForEach(0..<pages.count, id: \.self) { dot in
                        Circle()
                            .fill(
                                dot == index
                                    ? providerAccent(for: pages[dot][0].tool)
                                    : Color.primary.opacity(0.18)
                            )
                            .frame(width: 5, height: 5)
                            .contentShape(Circle().inset(by: -4))
                            .onTapGesture { pageIndex = dot }
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

/// The next seven days as a horizontal timeline: every bucket sits at its
/// reset time, so "what refills next" is the leftmost thing on screen.
enum MiniRailMetrics {
    static let size = CGSize(width: 584, height: 184)
    static let railWidth: CGFloat = 520
    static let horizonDays: Double = 7
    static let ringSize: CGFloat = 28
    static let laneLift: CGFloat = 34
    /// Minimum x distance between two bubbles in the same lane; closer ones
    /// are pushed right into a staircase.
    static let crowdingThreshold: CGFloat = 46
}

struct MiniRailLayout: View {
    let entries: [MiniEntry]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniRailMetrics.size.width, height: MiniRailMetrics.size.height)
    }

    private struct Placed: Identifiable {
        let entry: MiniEntry
        let x: CGFloat
        let lane: Int
        var id: String { entry.id }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let placed = place(now: now)
        if placed.isEmpty {
            MiniEmptyHint()
        } else {
            let mode = settingsStore.displayMode
            let railWidth = MiniRailMetrics.railWidth
            let axisY: CGFloat = 128
            VStack(spacing: 0) {
                Text("QUOTA RESETS · NEXT \(Int(MiniRailMetrics.horizonDays)) DAYS")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.6)
                    .padding(.top, 14)
                ZStack(alignment: .topLeading) {
                    // Axis + day ticks.
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: railWidth, height: 1)
                        .offset(y: axisY)
                    ForEach(0...Int(MiniRailMetrics.horizonDays), id: \.self) { day in
                        let x = railWidth * CGFloat(day) / MiniRailMetrics.horizonDays
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 1, height: 7)
                            .offset(x: x, y: axisY - 6)
                        Text(day == 0 ? "now" : "+\(day)d")
                            .font(.system(size: 7.5, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 30)
                            .offset(x: x - 15, y: axisY + 5)
                    }
                    ForEach(placed) { item in
                        bubble(item, mode: mode, axisY: axisY)
                    }
                }
                .frame(width: railWidth, height: MiniRailMetrics.size.height - 32, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func bubble(_ item: Placed, mode: DisplayMode, axisY: CGFloat) -> some View {
        let percent = entryPercent(item.entry, mode: mode)
        let color = entryColor(item.entry, mode: mode)
        let ringTop: CGFloat = 22 + (item.lane == 1 ? MiniRailMetrics.laneLift : 0)
        let ring = MiniRailMetrics.ringSize
        return ZStack(alignment: .topLeading) {
            // Stem from ring bottom to axis.
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: max(0, axisY - ringTop - ring))
                .offset(x: item.x, y: ringTop + ring)
            RingGauge(
                percent: percent,
                expected: nil,
                color: color,
                size: ring,
                lineWidth: 3.5
            ) {
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
            }
            .offset(x: item.x - ring / 2, y: ringTop)
            Text(bubbleLabel(item.entry))
                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 60, alignment: .center)
                .offset(x: item.x - 30, y: ringTop - 11)
        }
        .help("\(providerTitle(for: item.entry.tool)) · \(item.entry.rowLabel) — resets \(item.entry.bucket.resetAt.map { ResetCountdownFormatter.string(from: $0, now: Date()) ?? "—" } ?? "—")")
    }

    private func bubbleLabel(_ entry: MiniEntry) -> String {
        "\(shortCompany(entry.tool)) \(entry.rowLabel)"
    }

    /// Sort by reset time, then de-clutter: alternate between the two lanes
    /// and push a bubble right until its lane has room, so a cluster of
    /// same-hour resets fans out into a readable staircase instead of a pile.
    private func place(now: Date) -> [Placed] {
        let horizon = MiniRailMetrics.horizonDays * 86_400
        let sorted = entries
            .compactMap { entry -> (MiniEntry, TimeInterval)? in
                guard let reset = entry.bucket.resetAt else { return nil }
                let interval = reset.timeIntervalSince(now)
                // Dropped, not clamped, outside the window: pinning a
                // monthly reset to the +7d tick would present it as due this
                // week.
                guard interval > -3_600, interval <= horizon else { return nil }
                return (entry, max(0, interval))
            }
            .sorted { $0.1 < $1.1 }
        var placed: [Placed] = []
        var lastXByLane: [CGFloat] = [-.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        for (index, item) in sorted.enumerated() {
            let (entry, interval) = item
            let fraction = min(1, interval / horizon)
            let rawX = MiniRailMetrics.railWidth * CGFloat(fraction)
            // Prefer the lane whose last bubble is farther left; break ties by
            // alternating so a dense cluster zig-zags.
            let lane: Int
            if lastXByLane[0] + MiniRailMetrics.crowdingThreshold <= rawX {
                lane = 0
            } else if lastXByLane[1] + MiniRailMetrics.crowdingThreshold <= rawX {
                lane = 1
            } else {
                lane = index % 2
            }
            let x = min(
                MiniRailMetrics.railWidth,
                max(rawX, lastXByLane[lane] + MiniRailMetrics.crowdingThreshold)
            )
            placed.append(Placed(entry: entry, x: x, lane: lane))
            lastXByLane[lane] = x
        }
        return placed
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
