import SwiftUI
import VibeBarCore

/// The top six projects or models by tokens, each a share bar with its
/// tokens and cost, then one line for everything past them.
///
/// `Equatable` with only value inputs, so a snapshot that leaves this
/// ranking unchanged does not re-lay it out.
struct UsageRankingCard: View, Equatable {
    enum Kind: Equatable {
        case projects
        case models
    }

    let density: Theme.Density
    let kind: Kind
    let ranking: UsageDashboardSnapshot.Ranking

    private var title: String {
        kind == .projects ? L10n.Usage.Breakdown.projects : L10n.Usage.Breakdown.models
    }

    private var tint: Color {
        kind == .projects ? WorkbenchPorcelain.accent : .teal
    }

    var body: some View {
        CardShell(density: density, spacing: 12) {
            UsageCardHeader(density: density, title: title) {
                if ranking.totalTokens > 0 {
                    Text(UsageDashboardFormat.tokens(ranking.totalTokens))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if ranking.rows.isEmpty {
                UsageEmptyMessage(
                    density: density,
                    text: kind == .projects
                        ? L10n.Workbench.Usage.Ranking.emptyProjects
                        : L10n.Workbench.Usage.Ranking.emptyModels,
                    systemImage: kind == .projects ? "folder" : "cpu"
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ranking.rows) { row in
                        rankingRow(row)
                    }
                }
                if ranking.remainderCount > 0 {
                    Text(L10n.Workbench.Usage.Ranking.more(
                        count: ranking.remainderCount,
                        tokens: UsageDashboardFormat.tokens(ranking.remainderTokens)
                    ))
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

    private func rankingRow(_ row: UsageDashboardSnapshot.RankingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: kind == .projects ? "folder" : "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(row.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.id)
                Spacer(minLength: 8)
                Text(UsageDashboardFormat.tokens(row.tokens))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                Text(UsageDashboardFormat.cost(row.costMicros))
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 50, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 14, height: 1)
                UsageShareBar(fraction: row.share, tint: tint.opacity(0.85), height: 5)
                Text(UsageDashboardFormat.percent(row.share))
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
