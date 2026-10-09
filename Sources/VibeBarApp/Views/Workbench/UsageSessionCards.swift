import SwiftUI
import VibeBarCore

/// What the heaviest-sessions card ranks by.
enum UsageSessionSort: String, CaseIterable, Identifiable {
    case tokens
    case cost
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: L10n.Usage.Tokens.title
        case .cost: L10n.Cost.title
        case .active: L10n.Workbench.Usage.Trend.Metric.active
        }
    }
}

/// The heaviest sessions in the range by tokens, cost or active time. A row
/// opens the session on the Sessions page.
struct UsageTopSessionsCard: View, Equatable {
    let density: Theme.Density
    let top: UsageDashboardSnapshot.TopSessions
    let onOpen: (SessionSummary) -> Void

    @State private var sort: UsageSessionSort = .tokens

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.density == rhs.density && lhs.top == rhs.top
    }

    private var rows: [UsageDashboardSnapshot.SessionRow] {
        switch sort {
        case .tokens: top.byTokens
        case .cost: top.byCost
        case .active: top.byActive
        }
    }

    var body: some View {
        CardShell(density: density, spacing: 10) {
            UsageCardHeader(density: density, title: L10n.Workbench.Usage.TopSessions.title) {
                UsagePillPicker(
                    options: UsageSessionSort.allCases,
                    title: \.title,
                    selection: $sort,
                    accessibilityLabel: L10n.Workbench.Usage.TopSessions.title
                )
            }
            if rows.isEmpty {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Session.empty, systemImage: "bubble.left.and.text.bubble.right")
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        UsageSessionRowView(density: density, row: row, rank: index + 1, value: value(row), onOpen: onOpen)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func value(_ row: UsageDashboardSnapshot.SessionRow) -> String {
        switch sort {
        case .tokens: row.tokens.map { UsageDashboardFormat.tokens($0.total) } ?? "—"
        case .cost: UsageDashboardFormat.cost(row.costMicros) + (row.costIsPartial ? "+" : "")
        case .active: (row.activeSeconds ?? row.durationSeconds).map(UsageDashboardFormat.duration(seconds:)) ?? "—"
        }
    }
}

/// One session: harness mark, title, then project · harness · model · when,
/// and a value on the right. Clicking opens it on the Sessions page.
struct UsageSessionRowView: View {
    let density: Theme.Density
    let row: UsageDashboardSnapshot.SessionRow
    var rank: Int?
    let value: String
    var detail: String?
    let onOpen: (SessionSummary) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button {
            onOpen(row.summary)
        } label: {
            HStack(spacing: 10) {
                if let rank {
                    Text(AppLocale.number(rank))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)
                }
                HarnessBrandBadge(harness: row.harness, iconSize: 13, containerSize: 20, brandColored: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title ?? L10n.Workbench.Usage.Session.untitled)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    meta
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .help(sourceHelp)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? WorkbenchPorcelain.hoverFill(for: colorScheme) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.vibeBar(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .help(L10n.Workbench.Usage.Session.openHelp)
    }

    /// Which source the row's tokens and cost come from — one per harness,
    /// see `UsageDashboardSnapshot.SessionRow.TokenSource`.
    private var sourceHelp: String {
        switch row.tokenSource {
        case .ledger: L10n.Workbench.Usage.Session.sourceLedger
        case .sessionLog: L10n.Workbench.Usage.Session.sourceLog
        case .none: L10n.Workbench.Usage.Session.noTokens
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if let project = row.projectName {
                Label(project, systemImage: "folder")
                    .labelStyle(UsageCompactLabelStyle())
                separator
            }
            Text(row.harness.displayName)
            if let model = row.model {
                separator
                Text(UsageDashboardFormat.modelName(model))
                    .help(model)
            }
            separator
            Text(UsageDashboardFormat.relative(row.lastActiveAt))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

struct UsageCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5))
            configuration.title
        }
    }
}

/// Sessions active in the range, newest first, with a search box that
/// filters by title, project, harness and model.
struct UsageRecentSessionsCard: View, Equatable {
    let density: Theme.Density
    let sessions: [UsageDashboardSnapshot.SessionRow]
    let totalInRange: Int
    let onOpen: (SessionSummary) -> Void

