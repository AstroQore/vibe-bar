import Charts
import SwiftUI
import VibeBarCore

/// The Workbench's visual distribution wall. Unlike the compact Overview
/// switcher, every dimension is visible at once so comparisons do not require
/// changing tabs or losing the selected range/filter context.
struct UsageDistributionDashboard: View {
    let density: Theme.Density
    let summary: UsageSummaryMetrics
    let harnesses: [UsageHarnessStat]
    let providers: [UsageProviderStat]
    let models: [UsageModelStat]
    let projects: [UsageProjectStat]

    fileprivate struct Slice: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let tokens: Int64
        let costMicros: Int64?
        let color: Color
    }

    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.78, blue: 0.74),
        Color(red: 0.55, green: 0.40, blue: 0.92),
        Color(red: 0.96, green: 0.62, blue: 0.20),
        Color(red: 0.93, green: 0.40, blue: 0.40),
        Color(red: 0.34, green: 0.62, blue: 0.96),
        Color(red: 0.26, green: 0.74, blue: 0.55),
        Color(red: 0.58, green: 0.55, blue: 0.71),
    ]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: density.interSectionSpacing, alignment: .top)],
            alignment: .leading,
            spacing: density.interSectionSpacing
        ) {
            DistributionDonutCard(
                density: density,
                title: L10n.Usage.mixTokenFlowTitle,
                subtitle: L10n.Usage.mixTokenFlowSubtitle,
                emptyMessage: L10n.Usage.mixTokenFlowEmpty,
                slices: collapsed(flowSlices)
            )
            DistributionDonutCard(
                density: density,
                title: L10n.Usage.mixHarnessTitle,
                subtitle: L10n.Usage.mixHarnessSubtitle,
                emptyMessage: L10n.Usage.harnessMixEmpty,
                slices: collapsed(harnessSlices)
            )
            DistributionDonutCard(
                density: density,
                title: L10n.Usage.mixProviderTitle,
                subtitle: L10n.Usage.mixProviderSubtitle,
                emptyMessage: L10n.Usage.mixProviderEmpty,
                slices: collapsed(providerSlices)
            )
            DistributionDonutCard(
                density: density,
                title: L10n.Usage.mixProjectTitle,
                subtitle: L10n.Usage.mixProjectSubtitle,
                emptyMessage: L10n.Usage.mixProjectEmpty,
                slices: collapsed(projectSlices)
            )
            DistributionDonutCard(
                density: density,
                title: L10n.Usage.mixModelTitle,
                subtitle: L10n.Usage.mixModelSubtitle,
                emptyMessage: L10n.Usage.mixModelEmpty,
                slices: collapsed(modelSlices)
            )
        }
    }

    private var flowSlices: [Slice] {
        [
            Slice(id: "fresh", label: L10n.Usage.tokensInput, detail: nil,
                  tokens: summary.freshInput, costMicros: nil,
                  color: Self.palette[0]),
            Slice(id: "cache-read", label: L10n.Usage.tokensCacheRead, detail: nil,
                  tokens: summary.cacheRead, costMicros: nil,
                  color: Self.palette[1]),
            Slice(id: "cache-write", label: L10n.Usage.tokensCacheWrite, detail: nil,
                  tokens: summary.cacheCreation, costMicros: nil,
                  color: Self.palette[4]),
            Slice(id: "output", label: L10n.Usage.tokensOutput, detail: nil,
                  tokens: summary.output, costMicros: nil,
                  color: Self.palette[2]),
        ].filter { $0.tokens > 0 }
    }

    private var harnessSlices: [Slice] {
        harnesses.filter { $0.totalTokens > 0 }.map { row in
            Slice(
                id: row.harness.rawValue,
                label: row.harness.displayName,
                detail: row.harness.companyName,
                tokens: row.totalTokens,
                costMicros: row.costMicros,
                color: categoryColor(row.harness.rawValue)
            )
        }
    }

    private var providerSlices: [Slice] {
        providers.filter { $0.totalTokens > 0 }.map { row in
            Slice(
                id: row.tool.rawValue,
                label: row.tool.vendorName,
                detail: nil,
                tokens: row.totalTokens,
                costMicros: row.costMicros,
                color: Theme.providerAccent(for: row.tool)
            )
        }
    }

    private var projectSlices: [Slice] {
        projects.filter { $0.totalTokens > 0 }.map { row in
            Slice(
                id: row.path,
                label: row.name,
                detail: row.path,
                tokens: row.totalTokens,
                costMicros: row.costMicros,
                color: categoryColor(row.path)
            )
        }
    }

    private var modelSlices: [Slice] {
        models.filter { $0.totalTokens > 0 }.map { row in
            Slice(
                id: row.model,
                label: UsageModelNaming.canonicalDisplayName(row.model),
                detail: row.model,
                tokens: row.totalTokens,
                costMicros: row.costMicros,
                color: categoryColor(row.model)
            )
        }
    }

    private func collapsed(_ rows: [Slice], visible: Int = 5) -> [Slice] {
        let sorted = rows.sorted { $0.tokens > $1.tokens }
        guard sorted.count > visible else { return sorted }
        let tail = sorted.dropFirst(visible)
        return Array(sorted.prefix(visible)) + [
            Slice(
                id: "other:\(sorted.first?.id ?? "empty")",
                label: L10n.Usage.mixOther,
                detail: L10n.Usage.mixOtherCount(count: tail.count),
                tokens: tail.reduce(0) { $0 + $1.tokens },
                costMicros: tail.compactMap(\.costMicros).reduce(0, +),
                color: Color.secondary.opacity(0.55)
            )
        ]
    }

    private func categoryColor(_ key: String) -> Color {
        let index = key.utf8.reduce(0) { partial, byte in
            (partial &* 31 &+ Int(byte)) % Self.palette.count
        }
        return Self.palette[index]
    }
}

