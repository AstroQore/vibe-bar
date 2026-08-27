import Charts
import SwiftUI
import VibeBarCore

/// A compact 30-day composition explorer for the main Overview.
///
/// CostSnapshot already powers the durable charts, while the request ledger
/// can answer the questions a total cannot: which harness, project, model, or
/// token class produced it. One card with an explicit dimension switch keeps
/// those four pies comparable without filling the Overview with four nearly
/// identical cards.
struct OverviewUsageMixCard: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var costService: CostUsageService
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var dimension: Dimension = .projects
    @State private var snapshot = Snapshot.empty
    @State private var isLoading = false
    @State private var loadFailed = false

    private enum Dimension: String, CaseIterable, Identifiable {
        case projects
        case harnesses
        case models
        case flow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: "Projects"
            case .harnesses: "Harnesses"
            case .models: "Models"
            case .flow: "Token Flow"
            }
        }
    }

    private struct Snapshot {
        let summary: UsageSummaryMetrics
        let harnesses: [UsageHarnessStat]
        let models: [UsageModelStat]
        let projects: [UsageProjectStat]

        static let empty = Snapshot(summary: .empty, harnesses: [], models: [], projects: [])
    }

    private struct Slice: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let tokens: Int64
        let costMicros: Int64
        let color: Color
    }

    private static let categoricalPalette: [Color] = [
        Color(red: 0.30, green: 0.78, blue: 0.74),
        Color(red: 0.55, green: 0.40, blue: 0.92),
        Color(red: 0.96, green: 0.62, blue: 0.20),
        Color(red: 0.93, green: 0.40, blue: 0.40),
        Color(red: 0.34, green: 0.62, blue: 0.96),
        Color(red: 0.58, green: 0.55, blue: 0.71),
    ]

    var body: some View {
        CardShell(density: density, spacing: 10) {
            header
            dimensionPicker
            content
        }
        .task(id: loadTaskID) {
            await load()
        }
    }

    private var visibleCostProviders: [ToolType] {
        ToolType.costAwareProviders.filter { settingsStore.settings.isCoreProviderVisible($0) }
    }

    private var loadTaskID: String {
        "\(costService.lastRefreshedAt?.timeIntervalSince1970 ?? 0)|"
            + visibleCostProviders.map(\.rawValue).joined(separator: ",")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Usage Mix")
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
            Spacer(minLength: 6)
            Text("Last 30 days")
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
            SectionRefreshButton(isRefreshing: costService.isRefreshing || isLoading) {
                environment.refreshCostUsage()
            }
        }
    }

    private var dimensionPicker: some View {
        HStack(spacing: 3) {
            ForEach(Dimension.allCases) { item in
                Button {
                    dimension = item
                } label: {
                    Text(item.title)
                        .font(.system(size: max(9, density.segmentedFontSize - 2), weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            Capsule().fill(
                                dimension == item
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.primary.opacity(0.035)
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                dimension == item
                                    ? Color.accentColor.opacity(0.45)
                                    : Color.primary.opacity(0.08),
                                lineWidth: 0.7
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = slices
        if isLoading, rows.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 164)
        } else if rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: loadFailed ? "chart.pie.fill" : "chart.pie")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 164)
        } else {
            HStack(alignment: .center, spacing: 12) {
                donut(rows)
                    .frame(width: 132, height: 150)
                legend(rows)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func donut(_ rows: [Slice]) -> some View {
        let total = rows.reduce(Int64(0)) { $0 + $1.tokens }
        return Chart(rows) { row in
            SectorMark(
                angle: .value("Tokens", Double(max(0, row.tokens))),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(row.color)
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let rect = geometry[frame]
                    VStack(spacing: 0) {
                        Text(UsageFormatting.compactTokens(total))
                            .font(.system(size: density.bucketTitleFontSize, weight: .bold,
                                          design: .rounded).monospacedDigit())
                        Text("tokens")
                            .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                            .foregroundStyle(.tertiary)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private func legend(_ rows: [Slice]) -> some View {
        let total = max(1, rows.reduce(Int64(0)) { $0 + $1.tokens })
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label)
                            .font(.system(size: density.subtitleFontSize, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .help(row.detail ?? row.label)
                    Spacer(minLength: 3)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(UsageFormatting.compactTokens(row.tokens))
                            .font(.system(size: density.resetCountdownFontSize, weight: .semibold,
                                          design: .rounded).monospacedDigit())
                        Text(Double(row.tokens) / Double(total), format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: max(8, density.resetCountdownFontSize - 1),
                                          design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    // Same rule as the Workbench distribution legend: the
                    // value column never compresses or wraps — the label is
                    // the side that truncates.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var slices: [Slice] {
        let raw: [Slice]
        switch dimension {
        case .projects:
            raw = snapshot.projects.map { row in
                Slice(
                    id: row.path,
                    label: row.name,
                    detail: row.path,
                    tokens: row.totalTokens,
                    costMicros: row.costMicros,
                    color: categoryColor(for: row.path)
                )
            }
        case .harnesses:
            raw = snapshot.harnesses.map { row in
                Slice(
                    id: row.harness.rawValue,
                    label: row.harness.displayName,
                    detail: row.harness.companyName,
                    tokens: row.totalTokens,
                    costMicros: row.costMicros,
                    color: Theme.providerAccent(for: row.harness.company)
                )
            }
        case .models:
            raw = snapshot.models.map { row in
                Slice(
                    id: row.model,
                    label: UsageModelNaming.canonicalDisplayName(row.model),
                    detail: row.model,
                    tokens: row.totalTokens,
                    costMicros: row.costMicros,
                    color: categoryColor(for: row.model)
                )
            }
        case .flow:
            let summary = snapshot.summary
            raw = [
                Slice(id: "fresh", label: "Fresh input", detail: nil,
                      tokens: summary.freshInput, costMicros: 0,
                      color: Color(red: 0.30, green: 0.78, blue: 0.74)),
                Slice(id: "cache", label: "Cache", detail: "read + creation",
                      tokens: summary.cacheRead + summary.cacheCreation, costMicros: 0,
                      color: Color(red: 0.55, green: 0.40, blue: 0.92)),
                Slice(id: "output", label: "Output", detail: nil,
                      tokens: summary.output, costMicros: 0,
                      color: Color(red: 0.96, green: 0.62, blue: 0.20)),
            ]
        }
        return collapsed(raw.filter { $0.tokens > 0 })
    }

    private func collapsed(_ rows: [Slice], visibleCount: Int = 5) -> [Slice] {
        let sorted = rows.sorted { $0.tokens > $1.tokens }
        guard sorted.count > visibleCount else { return sorted }
        let head = Array(sorted.prefix(visibleCount))
        let tail = sorted.dropFirst(visibleCount)
        let other = Slice(
            id: "other:\(dimension.rawValue)",
            label: "Other",
            detail: "\(tail.count) more",
            tokens: tail.reduce(Int64(0)) { $0 + $1.tokens },
            costMicros: tail.reduce(Int64(0)) { $0 + $1.costMicros },
            color: Color.secondary.opacity(0.55)
        )
        return head + [other]
    }

    private func categoryColor(for key: String) -> Color {
        let index = key.utf8.reduce(0) { partial, byte in
            (partial &* 31 &+ Int(byte)) % Self.categoricalPalette.count
        }
        return Self.categoricalPalette[index]
    }

    private var emptyMessage: String {
        if loadFailed { return "Usage ledger could not be read." }
        if dimension == .projects {
            return "Project attribution appears after the next Codex or Claude cost refresh."
        }
        return "No local usage in this range."
    }

    @MainActor
    private func load() async {
        guard let ledger = environment.usageLedger else {
            loadFailed = true
            return
        }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let start = Calendar.current.date(byAdding: .day, value: -29, to: startOfToday)
            ?? now.addingTimeInterval(-29 * 86_400)
        let filter = UsageQueryFilter(
            range: DateInterval(start: start, end: now.addingTimeInterval(1)),
            tools: visibleCostProviders
        )
        do {
            let summary = try await ledger.summary(filter)
            let harnesses = try await ledger.harnessStats(filter)
            let models = try await ledger.modelStats(filter)
            let projects = try await ledger.projectStats(filter)
            snapshot = Snapshot(
                summary: summary,
                harnesses: harnesses,
                models: models,
                projects: projects
            )
        } catch {
            loadFailed = true
        }
    }
}
