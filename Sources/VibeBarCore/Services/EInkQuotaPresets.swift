import Foundation

// Quota presets: Ledger, Rings, Rail. Ported from the verified demo.
extension EInkPresets {
    // MARK: - Ledger

    static func ledgerLandscape(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let gap = 4
        let footer = usageFooter(snapshot)
        let available = frame.height - 2 * margin - 14 - 15 - 2 * gap
        let height = fittedRowHeight(available: available, count: rows.count, gap: gap, preferred: 18)
        let list = rows.map { quota in
            row(
                [
                    text("\(quota.providerDisplayName) · \(quota.windowTitle)", pixel, width: .points(126)),
                    horizontalBar(quota.remainingPercent),
                    text("\(quota.remainingPercent)%", sans(14), width: .points(34), align: .trailing),
                    text(quota.countdown, pixel, width: .points(42), align: .trailing)
                ],
                height: .points(height),
                gap: 5,
                align: .center
            )
        }
        return screen(
            [header("VIBE BAR", "QUOTA LEFT · \(snapshot.generatedAtLabel)")]
                + [column(list, height: .flex(1), gap: gap)]
                + [footer],
            frame: frame,
            gap: gap
        )
    }

    static func ledgerPortrait(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let groups = rows.map { quota in
            column(
                [
                    row(
                        [
                            text(quota.providerDisplayName, pixelBold),
                            text(quota.countdown, pixel, width: .flex(1), align: .trailing)
                        ],
                        height: .points(12)
                    ),
                    row(
                        [
                            text(quota.windowTitle, pixel, width: .points(48)),
                            horizontalBar(quota.remainingPercent),
                            text("\(quota.remainingPercent)%", sans(14), width: .points(34), align: .trailing)
                        ],
                        height: .points(14),
                        gap: 4,
                        align: .center
                    )
                ],
                height: .points(28),
                gap: 2
            )
        }
        return screen(
            [header("VIBE BAR", snapshot.generatedAtLabel)] + groups + [verticalSpacer(), usageFooterPortrait(snapshot)],
            frame: frame,
            gap: 4
        )
    }

    // MARK: - Rings

    static func ringCell(_ quota: EInkQuotaRow, size: Int, labelSize: Int) -> EInkNode {
        column(
            [
                ring(quota.remainingPercent, size: size, stroke: 6, labelSize: labelSize),
                text(quota.providerDisplayName, pixelBold, align: .center),
                text(quota.windowTitle, pixel, align: .center),
                text(quota.countdown, pixel, align: .center)
            ],
            width: .flex(1),
            height: .auto,
            gap: 1,
            align: .center
        )
    }

    static func ringsLandscape(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let cells = longestInMiddle(rows).map { ringCell($0, size: 48, labelSize: 14) }
        return screen(
            [
                header("VIBE BAR", "QUOTA LEFT · \(snapshot.generatedAtLabel)"),
                row(cells, height: .flex(1), align: .start),
                usageFooter(snapshot)
            ],
            frame: frame,
            gap: 4
        )
    }

    static func ringsPortrait(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        var lines: [EInkNode] = []
        for start in stride(from: 0, to: rows.count, by: 2) {
            let chunk = Array(rows[start..<min(start + 2, rows.count)])
            lines.append(row(chunk.map { ringCell($0, size: 44, labelSize: 13) }, height: .points(83), align: .start))
        }
        return screen([header("VIBE BAR", snapshot.generatedAtLabel)] + lines, frame: frame, gap: 4)
    }

    // MARK: - Rail

    static func railCell(_ quota: EInkQuotaRow, barHeight: Int, width: EInkLength) -> EInkNode {
        column(
            [
                text("\(quota.remainingPercent)", sans(13), align: .center),
                verticalBar(quota.remainingPercent, width: 22, height: barHeight),
                text(quota.providerDisplayName, pixelBold, align: .center),
                text(quota.windowTitle, pixel, align: .center)
            ],
            width: width,
            height: .auto,
            gap: 2,
            align: .center
        )
    }

    static func railLandscape(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let cells = longestInMiddle(rows).map { railCell($0, barHeight: 60, width: .flex(1)) }
        return screen(
            [
                header("VIBE BAR", "QUOTA LEFT · \(snapshot.generatedAtLabel)"),
                row(cells, height: .flex(1), align: .end),
                usageFooter(snapshot)
            ],
            frame: frame,
            gap: 4
        )
    }

    static func railPortrait(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, frame: EInkRect) -> EInkNode {
        let widths: [EInkLength] = [.points(60), .points(40), .points(40)]
        var lines: [EInkNode] = []
        for start in stride(from: 0, to: rows.count, by: 3) {
            let chunk = longestFirst(Array(rows[start..<min(start + 3, rows.count)]))
            let cells = chunk.enumerated().map { index, quota in
                railCell(quota, barHeight: 84, width: widths[min(index, widths.count - 1)])
            }
            lines.append(row(cells, height: .points(127), justify: .between, align: .end))
        }
        return screen([header("VIBE BAR", snapshot.generatedAtLabel)] + lines, frame: frame, gap: 6)
    }
}