private struct DistributionDonutCard: View {
    let density: Theme.Density
    let title: String
    let subtitle: String
    let emptyMessage: String
    let slices: [UsageDistributionDashboard.Slice]

    var body: some View {
        CardShell(density: density, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text(subtitle)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
            if slices.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 145)
            } else {
                HStack(spacing: 14) {
                    donut
                        .frame(width: 128, height: 148)
                    legend
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Greedy tail: when the grid proposes the row's shared height,
                // the card surface stretches to it instead of floating shorter
                // than its neighbours.
                Spacer(minLength: 0)
            }
        }
    }

    /// Floor for the trailing value column. Shared by every card so "19.38B"
    /// in one card and "53% $11.6k" in the next start at the same x.
    private static let valueColumnWidth: CGFloat = 62

    private var total: Int64 { max(1, slices.reduce(0) { $0 + $1.tokens }) }

    private var donut: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Tokens", Double(slice.tokens)),
                innerRadius: .ratio(0.60),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(slice.color)
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
                        Text(L10n.Usage.mixDonutUnit)
                            .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                            .foregroundStyle(.tertiary)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(slices) { slice in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(slice.color).frame(width: 7, height: 7)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.label)
                            .font(.system(size: density.subtitleFontSize, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // Always laid out, blank when a dimension has no
                        // detail, so every row is the same two-line height and
                        // the five cards share one legend rhythm.
                        Text(slice.detail ?? " ")
                            .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(slice.detail == nil ? 0 : 1)
                            .accessibilityHidden(slice.detail == nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(slice.detail ?? slice.label)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(UsageFormatting.compactTokens(slice.tokens))
                            .font(.system(size: density.resetCountdownFontSize, weight: .semibold,
                                          design: .rounded).monospacedDigit())
                        HStack(spacing: 4) {
                            Text(
                                Double(slice.tokens) / Double(total),
                                format: .percent.precision(.fractionLength(0))
                                    .locale(AppLocale.current)
                            )
                            if let cost = slice.costMicros {
                                Text(UsageFormatting.compactUSD(cost))
                            }
                        }
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1),
                                      design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                    // The values never wrap or compress — the label column is
                    // the one that truncates. Without this the layout engine
                    // squeezed "$4803.98" onto two lines while the label kept
                    // its width.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: Self.valueColumnWidth, alignment: .trailing)
                }
            }
        }
    }
}
