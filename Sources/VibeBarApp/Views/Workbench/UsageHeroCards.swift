import SwiftUI
import VibeBarCore

/// A single, range-scoped usage overview. Keeping the figures in one card
/// makes the relationship between token volume, spend, requests, and cache
/// effectiveness apparent before the reader moves into the charts below.
struct UsageHeroCards: View {
    let density: Theme.Density
    let summary: UsageSummaryMetrics

    var body: some View {
        CardShell(density: density, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                heroRow
                heroStack
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 0) {
            tokensSection
                .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(2)
                .padding(.trailing, density.cardPadding)
            heroDivider
            metricSection(label: L10n.Usage.heroTotalCost, value: costValue) {
                if summary.unpricedRequests > 0 {
                    unpricedBadge
                } else {
                    detailText(summary.costMicros == nil ? L10n.Usage.heroNoPricedRequests : L10n.Usage.heroAllRequestsPriced)
                }
            }
            .frame(minWidth: 145, idealWidth: 185, maxWidth: 220, alignment: .leading)
            .padding(.horizontal, density.cardPadding)
            heroDivider
            metricSection(label: L10n.Usage.heroRequests, value: summary.requests.formatted(.number.grouping(.automatic))) {
                detailText(summary.requests == 0 ? L10n.Usage.heroNoTrafficInRange : L10n.Usage.heroInSelectedRange)
            }
            .frame(minWidth: 130, idealWidth: 170, maxWidth: 195, alignment: .leading)
            .padding(.horizontal, density.cardPadding)
            heroDivider
            cacheSection
                .frame(minWidth: 190, idealWidth: 230, maxWidth: 270, alignment: .leading)
                .padding(.leading, density.cardPadding)
        }
    }

    private var heroStack: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            tokensSection
            HStack(alignment: .top, spacing: density.cardSpacing) {
                metricSection(label: L10n.Usage.heroTotalCost, value: costValue) {
                    if summary.unpricedRequests > 0 { unpricedBadge }
                    else { detailText(summary.costMicros == nil ? L10n.Usage.heroNoPricedRequests : L10n.Usage.heroAllRequestsPriced) }
                }
                Divider().frame(height: 54)
                metricSection(label: L10n.Usage.heroRequests, value: summary.requests.formatted(.number.grouping(.automatic))) {
                    detailText(summary.requests == 0 ? L10n.Usage.heroNoTrafficInRange : L10n.Usage.heroInSelectedRange)
                }
                Divider().frame(height: 54)
                cacheSection
            }
        }
    }

    private var tokensSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("REAL TOKENS · SELECTED RANGE")
            Text(UsageFormatting.compactTokens(summary.realTotalTokens))
                .font(.system(size: density.titleFontSize + 20, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            tokenLegend
            tokenCompositionBar
        }
    }

    private var tokenLegend: some View {
        HStack(spacing: 12) {
            tokenLegendItem("In", value: summary.freshInput, tint: .blue)
            tokenLegendItem("Out", value: summary.output, tint: .green)
            tokenLegendItem("Cache write", value: summary.cacheCreation, tint: .orange)
            tokenLegendItem("Cache read", value: summary.cacheRead, tint: .purple)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tokenCompositionBar: some View {
        GeometryReader { geometry in
            let total = max(1, summary.realTotalTokens)
            HStack(spacing: 1) {
                tokenSegment(summary.freshInput, total: total, tint: .blue, width: geometry.size.width)
                tokenSegment(summary.output, total: total, tint: .green, width: geometry.size.width)
                tokenSegment(summary.cacheCreation, total: total, tint: .orange, width: geometry.size.width)
                tokenSegment(summary.cacheRead, total: total, tint: .purple, width: geometry.size.width)
            }
            .clipShape(Capsule())
            .background(Capsule().fill(Theme.barTrack))
        }
        .frame(height: max(8, density.bucketBarHeight - 1))
        .accessibilityLabel(L10n.Usage.heroTokenComposition)
    }

    private func tokenSegment(_ value: Int64, total: Int64, tint: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(tint.gradient)
            .frame(width: value > 0 ? width * Double(value) / Double(total) : 0)
    }

    private func tokenLegendItem(_ label: String, value: Int64, tint: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.secondary)
            Text(UsageFormatting.compactTokens(value))
                .fontWeight(.semibold)
        }
        .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded).monospacedDigit())
        .lineLimit(1)
    }

    @ViewBuilder
    private func metricSection(
        label: String,
        value: String,
        @ViewBuilder detail: @escaping () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)
            Text(value)
                .font(.system(size: density.titleFontSize + 2, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            detail()
        }
    }

    private var cacheSection: some View {
        HStack(spacing: 11) {
            cacheRing
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel("CACHE HIT")
                Text(UsageFormatting.formatPercent(summary.cacheHitRate))
                    .font(.system(size: density.titleFontSize, weight: .bold, design: .rounded).monospacedDigit())
                detailText("\(UsageFormatting.compactTokens(summary.cacheRead)) read")
            }
        }
    }

    private var cacheRing: some View {
        let rate = max(0, min(1, summary.cacheHitRate ?? 0))
        return ZStack {
            Circle().stroke(Theme.barTrack, lineWidth: 5)
            Circle()
                .trim(from: 0, to: rate)
                .stroke(cacheTint(rate), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 54, height: 54)
        .accessibilityHidden(true)
    }

    private var heroDivider: some View {
        Divider().frame(maxHeight: 112)
    }

    private var costValue: String {
        guard let micros = summary.costMicros else { return "—" }
        return UsageFormatting.formatMicroUSD(micros)
    }

    private var unpricedBadge: some View {
        Text(L10n.Usage.heroUnpricedBadge(count: summary.unpricedRequests))
            .font(.system(size: max(8, density.resetCountdownFontSize - 2), weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.13)))
            .help(L10n.Usage.heroUnpricedHelp(count: summary.unpricedRequests))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.7)
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func cacheTint(_ rate: Double) -> Color {
        guard summary.cacheHitRate != nil else { return .secondary.opacity(0.4) }
        if rate >= 0.6 { return .green }
        if rate >= 0.3 { return .teal }
        return .orange
    }
}
