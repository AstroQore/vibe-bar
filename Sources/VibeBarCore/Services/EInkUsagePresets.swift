import Foundation

// Usage presets: Tiles, Split, Table, Dual Bars, Trend.
extension EInkPresets {
    // MARK: - Shared

    /// Big number plus its unit, bottom-aligned the way the demo's
    /// `items-baseline` row reads on the panel.
    static func bigStat(_ value: String, _ unit: String, size: Int) -> EInkNode {
        row(
            [text(value, sans(size), height: .points(size)), text(unit, pixel)],
            height: .points(size),
            gap: 4,
            align: .end
        )
    }

    static func usageBlock(_ caption: String, _ totals: EInkUsageTotals, size: Int, gap: Int = 4) -> EInkNode {
        column(
            [
                text(caption, pixelBold, height: .points(12)),
                bigStat(EInkFormat.money(totals.costUSD), "cost", size: size),
                bigStat(EInkFormat.tokens(totals.tokens), "tokens", size: size),
                bigStat(EInkFormat.int(totals.requests), "requests", size: 14)
            ],
            gap: gap
        )
    }

    // MARK: - Tiles

    static func tile(_ caption: String, _ totals: EInkUsageTotals, size: Int, width: EInkLength) -> EInkNode {
        column(
            [
                text(caption, pixelBold, height: .points(12)),
                text(EInkFormat.money(totals.costUSD), sans(size), height: .points(size)),
                row(
                    [text(EInkFormat.tokens(totals.tokens), sans(size), height: .points(size)), text("tokens", pixel)],
                    height: .points(size),
                    gap: 4,
                    align: .end
                )
            ],
            width: width,
            height: .auto,
            gap: 3
        )
    }

    static func tilesLandscape(_ periods: [EInkUsagePeriod], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let tiles = periods.map { tile($0.caption, snapshot.usage[$0], size: 18, width: .flex(1)) }
        var children: [EInkNode] = [header("VIBE BAR", "USAGE · \(snapshot.generatedAtLabel)")]
        let first = Array(tiles.prefix(2))
        let second = Array(tiles.dropFirst(2))
        children.append(row(decorated(first), height: .flex(1), gap: 8))
        if !second.isEmpty {
            children.append(rule())
            children.append(row(decorated(second), height: .flex(1), gap: 8))
        }
        return screen(children, frame: frame, gap: 4)
    }

    /// Every tile after the first in a row gets the demo's left rule.
    private static func decorated(_ tiles: [EInkNode]) -> [EInkNode] {
        tiles.enumerated().map { index, tile in index == 0 ? tile : leftRuled(tile) }
    }

    static func tilesPortrait(_ periods: [EInkUsagePeriod], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        var children: [EInkNode] = [header("VIBE BAR", snapshot.generatedAtLabel)]
        for (index, period) in periods.enumerated() {
            if index > 0 { children.append(rule()) }
            children.append(tile(period.caption, snapshot.usage[period], size: 18, width: .flex(1)))
        }
        return screen(children, frame: frame, gap: 5)
    }

    // MARK: - Split

    static func splitLandscape(_ periods: [EInkUsagePeriod], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        var blocks: [EInkNode] = []
        for (index, period) in periods.prefix(2).enumerated() {
            let block = usageBlock(period.caption, snapshot.usage[period], size: 26)
            blocks.append(index == 0 ? block : leftRuled(block, gap: 10))
        }
        var children: [EInkNode] = [header("VIBE BAR", "USAGE · \(snapshot.generatedAtLabel)")]
        children.append(row(blocks, height: .flex(1), gap: 10))
        if let trailing = periods.dropFirst(2).first {
            let totals = snapshot.usage[trailing]
            children.append(
                topRuled(
                    row(
                        [
                            text(trailing.caption, pixelBold),
                            text(
                                "\(EInkFormat.money(totals.costUSD)) · \(EInkFormat.tokens(totals.tokens)) tokens",
                                pixel,
                                width: .flex(1),
                                align: .trailing
                            )
                        ],
                        height: .points(14),
                        align: .center
                    )
                )
            )
        }
        return screen(children, frame: frame, gap: 4)
    }

    static func splitPortrait(_ periods: [EInkUsagePeriod], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        var children: [EInkNode] = [header("VIBE BAR", snapshot.generatedAtLabel)]
        for (index, period) in periods.enumerated() {
            if index > 0 { children.append(rule()) }
            children.append(usageBlock(period.caption, snapshot.usage[period], size: 20, gap: 3))
        }
        return screen(children, frame: frame, gap: 4)
    }

