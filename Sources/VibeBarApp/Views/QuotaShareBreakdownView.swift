import SwiftUI
import VibeBarCore

/// Colours for the products a quota pool is split by.
///
/// The forecast already owns blue (Surplus), green (Enough), orange (Watch)
/// and red (At risk), and the Used-mode fill is teal, so products draw from
/// the one family left — violet to magenta — and two neutrals. A colour
/// follows its product, never its rank: Claude Code and Grok Build share the
/// first slot because they never appear in the same pool.
enum QuotaShareColors {
    private static let slots: [(light: Color, dark: Color)] = [
        (Color(red: 0.357, green: 0.294, blue: 0.769), Color(red: 0.553, green: 0.498, blue: 0.941)),  // violet
        (Color(red: 0.769, green: 0.345, blue: 0.624), Color(red: 0.847, green: 0.447, blue: 0.714)),  // magenta
        (Color(red: 0.557, green: 0.494, blue: 0.878), Color(red: 0.663, green: 0.612, blue: 0.941)),  // light violet
        (Color(red: 0.871, green: 0.549, blue: 0.741), Color(red: 0.914, green: 0.639, blue: 0.804)),  // pink
        (Color(red: 0.239, green: 0.247, blue: 0.322), Color(red: 0.816, green: 0.824, blue: 0.863)),  // graphite
        (Color(red: 0.541, green: 0.553, blue: 0.612), Color(red: 0.604, green: 0.616, blue: 0.675)),  // slate
        (Color(red: 0.725, green: 0.737, blue: 0.776), Color(red: 0.431, green: 0.443, blue: 0.502))   // light gray
    ]

    /// Fixed slots by product name, across providers.
    private static let slotByLabel: [String: Int] = [
        "claude code": 0, "grok build": 0,
        "cowork": 1, "grok bot": 1,
        "chats": 2, "api": 2,
        "imagine": 3,
        "chat": 4,
        "voice": 5,
        "cursor": 6, "other": 6
    ]

    /// One colour per row, in the breakdown's order. A product without a
    /// fixed slot takes the first slot no other row in this pool uses.
    static func colors(for rows: [QuotaShareBreakdown.Row], scheme: ColorScheme) -> [Color] {
        var used = Set(rows.compactMap { slotByLabel[$0.label.lowercased()] })
        return rows.map { row in
            let slot: Int
            if let fixed = slotByLabel[row.label.lowercased()] {
                slot = fixed
            } else {
                slot = (0..<slots.count).first { !used.contains($0) } ?? slots.count - 1
                used.insert(slot)
            }
            return scheme == .dark ? slots[slot].dark : slots[slot].light
        }
    }
}

/// The product layer drawn inside a quota bar in Remaining mode: the empty
/// part of the bar is exactly what has been used, so it is split by product,
/// heaviest at the far end, translucent. It sits in the bar's clipped group
/// right after the fill, under every forecast layer — the confidence band,
/// the time-pace tick and the median tick draw over it unchanged.
struct QuotaProductTrackLayer {
    let breakdown: QuotaShareBreakdown
    /// The bucket's used percent, 0…100: the span the products fill.
    let usedPercent: Double

    @ViewBuilder
    func body(width: CGFloat, height: CGFloat, scheme: ColorScheme) -> some View {
        let colors = QuotaShareColors.colors(for: breakdown.rows, scheme: scheme)
        let span = width * CGFloat(max(0, min(100, usedPercent))) / 100
        ZStack(alignment: .trailing) {
            HStack(spacing: 1) {
                ForEach(Array(breakdown.rows.enumerated().reversed()), id: \.element.label) { index, row in
                    Rectangle()
                        .fill(colors[index].opacity(0.5))
                        .frame(width: max(1, span * CGFloat(row.fraction) - 1))
                }
            }
            .frame(width: span, height: height, alignment: .trailing)
        }
        .frame(width: width, height: height, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// Used mode keeps the quota bar exactly as it is and puts the product split
/// in a thin strip right under the fill, the same length as the fill.
struct QuotaProductStrip: View {
    let breakdown: QuotaShareBreakdown
    let usedPercent: Double
    /// The bar's height: every bar draws its fill at least that wide, so the
    /// strip does too, or it would shrink to a few pixels under a full cap.
    let barHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = QuotaShareColors.colors(for: breakdown.rows, scheme: colorScheme)
        GeometryReader { proxy in
            let raw = proxy.size.width * CGFloat(max(0, min(100, usedPercent))) / 100
            let span = min(proxy.size.width, max(barHeight, raw))
            HStack(spacing: 1) {
                ForEach(Array(breakdown.rows.enumerated()), id: \.element.label) { index, row in
                    Rectangle()
                        .fill(colors[index])
                        .frame(width: max(1, span * CGFloat(row.fraction) - 1))
                }
            }
            .frame(width: span, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// The legend under the bar: one dot, name and whole-number share per
/// product, wrapping onto as many lines as the width needs.
struct QuotaShareLegend: View {
    let breakdown: QuotaShareBreakdown
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = QuotaShareColors.colors(for: breakdown.rows, scheme: colorScheme)
        FlowLegend(spacing: 12, lineSpacing: 3) {
            ForEach(Array(breakdown.rows.enumerated()), id: \.element.label) { index, row in
                HStack(spacing: 4) {
                    Circle().fill(colors[index]).frame(width: 6, height: 6)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Quota.UsedByProduct.title)
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
