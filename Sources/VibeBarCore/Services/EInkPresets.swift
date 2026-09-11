import Foundation

/// The eight verified layouts, ported from the Dot. demo onto the box engine.
///
/// The port is deliberately literal — same strings, same font sizes, same
/// gaps, same column arrangements — with one systematic change: the demo let
/// Satori's flexbox overflow a full-capacity screen by a pixel or two, which
/// an absolutely positioned tree cannot hide. Every list here therefore sizes
/// its rows with `fittedRowHeight`, which keeps the demo's preferred height
/// whenever it fits and shrinks only as far as the 6 px safe margin requires.
public enum EInkPresets {
    static let margin = 6

    // MARK: - Fonts

    /// 12 px pixel font, the smallest legible type on the panel.
    static let pixel = EInkFont.pixel12(bold: false)
    static let pixelBold = EInkFont.pixel12(bold: true)
    /// Numbers: ChillDuanSans, bold, never below 13 px.
    static func sans(_ size: Int, bold: Bool = true) -> EInkFont { .sans(size: size, bold: bold) }

    // MARK: - Node helpers

    static func text(
        _ content: String,
        _ font: EInkFont = EInkPresets.pixel,
        width: EInkLength = .auto,
        height: EInkLength = .auto,
        align: EInkTextAlignment = .leading
    ) -> EInkNode {
        EInkNode(.text(content, font: font, alignment: align), width: width, height: height)
    }

    static func row(
        _ children: [EInkNode],
        width: EInkLength = .flex(1),
        height: EInkLength = .auto,
        gap: Int = 0,
        justify: EInkMainAlignment = .start,
        align: EInkCrossAlignment = .stretch,
        padding: EInkInsets = .zero
    ) -> EInkNode {
        EInkNode(.row, width: width, height: height, padding: padding, gap: gap, justify: justify, align: align, children: children)
    }

    static func column(
        _ children: [EInkNode],
        width: EInkLength = .flex(1),
        height: EInkLength = .auto,
        gap: Int = 0,
        justify: EInkMainAlignment = .start,
        align: EInkCrossAlignment = .stretch,
        padding: EInkInsets = .zero
    ) -> EInkNode {
        EInkNode(.column, width: width, height: height, padding: padding, gap: gap, justify: justify, align: align, children: children)
    }

    /// Fills the remaining vertical space in a column.
    static func verticalSpacer() -> EInkNode { EInkNode(.row, width: .flex(1), height: .flex(1)) }

    /// 1 px black rule across the parent's width.
    static func rule() -> EInkNode { EInkNode(.fill, width: .flex(1), height: .points(1)) }

    /// 1 px black rule down the parent's height.
    static func verticalRule() -> EInkNode { EInkNode(.fill, width: .points(1), height: .flex(1)) }

    static func horizontalBar(_ percent: Int, height: Int = 10, width: EInkLength = .flex(1)) -> EInkNode {
        EInkNode(.horizontalBar(percent: percent), width: width, height: .points(height))
    }

    static func verticalBar(_ percent: Int, width: Int, height: Int) -> EInkNode {
        EInkNode(.verticalBar(percent: percent), width: .points(width), height: .points(height))
    }

    static func ring(_ percent: Int, size: Int = 48, stroke: Int = 6, labelSize: Int = 14) -> EInkNode {
        EInkNode(
            .ring(percent: percent, stroke: stroke, labelFont: sans(labelSize)),
            width: .points(size),
            height: .points(size)
        )
    }

    /// The demo's `border-l border-black pl-[8px]`: a rule plus a gap, drawn
    /// explicitly because the encoder positions every box itself.
    static func leftRuled(_ node: EInkNode, gap: Int = 8) -> EInkNode {
        row([verticalRule(), node], width: .flex(1), height: .flex(1), gap: gap)
    }

    /// The demo's `border-t border-black`: a rule directly above, no gap.
    static func topRuled(_ node: EInkNode, paddingTop: Int = 0) -> EInkNode {
        column(
            [rule(), EInkNode(.column, width: .flex(1), height: .auto, padding: EInkInsets(top: paddingTop), children: [node])],
            width: .flex(1),
            height: .auto
        )
    }

