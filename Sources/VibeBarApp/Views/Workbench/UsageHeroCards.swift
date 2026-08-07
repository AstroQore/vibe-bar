import SwiftUI
import VibeBarCore

/// The four headline numbers of the Usage Stats page.
///
/// One tile per metric on its own `CardShell` in an adaptive grid, so the
/// row degrades to 2×2 and then to a column as the window narrows instead of
/// squeezing four values into an unreadable strip.
struct UsageHeroCards: View {
    let density: Theme.Density
    let summary: UsageSummaryMetrics

    private static let tileMinimum: CGFloat = 210

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: Self.tileMinimum),
                    spacing: density.interSectionSpacing,
                    alignment: .topLeading
                )
            ],
            spacing: density.interSectionSpacing
        ) {
            tokensTile
            costTile
            requestsTile
            cacheTile
        }
    }

    // MARK: - Tiles

    private var tokensTile: some View {
        tile(label: "REAL TOKENS", value: UsageFormatting.compactTokens(summary.realTotalTokens)) {
            Text(componentLine)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var costTile: some View {
        tile(label: "TOTAL COST", value: costValue) {
            if summary.unpricedRequests > 0 {
                badge(
                    text: "unpriced \(summary.unpricedRequests)",
                    tint: .orange,
                    help: "\(summary.unpricedRequests) request(s) had no usable price and contribute $0."
                )
            } else {
                Text(summary.costMicros == nil ? "no priced requests in range" : "all requests priced")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var requestsTile: some View {
        tile(label: "REQUESTS", value: summary.requests.formatted(.number.grouping(.automatic))) {
            Text(summary.requests == 0 ? "no traffic in range" : "in the selected range")
                .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var cacheTile: some View {
        tile(label: "CACHE HIT RATE", value: UsageFormatting.formatPercent(summary.cacheHitRate)) {
            cacheBar
        }
    }

    // MARK: - Pieces

    /// Slim capsule track. Read as reassurance rather than as a warning: a
    /// high hit rate is the good outcome, so the fill greens up as it grows.
    private var cacheBar: some View {
        let rate = summary.cacheHitRate ?? 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.barTrack)
                Capsule()
                    .fill(cacheTint(rate))
                    .frame(width: max(0, min(1, rate)) * geometry.size.width)
            }
        }
        .frame(height: max(4, density.bucketBarHeight - 6))
        .accessibilityHidden(true)
    }

    private func cacheTint(_ rate: Double) -> Color {
        if summary.cacheHitRate == nil { return Color.secondary.opacity(0.4) }
        if rate >= 0.6 { return .green }
        if rate >= 0.3 { return .teal }
        return .orange
    }

    private var costValue: String {
        guard let micros = summary.costMicros else { return "—" }
        return UsageFormatting.formatMicroUSD(micros)
    }

    private var componentLine: String {
        "In \(UsageFormatting.compactTokens(summary.freshInput))"
            + " · Out \(UsageFormatting.compactTokens(summary.output))"
            + " · CacheW \(UsageFormatting.compactTokens(summary.cacheCreation))"
            + " · CacheR \(UsageFormatting.compactTokens(summary.cacheRead))"
    }

    private func badge(text: String, tint: Color, help: String) -> some View {
        Text(text)
            .font(.system(size: max(8, density.resetCountdownFontSize - 2), weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .help(help)
    }

    @ViewBuilder
    private func tile(
        label: String,
        value: String,
        @ViewBuilder detail: @escaping () -> some View
    ) -> some View {
        CardShell(density: density, spacing: 6) {
            Text(label)
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.system(
                    size: density.titleFontSize + 8,
                    weight: .bold,
                    design: .rounded
                ).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            detail()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
