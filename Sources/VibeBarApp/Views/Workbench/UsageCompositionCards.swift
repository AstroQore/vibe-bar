import SwiftUI
import VibeBarCore

/// Provider share for the selected ledger range. Token composition deliberately
/// lives in the hero card so this remains one focused companion to the trend.
struct UsageCompositionCards: View {
    let density: Theme.Density
    let summary: UsageSummaryMetrics
    let providers: [UsageProviderStat]

    private var providerRows: [UsageProviderStat] {
        providers
            .filter { $0.totalTokens > 0 }
            .sorted { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.tool.rawValue < rhs.tool.rawValue
            }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        CardShell(density: density, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PROVIDER MIX")
                    .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                Spacer(minLength: 6)
                Text("by real tokens")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
            }

            if providerRows.isEmpty {
                Text("No provider traffic in this range")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                ForEach(providerRows) { row in
                    providerRow(row)
                }
                Spacer(minLength: 0)
                Divider().opacity(0.45)
                HStack {
                    Text("\(providerRows.count) provider\(providerRows.count == 1 ? "" : "s") active in range")
                    Spacer(minLength: 8)
                    Text("\(summary.requests.formatted(.number.grouping(.automatic))) requests")
                }
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func providerRow(_ row: UsageProviderStat) -> some View {
        let total = max(1, summary.realTotalTokens)
        let fraction = min(1, max(0, Double(row.totalTokens) / Double(total)))
        let tint = Theme.providerAccent(for: row.tool)
        return VStack(spacing: 5) {
            HStack(spacing: 7) {
                ToolBrandBadge(tool: row.tool, iconSize: 12, containerSize: 19)
                Text(row.tool.displayName)
                    .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                Text(UsageFormatting.compactTokens(row.totalTokens))
                    .fontWeight(.semibold)
                    .frame(minWidth: 54, alignment: .trailing)
            }
            .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded).monospacedDigit())
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
}
