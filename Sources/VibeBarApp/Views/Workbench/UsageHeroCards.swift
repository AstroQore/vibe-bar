import SwiftUI
import VibeBarCore

/// The six headline figures — sessions, tokens, cost, cache reads, active
/// time and projects, each with the one detail that explains it — over the
/// token composition bar the previous page's hero carried (fresh input,
/// output, cache write, cache read) and the request count.
///
/// Every figure but the session ones is `UsageEventLedger.summary` for the
/// same filter; `UsageDashboardReconciliationTests` holds them equal.
struct UsageHeroCards: View, Equatable {
    let density: Theme.Density
    let hero: UsageDashboardSnapshot.Hero

    var body: some View {
        CardShell(density: density, spacing: 14) {
            // One row: the Workbench is never narrower than six tiles need,
            // and a `ViewThatFits` would measure both layouts on every update.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    if index > 0 {
                        Divider().frame(maxHeight: 64).padding(.horizontal, 12)
                    }
                    tileView(tile)
                        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                }
            }
            if hero.tokens.total > 0 {
                composition
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composition: some View {
        let tokens = hero.tokens
        let parts: [(String, Int64, Color)] = [
            (L10n.Usage.Tokens.input, tokens.input, UsageTokenPalette.input),
            (L10n.Usage.Tokens.output, tokens.output, UsageTokenPalette.output),
            (L10n.Usage.Tokens.cacheWrite, tokens.cacheWrite, UsageTokenPalette.cacheWrite),
            (L10n.Usage.Tokens.cacheRead, tokens.cacheRead, UsageTokenPalette.cacheRead),
        ]
        let total = max(1, tokens.total)
        return VStack(alignment: .leading, spacing: 7) {
            UsageSegmentedBar(
                parts: parts.map { UsageSegmentedBar.Part(value: Double($0.1), tint: $0.2) },
                scale: Double(total),
                height: 7
            )
            .accessibilityLabel(L10n.Usage.Hero.tokenComposition)
            HStack(spacing: 14) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(part.2)
                            .frame(width: 7, height: 7)
                        Text(part.0).foregroundStyle(.secondary)
                        Text(UsageDashboardFormat.tokens(part.1)).fontWeight(.semibold)
                    }
                }
                Spacer(minLength: 8)
                Text(L10n.Usage.requestCount(count: AppLocale.number(hero.requests)))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5, design: .rounded).monospacedDigit())
            .lineLimit(1)
        }
    }

    private struct Tile {
        let title: String
        let value: String
        let detail: String
        var badge: String?
        let systemImage: String
        let tint: Color
    }

    private var tiles: [Tile] {
        let tokens = hero.tokens
        return [
            Tile(
                title: L10n.Workbench.Page.Sessions.title,
                value: AppLocale.number(hero.sessions),
                detail: hero.medianSessionTokens.map { median in
                    L10n.Workbench.Usage.Hero.sessionsDetail(
                        median: UsageDashboardFormat.tokens(median),
                        p90: UsageDashboardFormat.tokens(hero.p90SessionTokens ?? median)
                    )
                } ?? L10n.Common.noData,
                systemImage: "bubble.left.and.text.bubble.right",
                tint: Color(red: 20 / 255, green: 169 / 255, blue: 124 / 255)
            ),
            Tile(
                title: L10n.Usage.Tokens.title,
                value: UsageDashboardFormat.tokens(tokens.total),
                detail: L10n.Workbench.Usage.Hero.tokensDetail(
                    input: UsageDashboardFormat.tokens(tokens.prompt),
                    output: UsageDashboardFormat.tokens(tokens.output)
                ),
                systemImage: "sum",
                tint: WorkbenchPorcelain.accent
            ),
            Tile(
                title: L10n.Cost.title,
                value: hero.costMicros.map { UsageFormatting.compactUSD($0) + (hero.hasUnpricedUsage ? "+" : "") } ?? "—",
                detail: hero.hasUnpricedUsage ? L10n.Workbench.Usage.Hero.costUnpriced : L10n.Workbench.Usage.Hero.costDetail,
                systemImage: "dollarsign.circle",
                tint: .orange
            ),
            Tile(
                title: L10n.Usage.Tokens.cacheRead,
                value: UsageDashboardFormat.tokens(tokens.cacheRead),
                detail: L10n.Workbench.Usage.Hero.cacheDetail(rate: UsageDashboardFormat.percent(tokens.cacheHitRate)),
                systemImage: "arrow.triangle.2.circlepath",
                tint: .purple
            ),
            Tile(
                title: L10n.Workbench.Usage.Hero.activeTime,
                value: L10n.Common.Duration.hours(hours: hero.activeHours),
                detail: L10n.Workbench.Usage.Hero.activeDetail(count: hero.activeDays),
                systemImage: "clock",
                tint: .teal
            ),
            Tile(
                title: L10n.Usage.Breakdown.projects,
                value: AppLocale.number(hero.projectCount),
                detail: hero.topProjectName.map { name in
                    L10n.Workbench.Usage.Hero.projectsDetail(name: name, share: UsageDashboardFormat.percent(hero.topProjectShare))
                } ?? L10n.Common.noData,
                systemImage: "folder",
                tint: .pink
            ),
        ]
    }

    private func tileView(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: tile.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tile.tint)
                Text(tile.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(tile.value)
                .font(.system(size: density.titleFontSize + 8, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tile.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(tile.detail)
        }
        .accessibilityElement(children: .combine)
    }
}