    static func screen(_ children: [EInkNode], frame: EInkRect, gap: Int) -> EInkNode {
        column(
            children,
            width: .points(frame.width),
            height: .points(frame.height),
            gap: gap,
            padding: EInkInsets(all: margin)
        )
    }

    /// Keeps the demo's preferred row height until the panel runs out, then
    /// shrinks evenly rather than pushing the last row past the safe margin.
    static func fittedRowHeight(available: Int, count: Int, gap: Int, preferred: Int) -> Int {
        guard count > 0 else { return preferred }
        let usable = available - gap * (count - 1)
        return max(6, min(preferred, usable / count))
    }

    // MARK: - Shared rows

    static func header(_ left: String, _ right: String) -> EInkNode {
        row(
            [text(left, pixelBold), text(right, pixel, width: .flex(1), align: .trailing)],
            height: .points(14),
            align: .center
        )
    }

    static func usageFooter(_ snapshot: EInkDataSnapshot) -> EInkNode {
        let today = snapshot.usage.today
        let week = snapshot.usage.week
        return topRuled(
            row(
                [
                    text("TODAY \(EInkFormat.money(today.costUSD)) · \(EInkFormat.tokens(today.tokens)) tokens", pixel),
                    text("7 DAYS \(EInkFormat.money(week.costUSD))", pixelBold, width: .flex(1), align: .trailing)
                ],
                height: .points(14),
                align: .center
            )
        )
    }

    /// 140 px is too narrow for one line per period, so portrait prints the
    /// money on the caption line and the tokens right-aligned underneath.
    static func usageFooterPortrait(_ snapshot: EInkDataSnapshot) -> EInkNode {
        var lines: [EInkNode] = []
        for (caption, totals) in [("TODAY", snapshot.usage.today), ("7 DAYS", snapshot.usage.week)] {
            lines.append(
                row(
                    [
                        text(caption, pixelBold),
                        text(EInkFormat.money(totals.costUSD), pixelBold, width: .flex(1), align: .trailing)
                    ],
                    height: .points(12)
                )
            )
            lines.append(
                row([text("\(EInkFormat.tokens(totals.tokens)) tokens", pixel, width: .flex(1), align: .trailing)], height: .points(12))
            )
        }
        return topRuled(column(lines, height: .auto, gap: 1), paddingTop: 3)
    }

    // MARK: - Column ordering

    /// Equal-width columns: the longest provider name takes the middle slot
    /// and the two shortest sit beside it, so its overflow lands on their
    /// slack instead of on the panel edge.
    public static func longestInMiddle(_ rows: [EInkQuotaRow]) -> [EInkQuotaRow] {
        guard rows.count >= 3 else { return rows }
        let byLength = rows.enumerated().sorted {
            $0.element.providerDisplayName.count == $1.element.providerDisplayName.count
                ? $0.offset < $1.offset
                : $0.element.providerDisplayName.count < $1.element.providerDisplayName.count
        }
        let longest = byLength[byLength.count - 1].offset
        let shortest = [byLength[0].offset, byLength[1].offset]
        let rest = rows.indices.filter { $0 != longest && !shortest.contains($0) }
        var slots = [Int?](repeating: nil, count: rows.count)
        let middle = rows.count / 2
        slots[middle] = longest
        slots[middle - 1] = shortest[0]
        slots[middle + 1] = shortest[1]
        var remaining = rest
        for index in slots.indices where slots[index] == nil {
            slots[index] = remaining.removeFirst()
        }
        return slots.compactMap { $0.map { rows[$0] } }
    }

    /// Wide-first-column rows (the portrait rail): longest name first,
    /// shortest second.
    public static func longestFirst(_ rows: [EInkQuotaRow]) -> [EInkQuotaRow] {
        let byLength = rows.enumerated().sorted {
            $0.element.providerDisplayName.count == $1.element.providerDisplayName.count
                ? $0.offset < $1.offset
                : $0.element.providerDisplayName.count < $1.element.providerDisplayName.count
        }
        guard rows.count >= 3 else { return byLength.reversed().map(\.element) }
        let longest = byLength[byLength.count - 1].offset
        let shortest = byLength[0].offset
        let rest = rows.indices.filter { $0 != longest && $0 != shortest }
        return ([longest, shortest] + rest).map { rows[$0] }
    }
}
