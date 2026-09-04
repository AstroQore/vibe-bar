import SwiftUI
import VibeBarCore

/// Share of the selected range by **harness** — the CLI or app the usage came
/// from, not the company that bills it and not the quota SubProvider. Codex
/// and ChatGPT Work are one company and two harnesses; Claude Code and Claude
/// Cowork spend the same quota from two different places. Token composition
/// deliberately lives in the hero card so this remains one focused companion
/// to the trend.
struct UsageCompositionCards: View {
    let density: Theme.Density
    let summary: UsageSummaryMetrics
    let harnesses: [UsageHarnessStat]

    private var harnessRows: [UsageHarnessStat] {
        harnesses
            .filter { $0.totalTokens > 0 }
            .sorted { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.harness.displayName < rhs.harness.displayName
            }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        CardShell(density: density, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.Usage.harnessMixTitle)
                    .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                Spacer(minLength: 6)
                Text(L10n.Usage.harnessMixByRealTokens)
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
            }

            if harnessRows.isEmpty {
                Text(L10n.Usage.harnessMixEmpty)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                ForEach(harnessRows) { row in
                    harnessRow(row)
                }
                Spacer(minLength: 0)
                Divider().opacity(0.45)
                HStack {
                    Text(L10n.Usage.harnessMixActiveCount(count: harnessRows.count))
                    Spacer(minLength: 8)
                    Text(L10n.Usage.requestCount(count: summary.requests.formatted(.number.grouping(.automatic).locale(AppLocale.current))))
                }
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func harnessRow(_ row: UsageHarnessStat) -> some View {
        let total = max(1, summary.realTotalTokens)
        let fraction = min(1, max(0, Double(row.totalTokens) / Double(total)))
        // Badge and tint follow the L1 company, so two harnesses of one brand
        // still read as that brand while staying separate rows.
        let company = row.harness.company
        let tint = Theme.providerAccent(for: company)
        return VStack(spacing: 5) {
            HStack(spacing: 7) {
                CompanyBrandBadge(tool: company, iconSize: 12, containerSize: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.harness.displayName)
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    Text(row.harness.companyName)
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))
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