    @State private var query = ""
    @State private var limit = 12
    /// The search result, recomputed when the query or the list changes —
    /// never in `body`.
    @State private var matches: [UsageDashboardSnapshot.SessionRow] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.density == rhs.density && lhs.sessions == rhs.sessions && lhs.totalInRange == rhs.totalInRange
    }

    private func refilter() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            matches = sessions
            return
        }
        matches = sessions.filter { row in
            [row.title, row.projectName, row.model, row.harness.displayName, row.summary.sessionID]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        CardShell(density: density, spacing: 10) {
            UsageCardHeader(density: density, title: L10n.Workbench.Usage.Recent.title) {
                searchField
            }
            if sessions.isEmpty {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Session.empty, systemImage: "bubble.left.and.text.bubble.right")
            } else if matches.isEmpty {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Recent.noMatch(query: query), systemImage: "magnifyingglass")
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(matches.prefix(limit)) { row in
                        UsageSessionRowView(
                            density: density,
                            row: row,
                            value: UsageDashboardFormat.cost(row.costMicros) + (row.costIsPartial ? "+" : ""),
                            detail: tokenDetail(row),
                            onOpen: onOpen
                        )
                    }
                }
                HStack {
                    Text(L10n.Workbench.Usage.Recent.showing(
                        shown: AppLocale.number(min(limit, matches.count)),
                        total: AppLocale.number(query.isEmpty ? max(totalInRange, matches.count) : matches.count)
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    Spacer()
                    if matches.count > limit {
                        Button {
                            limit += 24
                        } label: {
                            Text(L10n.Usage.Table.loadMore(remaining: matches.count - limit))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(WorkbenchPillButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { refilter() }
        .onChange(of: sessions) { _, _ in refilter() }
        .onChange(of: query) { _, _ in
            limit = 12
            refilter()
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(L10n.Workbench.Sessions.Search.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .frame(width: 180)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .workbenchFieldSurface(cornerRadius: 8)
    }

    private func tokenDetail(_ row: UsageDashboardSnapshot.SessionRow) -> String {
        guard let tokens = row.tokens else { return L10n.Workbench.Usage.Session.noTokens }
        return L10n.Workbench.Usage.Recent.tokens(
            input: UsageDashboardFormat.tokens(tokens.input),
            output: UsageDashboardFormat.tokens(tokens.output),
            cache: UsageDashboardFormat.tokens(tokens.cacheRead + tokens.cacheWrite)
        )
    }
}

/// How sessions are distributed by messages, duration or tool calls.
struct UsageSessionShapeCard: View, Equatable {
    enum Metric: String, CaseIterable, Identifiable {
        case messages
        case duration
        case toolCalls

        var id: String { rawValue }

        var title: String {
            switch self {
            case .messages: L10n.Workbench.Usage.Trend.Metric.messages
            case .duration: L10n.Workbench.Usage.Shape.Metric.duration
            case .toolCalls: L10n.Workbench.Usage.Shape.Metric.toolCalls
            }
        }
    }

    let density: Theme.Density
    let shape: UsageDashboardSnapshot.SessionShape

    @State private var metric: Metric = .messages

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.density == rhs.density && lhs.shape == rhs.shape
    }

    private var histogram: UsageDashboardSnapshot.Histogram {
        switch metric {
        case .messages: shape.messages
        case .duration: shape.duration
        case .toolCalls: shape.toolCalls
        }
    }

    var body: some View {
        CardShell(density: density, spacing: 12) {
            UsageCardHeader(density: density, title: L10n.Workbench.Usage.Shape.title) {
                UsagePillPicker(
                    options: Metric.allCases,
                    title: \.title,
                    selection: $metric,
                    accessibilityLabel: L10n.Workbench.Usage.Shape.title
                )
            }
            let histogram = self.histogram
            if histogram.sampleCount == 0 {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Session.empty, systemImage: "chart.bar")
            } else {
                bars(histogram)
                    .frame(height: 118)
                HStack {
                    if let median = histogram.median {
                        Text(L10n.Workbench.Usage.Shape.median(value: format(Int(median.rounded()))))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L10n.Workbench.Usage.Shape.samples(count: histogram.sampleCount))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            // Greedy tail: beside a taller card the surface stretches to the
            // row's height instead of stopping short of its neighbour.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bars(_ histogram: UsageDashboardSnapshot.Histogram) -> some View {
        let maximum = max(1, histogram.maximum)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(histogram.bins) { bin in
                VStack(spacing: 4) {
                    Text(AppLocale.number(bin.count))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(bin.count > 0 ? .secondary : .tertiary)
                    UsageFractionShape(
                        fraction: bin.count > 0 ? Double(bin.count) / Double(maximum) : 0.02,
                        vertical: true
                    )
                    .fill(WorkbenchPorcelain.accent.opacity(bin.count > 0 ? 0.75 : 0.12))
                    Text(label(bin))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .help(L10n.Workbench.Usage.Shape.bin(range: label(bin), count: bin.count))
            }
        }
    }

    private func format(_ value: Int) -> String {
        metric == .duration ? UsageDashboardFormat.duration(seconds: value) : AppLocale.number(value)
    }

    private func label(_ bin: UsageDashboardSnapshot.Histogram.Bin) -> String {
        if metric == .duration {
            if bin.lower == 0, let upper = bin.upper {
                return L10n.Workbench.Usage.Shape.under(value: format(upper + 1))
            }
            guard let upper = bin.upper else { return L10n.Workbench.Usage.Shape.atLeast(value: format(bin.lower)) }
            return L10n.Workbench.Usage.Shape.range(from: format(bin.lower), to: format(upper + 1))
        }
        guard let upper = bin.upper else { return L10n.Workbench.Usage.Shape.atLeast(value: format(bin.lower)) }
        return upper == bin.lower
            ? format(bin.lower)
            : L10n.Workbench.Usage.Shape.range(from: format(bin.lower), to: format(upper))
    }
}
