import SwiftUI
import VibeBarCore

/// Two compact explanations of the selected range: where traffic came from
/// and what kind of tokens moved. Both are projections of the same filtered
/// ledger query as the headline cards and chart, so they cannot drift into a
/// second usage definition.
struct UsageCompositionCards: View {
    let density: Theme.Density
    let summary: UsageSummaryMetrics
    let providers: [UsageProviderStat]

    private var providerRows: [UsageProviderStat] {
        providers
            .filter { $0.totalTokens > 0 }
            .sorted { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens {
                    return lhs.totalTokens > rhs.totalTokens
                }
                return lhs.tool.rawValue < rhs.tool.rawValue
            }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: density.interSectionSpacing) {
            providerMix
            tokenFlow
        }
    }

    private var providerMix: some View {
        CardShell(density: density, spacing: 8) {
            sectionTitle("PROVIDER MIX", detail: "by real tokens")
            if providerRows.isEmpty {
                emptyLine("No provider traffic in this range")
            } else {
                ForEach(providerRows) { row in
                    providerRow(row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func providerRow(_ row: UsageProviderStat) -> some View {
        let total = max(1, summary.realTotalTokens)
        let fraction = min(1, max(0, Double(row.totalTokens) / Double(total)))
        let tint = Theme.providerAccent(for: row.tool)
        return VStack(spacing: 4) {
            HStack(spacing: 7) {
                ToolBrandBadge(tool: row.tool, iconSize: 12, containerSize: 18)
                Text(row.tool.displayName)
                    .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                Text(UsageFormatting.compactTokens(row.totalTokens))
                    .frame(minWidth: 50, alignment: .trailing)
            }
            .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded)
                .monospacedDigit())
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.barTrack)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: max(5, density.bucketBarHeight - 5))
            .accessibilityHidden(true)
        }
    }

    private var tokenFlow: some View {
        CardShell(density: density, spacing: 10) {
            sectionTitle("TOKEN FLOW", detail: "input, output & cache")
            compositionBar
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 8
            ) {
                legend("Fresh input", value: summary.freshInput, tint: .blue)
                legend("Output", value: summary.output, tint: .purple)
                legend("Cache read", value: summary.cacheRead, tint: .green)
                legend("Cache write", value: summary.cacheCreation, tint: .orange)
            }
            Divider().opacity(0.3)
            HStack(spacing: 8) {
                Label("Cache hit", systemImage: "bolt.fill")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(UsageFormatting.formatPercent(summary.cacheHitRate))
                    .fontWeight(.semibold)
                if summary.unpricedRequests > 0 {
                    Text("\(summary.unpricedRequests) unpriced")
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1), weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.13)))
                }
            }
            .font(.system(size: density.subtitleFontSize, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var compositionBar: some View {
        GeometryReader { geometry in
            let total = max(1, summary.realTotalTokens)
            HStack(spacing: 2) {
                segment(summary.freshInput, total: total, tint: .blue, width: geometry.size.width)
                segment(summary.output, total: total, tint: .purple, width: geometry.size.width)
                segment(summary.cacheRead, total: total, tint: .green, width: geometry.size.width)
                segment(summary.cacheCreation, total: total, tint: .orange, width: geometry.size.width)
            }
            .clipShape(Capsule())
            .background(Capsule().fill(Theme.barTrack))
        }
        .frame(height: max(10, density.bucketBarHeight))
        .accessibilityLabel("Token composition")
    }

    private func segment(_ value: Int64, total: Int64, tint: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(tint.gradient)
            .frame(width: value > 0 ? width * Double(value) / Double(total) : 0)
    }

    private func legend(_ label: String, value: Int64, tint: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: max(9, density.resetCountdownFontSize)))
                    .foregroundStyle(.secondary)
                Text(UsageFormatting.compactTokens(value))
                    .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded)
                        .monospacedDigit())
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: density.subtitleFontSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}
