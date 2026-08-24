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
            columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: density.interSectionSpacing)],
            alignment: .leading,
            spacing: density.interSectionSpacing
        ) {
            DistributionDonutCard(
                density: density,
                title: "Token Flow",
                subtitle: "input · cache · output",
                emptyMessage: "No token traffic in this range",
                slices: collapsed(flowSlices)
            )
            DistributionDonutCard(
                density: density,
                title: "Harness Mix",
                subtitle: "where requests ran",
                emptyMessage: "No harness traffic in this range",
                slices: collapsed(harnessSlices)
            )
            DistributionDonutCard(
                density: density,
                title: "Provider Mix",
                subtitle: "billing companies",
                emptyMessage: "No provider traffic in this range",
                slices: collapsed(providerSlices)
            )
            DistributionDonutCard(
                density: density,
                title: "Project Mix",
                subtitle: "Codex + Claude cwd · up to 30 d detail",
                emptyMessage: "Project attribution appears after a Codex or Claude rescan",
                slices: collapsed(projectSlices)
            )
            DistributionDonutCard(
                density: density,
                title: "Model Mix",
                subtitle: "canonical display names",
                emptyMessage: "No model traffic in this range",
                slices: collapsed(modelSlices)
            )
        }
    }

    private var flowSlices: [Slice] {
        [
            Slice(id: "fresh", label: "Fresh input", detail: nil,
                  tokens: summary.freshInput, costMicros: nil,
                  color: Self.palette[0]),
            Slice(id: "cache-read", label: "Cache read", detail: nil,
                  tokens: summary.cacheRead, costMicros: nil,
                  color: Self.palette[1]),
            Slice(id: "cache-write", label: "Cache creation", detail: nil,
                  tokens: summary.cacheCreation, costMicros: nil,
                  color: Self.palette[4]),
            Slice(id: "output", label: "Output", detail: nil,
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
                label: "Other",
                detail: "\(tail.count) more",
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
            }
        }
    }

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
                        Text("tokens")
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(slice.color).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.label)
                            .font(.system(size: density.subtitleFontSize, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = slice.detail {
                            Text(detail)
                                .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .help(slice.detail ?? slice.label)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(UsageFormatting.compactTokens(slice.tokens))
                            .font(.system(size: density.resetCountdownFontSize, weight: .semibold,
                                          design: .rounded).monospacedDigit())
                        HStack(spacing: 4) {
                            Text(Double(slice.tokens) / Double(total), format: .percent.precision(.fractionLength(0)))
                            if let cost = slice.costMicros {
                                Text(UsageFormatting.formatMicroUSD(cost))
                            }
                        }
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1),
                                      design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
