import SwiftUI
import VibeBarCore

/// The "Used by product" line under a quota row: a thin segmented bar whose
/// full width is what the pool has used, and a legend of whole-number
/// shares. Its own line, not segments on the quota bar above it — that bar
/// already carries the display direction (used or remaining), the time-pace
/// mark and the forecast projection, and colour bands would fight all
/// three. Always in used terms: a share has no remaining value.
struct QuotaShareBreakdownView: View {
    let breakdown: QuotaShareBreakdown
    let accent: Color
    let fontSize: CGFloat

    /// Step down from the provider's accent, heaviest product darkest.
    private static let opacities: [Double] = [1, 0.78, 0.6, 0.47, 0.37, 0.3, 0.24, 0.2]

    private func color(at index: Int) -> Color {
        accent.opacity(Self.opacities[min(index, Self.opacities.count - 1)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.Quota.UsedByProduct.title)
                .font(.system(size: max(9, fontSize - 1), weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.4)
            GeometryReader { proxy in
                let gaps = CGFloat(max(0, breakdown.rows.count - 1)) * 2
                let width = max(0, proxy.size.width - gaps)
                HStack(spacing: 2) {
                    ForEach(Array(breakdown.rows.enumerated()), id: \.element.label) { index, row in
                        Rectangle()
                            .fill(color(at: index))
                            .frame(width: max(2, width * CGFloat(row.fraction)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            FlowLegend(spacing: 12, lineSpacing: 3) {
                ForEach(Array(breakdown.rows.enumerated()), id: \.element.label) { index, row in
                    HStack(spacing: 4) {
                        Circle().fill(color(at: index)).frame(width: 6, height: 6)
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Text(row.isBelowOnePoint
                             ? L10n.Quota.UsedByProduct.belowOne
                             : L10n.Common.percent(value: row.points))
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    .font(.system(size: fontSize))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Wraps its children onto as many lines as the width needs.
private struct FlowLegend: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