    // MARK: - Table

    struct TableColumn {
        var key: Key
        var width: Int
        var title: String

        enum Key { case label, tokens, requests, cost }
    }

    static func tableRows(
        caption: String?,
        totals: EInkUsageTotals,
        columns: [TableColumn],
        limit: Int,
        rowHeight: Int,
        numberFont: EInkFont,
        gap: Int,
        compactMoney: Bool
    ) -> [EInkNode] {
        func money(_ value: Double) -> String {
            compactMoney ? EInkFormat.moneyCompact(value) : EInkFormat.money(value)
        }
        func cell(_ column: TableColumn, _ value: String, _ font: EInkFont) -> EInkNode {
            text(value, font, width: .points(column.width), align: column.key == .label ? .leading : .trailing)
        }

        var output: [EInkNode] = []
        if let caption { output.append(text(caption, pixelBold, height: .points(12))) }
        output.append(
            row(
                columns.map { cell($0, $0.title, $0.key == .label ? pixelBold : pixel) },
                height: .points(12),
                gap: gap,
                align: .center
            )
        )
        for harness in totals.rows.prefix(limit) {
            let values: [TableColumn.Key: String] = [
                .label: harness.label,
                .tokens: EInkFormat.tokens(harness.tokens),
                .requests: EInkFormat.int(harness.requests),
                .cost: money(harness.costUSD)
            ]
            output.append(
                row(
                    columns.map { cell($0, values[$0.key] ?? "", $0.key == .label ? pixel : numberFont) },
                    height: .points(rowHeight),
                    gap: gap,
                    align: .center
                )
            )
        }
        let totalValues: [TableColumn.Key: String] = [
            .label: "TOTAL",
            .tokens: EInkFormat.tokens(totals.tokens),
            .requests: EInkFormat.int(totals.requests),
            .cost: money(totals.costUSD)
        ]
        output.append(
            topRuled(
                row(
                    columns.map { cell($0, totalValues[$0.key] ?? "", $0.key == .label ? pixelBold : numberFont) },
                    height: .points(rowHeight),
                    gap: gap,
                    align: .center
                )
            )
        )
        return output
    }

    static func tableLandscape(_ limit: Int, _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let totals = snapshot.usage.today
        let week = snapshot.usage.week
        let columns = [
            TableColumn(key: .label, width: 100, title: "HARNESS · TODAY"),
            TableColumn(key: .tokens, width: 58, title: "TOKENS"),
            TableColumn(key: .requests, width: 58, title: "REQUESTS"),
            TableColumn(key: .cost, width: 52, title: "COST")
        ]
        let count = min(limit, totals.rows.count)
        let gap = 3
        let childCount = 3 + count + 1
        let available = frame.height - 2 * margin - 14 - 12 - 15 - 14 - gap * max(0, childCount - 1)
        let rowHeight = fittedRowHeight(available: available, count: max(1, count), gap: gap, preferred: 14)
        var children: [EInkNode] = [header("VIBE BAR", "USAGE · \(snapshot.generatedAtLabel)")]
        children += tableRows(
            caption: nil,
            totals: totals,
            columns: columns,
            limit: count,
            rowHeight: rowHeight,
            numberFont: sans(13),
            gap: 4,
            compactMoney: false
        )
        children.append(
            row(
                [
                    text(
                        "7 DAYS \(EInkFormat.money(week.costUSD)) · \(EInkFormat.tokens(week.tokens)) tokens · \(EInkFormat.int(week.requests)) requests",
                        pixel
                    )
                ],
                height: .points(14),
                align: .center
            )
        )
        return screen(children, frame: frame, gap: gap)
    }

