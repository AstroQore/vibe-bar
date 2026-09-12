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
        align: EInkTextAlignment = .leading,
        clips: Bool? = nil
    ) -> EInkNode {
        EInkNode(
            .text(content, font: font, alignment: align),
            width: width,
            height: height,
            clipsText: clips
        )
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

    /// What a Canvas API task with no slide behind it draws.
    ///
    /// The Dot. API can update a task in the device's loop but cannot delete
    /// one, so a slide the user removes would otherwise stay on that slot
    /// forever — a panel showing a quota row nobody configured any more, with
    /// numbers frozen at whatever they were. A stale reading on a glanceable
    /// surface is worse than a blank one, so the slot says what it is instead.
    ///
    /// English on purpose, like every other string the device draws.
    public static func unusedSlot(_ frame: EInkRect) -> EInkNode {
        column(
            [
                text("VIBE BAR", pixelBold, width: .flex(1), height: .points(12)),
                rule(),
                verticalSpacer(),
                text("THIS SLOT IS UNUSED", pixel, width: .flex(1), height: .points(12), align: .center),
                text("REMOVE IT IN THE DOT. APP", pixel, width: .flex(1), height: .points(12), align: .center),
                verticalSpacer()
            ],
            width: .points(frame.width),
            height: .points(frame.height),
            gap: 6,
            padding: EInkInsets(all: margin)
        )
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

    /// Free space that draws nothing. A container with no border and no fill
    /// emits no box, so this costs the device's element budget nothing.
    static func spacer(_ width: EInkLength = .flex(1)) -> EInkNode {
        EInkNode(.row, width: width)
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

    static func header(
        _ left: String,
        _ right: String,
        leftBinding: EInkNodeBinding? = nil,
        rightBinding: EInkNodeBinding? = nil
    ) -> EInkNode {
        row(
            [
                text(left, pixelBold).bound(leftBinding),
                text(right, pixel, width: .flex(1), align: .trailing).bound(rightBinding)
            ],
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

    /// The module id one quota slot's nodes carry, so the exploder can group
    /// them.
    static func slotModule(_ fieldID: String) -> String { "slot:\(fieldID)" }

    static let headerModule = "header"
    static let footerModule = "footer"

    // MARK: - Chrome (header / footer composition)

    /// What one preset prints in its bars when the slide has not said
    /// otherwise. Round 1's strings, exactly.
    struct ChromeDefaults {
        var left: String
        var right: String
        /// `nil` when this preset never had a footer.
        var footer: EInkNode?

        init(left: String = "VIBE BAR", right: String, footer: EInkNode? = nil) {
            self.left = left
            self.right = right
            self.footer = footer
        }
    }

    /// A slide's resolved header and footer, plus the height they cost the
    /// body.
    struct Chrome {
        var header: EInkNode?
        var headerAtBottom = false
        var footer: EInkNode?
        var reserved = 0
        var compact = false

        /// `body` between the bars, in the order the slide asked for.
        func compose(_ body: [EInkNode]) -> [EInkNode] {
            var children: [EInkNode] = []
            if let header, !headerAtBottom { children.append(header) }
            children += body
            if let footer { children.append(footer) }
            if let header, headerAtBottom { children.append(header) }
            return children
        }

        /// The row height a list should aim for: the preset's own, unless the
        /// slide asked to fill the panel.
        func preferredRowHeight(_ preferred: Int) -> Int {
            compact ? 1_000 : preferred
        }
    }

    static func chrome(
        _ options: EInkSlideOptions,
        defaults: ChromeDefaults,
        snapshot: EInkDataSnapshot,
        gap: Int
    ) -> Chrome {
        var result = Chrome(compact: options.compact)
        if let bar = options.header {
            let left = barText(bar.left, default: defaults.left, snapshot: snapshot)
            let right = barText(bar.right, default: defaults.right, snapshot: snapshot)
            if !left.isEmpty || !right.isEmpty {
                result.header = header(left, right, leftBinding: binding(for: bar.left), rightBinding: binding(for: bar.right))
                    .module(headerModule)
                result.headerAtBottom = bar.position == .bottom
                result.reserved += 14 + gap
            }
        }
        if let config = options.footer, let node = footerNode(config.content, defaults: defaults, snapshot: snapshot) {
            result.footer = node.module(footerModule)
            result.reserved += EInkBoxLayout.intrinsicHeight(node) + gap
        }
        return result
    }

    /// What an exploded header element follows. Only the clock and the date
    /// move on their own; everything else is a fixed string.
    static func binding(for content: EInkBarContent) -> EInkNodeBinding? {
        switch content {
        case .clock: .clock
        case .date: .date
        default: nil
        }
    }

    static func barText(_ content: EInkBarContent, default fallback: String, snapshot: EInkDataSnapshot) -> String {
        switch content {
        case .presetDefault: return fallback
        case .none: return ""
        case let .text(value): return value
        case .clock: return snapshot.clockLabel
        case .date: return snapshot.dateLabel
        case .dateClock: return snapshot.generatedAtLabel
        case .providerStatus: return snapshot.providerStatusLine
        }
    }

    static func footerNode(
        _ content: EInkFooterContent,
        defaults: ChromeDefaults,
        snapshot: EInkDataSnapshot
    ) -> EInkNode? {
        switch content {
        case .presetDefault:
            return defaults.footer
        case let .usageSummary(periods):
            return usageSummaryFooter(periods, snapshot)
        case .clock:
            return topRuled(
                row([text(snapshot.generatedAtLabel, pixel, width: .flex(1), align: .center)], height: .points(14), align: .center)
            )
        case let .text(value):
            guard !value.isEmpty else { return nil }
            return topRuled(row([text(value, pixel, width: .flex(1))], height: .points(14), align: .center))
        }
    }

    /// A footer over the windows the slide picked. One line each, so two
    /// windows read like the shipped footer and four still fit.
    static func usageSummaryFooter(_ periods: [EInkUsagePeriod], _ snapshot: EInkDataSnapshot) -> EInkNode? {
        let chosen = periods.isEmpty ? [EInkUsagePeriod.today, .week] : periods
        let lines = chosen.map { period -> EInkNode in
            let totals = snapshot.usage[period]
            return row(
                [
                    text("\(period.caption) \(EInkFormat.money(totals.costUSD))", pixelBold),
                    text("\(EInkFormat.tokens(totals.tokens)) tokens", pixel, width: .flex(1), align: .trailing)
                ],
                height: .points(14),
                align: .center
            )
        }
        guard !lines.isEmpty else { return nil }
        return topRuled(column(lines, height: .auto, gap: 1))
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