    static func tablePortrait(_ limit: Int, _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        // 68 + 34 + 34 plus two 2 px gaps is exactly the 140 px content
        // width, and every part of that split is a measured number rather
        // than a guess (Fusion Pixel 12 px, via `EInkTextMetrics`):
        //
        //   * cost 34 — the widest `moneyCompact` figure is "$121k" at 34,
        //     comfortably over the "COST" header's 28.
        //   * tokens 34 — the widest figure is "242M"/"315M" at 29. The
        //     header is the reason this column is not 29: "TOKENS" measures
        //     42 and simply does not exist at this width, so the portrait
        //     table says "TOK". Spending the difference on the label column
        //     instead of a header nobody needs to read twice is the trade.
        //   * label 68 — what is left, and enough for "HARNESS" (49),
        //     "TOTAL" (35) and every common harness name: "Claude Code" 67,
        //     "AntiGravity" 63, "Gemini CLI" 62, "Grok Build" 59. The two
        //     longest names in the catalog, "Claude Cowork" (80) and
        //     "ChatGPT Work" (76), still clip — on a 152 px panel the label
        //     is the column where clipping is the right answer, because a
        //     truncated name still identifies its row while a truncated
        //     number lies about the figure.
        let columns = [
            TableColumn(key: .label, width: 68, title: "HARNESS"),
            TableColumn(key: .tokens, width: 34, title: "TOK"),
            TableColumn(key: .cost, width: 34, title: "COST")
        ]
        let blocks: [(String, EInkUsageTotals)] = [("TODAY", snapshot.usage.today), ("7 DAYS", snapshot.usage.week)]
        let counts = blocks.map { min(limit, $0.1.rows.count) }
        let gap = 2
        let childCount = 1 + counts.reduce(0) { $0 + $1 + 3 }
        let fixed = 14 + blocks.count * (12 + 12 + 15)
        let available = frame.height - 2 * margin - fixed - gap * max(0, childCount - 1)
        let rowHeight = fittedRowHeight(available: available, count: max(1, counts.reduce(0, +)), gap: gap, preferred: 14)
        var children: [EInkNode] = [header("VIBE BAR", snapshot.generatedAtLabel)]
        for (index, block) in blocks.enumerated() {
            children += tableRows(
                caption: block.0,
                totals: block.1,
                columns: columns,
                limit: counts[index],
                rowHeight: rowHeight,
                numberFont: pixelBold,
                gap: 2,
                compactMoney: true
            )
        }
        return screen(children, frame: frame, gap: gap)
    }

    // MARK: - Dual bars

    static func dualRows(
        _ totals: EInkUsageTotals,
        limit: Int,
        labelWidth: Int,
        valueWidth: Int,
        barHeight: Int,
        stackedLabel: Bool,
        rowHeight: Int
    ) -> [EInkNode] {
        let rows = Array(totals.rows.prefix(limit))
        let maxCost = max(rows.map(\.costUSD).max() ?? 0, 0.000_001)
        let maxTokens = max(rows.map(\.tokens).max() ?? 0, 1)
        func percent(_ value: Double, _ maximum: Double) -> Int {
            Int((100 * value / maximum).rounded(.down))
        }
        return rows.map { harness in
            let costLine = row(
                [
                    horizontalBar(percent(harness.costUSD, maxCost), height: barHeight),
                    text(EInkFormat.money(harness.costUSD), pixel, width: .points(valueWidth), align: .trailing)
                ],
                gap: 4,
                align: .center
            )
            let tokenLine = row(
                [
                    horizontalBar(percent(Double(harness.tokens), Double(maxTokens)), height: barHeight),
                    text(EInkFormat.tokens(harness.tokens), pixel, width: .points(valueWidth), align: .trailing)
                ],
                gap: 4,
                align: .center
            )
            if stackedLabel {
                return column(
                    [
                        text(harness.label, pixelBold, height: .points(12)),
                        row([costLine], height: .points(9), align: .center),
                        row([tokenLine], height: .points(9), align: .center)
                    ],
                    height: .points(rowHeight),
                    gap: 2
                )
            }
            let half = max(6, (rowHeight - 2) / 2)
            return row(
                [
                    text(harness.label, pixelBold, width: .points(labelWidth)),
                    column(
                        [row([costLine], height: .points(half), align: .center), row([tokenLine], height: .points(half), align: .center)],
                        gap: 2
                    )
                ],
                height: .points(rowHeight),
                gap: 6,
                align: .center
            )
        }
    }

    static func dualLandscape(_ limit: Int, _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let totals = snapshot.usage.today
        let count = max(1, min(limit, totals.rows.count))
        let gap = 3
        let available = frame.height - 2 * margin - 14 - 15 - gap * (count + 1)
        let rowHeight = fittedRowHeight(available: available, count: count, gap: gap, preferred: 26)
        let rows = dualRows(
            totals,
            limit: count,
            labelWidth: 76,
            valueWidth: 40,
            barHeight: 7,
            stackedLabel: false,
            rowHeight: rowHeight
        )
        return screen(
            [header("VIBE BAR", "COST / TOKENS · TODAY · \(snapshot.generatedAtLabel)")] + rows + [usageFooter(snapshot)],
            frame: frame,
            gap: gap
        )
    }

    static func dualPortrait(_ limit: Int, _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let totals = snapshot.usage.today
        let count = max(1, min(limit, totals.rows.count))
        let rows = dualRows(
            totals,
            limit: count,
            labelWidth: 0,
            valueWidth: 40,
            barHeight: 7,
            stackedLabel: true,
            rowHeight: 34
        )
        let footer = topRuled(
            column(
                [
                    row(
                        [
                            text("TOTAL", pixelBold),
                            text(EInkFormat.money(totals.costUSD), pixelBold, width: .flex(1), align: .trailing)
                        ],
                        height: .points(12)
                    ),
                    row([text("\(EInkFormat.tokens(totals.tokens)) tokens", pixel, width: .flex(1), align: .trailing)], height: .points(12))
                ],
                gap: 1
            ),
            paddingTop: 3
        )
        return screen(
            [header("VIBE BAR", snapshot.generatedAtLabel), text("COST / TOKENS · TODAY", pixel, height: .points(12))]
                + rows + [verticalSpacer(), footer],
            frame: frame,
            gap: 4
        )
    }

    // MARK: - Trend

    static func trendPanel(
        caption: String,
        values: [Double],
        maximumLabel: (Double) -> String,
        barHeight: Int,
        barWidth: Int,
        gap: Int
    ) -> EInkNode {
        let maximum = max(values.max() ?? 0, 0.000_001)
        let bars = values.map { value in
            verticalBar(Int((100 * value / maximum).rounded(.down)), width: barWidth, height: barHeight)
        }
        return column(
            [
                row(
                    [
                        text(caption, pixelBold),
                        text("max \(maximumLabel(maximum))", pixel, width: .flex(1), align: .trailing)
                    ],
                    height: .points(12)
                ),
                row(bars, height: .points(barHeight), gap: gap, align: .end)
            ],
            height: .auto,
            gap: 2
        )
    }

    static func trendDates(_ points: [EInkTrendPoint], barWidth: Int, gap: Int) -> EInkNode {
        row(
            points.map { text($0.dayLabel, pixel, width: .points(barWidth), align: .center) },
            height: .points(12),
            gap: gap
        )
    }

    static func trendLandscape(_ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let totals = snapshot.usage.today
        let points = snapshot.trend
        let left = column(
            [
                text("TODAY", pixelBold, height: .points(12)),
                bigStat(EInkFormat.money(totals.costUSD), "cost", size: 22),
                bigStat(EInkFormat.tokens(totals.tokens), "tokens", size: 22),
                bigStat(EInkFormat.int(totals.requests), "requests", size: 14)
            ],
            width: .points(94),
            height: .flex(1),
            gap: 5,
            justify: .center
        )
        let right = leftRuled(
            column(
                [
                    trendPanel(
                        caption: "COST · 7 DAYS",
                        values: points.map(\.costUSD),
                        maximumLabel: EInkFormat.money,
                        barHeight: 36,
                        barWidth: 14,
                        gap: 6
                    ),
                    trendPanel(
                        caption: "TOKENS · 7 DAYS",
                        values: points.map { Double($0.tokens) },
                        maximumLabel: EInkFormat.tokens,
                        barHeight: 36,
                        barWidth: 14,
                        gap: 6
                    ),
                    trendDates(points, barWidth: 14, gap: 6)
                ],
                height: .flex(1),
                gap: 4
            )
        )
        return screen(
            [
                header("VIBE BAR", "USAGE · \(snapshot.generatedAtLabel)"),
                row([left, right], height: .flex(1), gap: 8)
            ],
            frame: frame,
            gap: 4
        )
    }

    static func trendPortrait(_ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let totals = snapshot.usage.today
        let points = snapshot.trend
        return screen(
            [
                header("VIBE BAR", snapshot.generatedAtLabel),
                text("TODAY", pixelBold, height: .points(12)),
                bigStat(EInkFormat.money(totals.costUSD), "cost", size: 22),
                bigStat(EInkFormat.tokens(totals.tokens), "tokens", size: 22),
                rule(),
                trendPanel(
                    caption: "COST · 7 DAYS",
                    values: points.map(\.costUSD),
                    maximumLabel: EInkFormat.money,
                    barHeight: 52,
                    barWidth: 14,
                    gap: 6
                ),
                trendDates(points, barWidth: 14, gap: 6),
                trendPanel(
                    caption: "TOKENS · 7 DAYS",
                    values: points.map { Double($0.tokens) },
                    maximumLabel: EInkFormat.tokens,
                    barHeight: 52,
                    barWidth: 14,
                    gap: 6
                ),
                trendDates(points, barWidth: 14, gap: 6)
            ],
            frame: frame,
            gap: 5
        )
    }
}
