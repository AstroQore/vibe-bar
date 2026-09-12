import Foundation

// Quota presets: Ledger, Rings, Rail. Ported from the verified demo, then
// given the round 2 composition options.
extension EInkPresets {
    // MARK: - Slot labels

    /// The label column the ledger and the table use.
    ///
    /// It grows before anything else gives way: the owner's review found
    /// "Claude · Weekly" hiding which weekly bucket a row was, and the fix is
    /// a longer name, which is only worth printing if there is room for it.
    /// `minimum` is the shipped width, `maximum` what the row can spare.
    static func labelColumnWidth(_ labels: [String], minimum: Int, maximum: Int) -> Int {
        let widest = EInkSlotLabel.widestWidth(labels)
        return max(minimum, min(maximum, widest))
    }

    /// One slot's name, on one line or two.
    ///
    /// Two lines put the SubProvider on top and the rest underneath, which is
    /// the reading order of the name itself — "Claude", then "Fable · Weekly".
    static func slotLabel(
        _ quota: EInkQuotaRow,
        width: EInkLength,
        twoLines: Bool,
        align: EInkTextAlignment = .leading,
        firstFont: EInkFont = EInkPresets.pixelBold,
        secondFont: EInkFont = EInkPresets.pixel
    ) -> EInkNode {
        guard twoLines else {
            return text(quota.slotLabel, pixel, width: width, align: align)
                .bound(.quota(quota.fieldID, .label))
        }
        return column(
            [
                text(quota.providerDisplayName, firstFont, width: .flex(1), height: .points(12), align: align),
                text(quota.windowTitle, secondFont, width: .flex(1), height: .points(12), align: align)
            ],
            width: width,
            height: .auto,
            gap: 0
        )
    }

    // MARK: - Ledger

    static func ledgerLandscape(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 4
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: "QUOTA LEFT · \(snapshot.generatedAtLabel)",
                footer: usageFooter(snapshot)
            ),
            snapshot: snapshot,
            gap: gap
        )
        let available = frame.height - 2 * margin - chrome.reserved
        // 284 content − 34 percent − 42 countdown − three 5 px gaps, minus the
        // 40 px a bar needs to still read as a bar.
        let labelWidth = labelColumnWidth(rows.map(\.slotLabel), minimum: 126, maximum: 153)
        // The column grows first. Only when a name still outruns the grown
        // column, *and* the panel has the height for a second line, does the
        // slot split — five rows on a 152 px panel do not, and a clipped name
        // beats five rows squeezed to nine pixels each.
        let roomPerRow = rows.isEmpty ? 0 : (available - gap * max(0, rows.count - 1)) / rows.count
        let twoLines = roomPerRow >= 26
            && rows.contains { EInkSlotLabel.needsTwoLines($0.slotLabel, columnWidth: labelWidth) }
        let height = fittedRowHeight(
            available: available,
            count: rows.count,
            gap: gap,
            preferred: twoLines ? 26 : chrome.preferredRowHeight(18)
        )
        let list = rows.map { quota in
            row(
                [
                    slotLabel(quota, width: .points(labelWidth), twoLines: twoLines),
                    horizontalBar(quota.remainingPercent).bound(.quota(quota.fieldID, .percent)),
                    text("\(quota.remainingPercent)%", sans(14), width: .points(34), align: .trailing)
                        .bound(.quota(quota.fieldID, .percent)),
                    text(quota.countdown, pixel, width: .points(42), align: .trailing)
                        .bound(.quota(quota.fieldID, .countdown))
                ],
                height: .points(height),
                gap: 5,
                align: .center
            ).module(slotModule(quota.fieldID))
        }
        return screen(
            chrome.compose([column(list, height: .flex(1), gap: gap)]),
            frame: frame,
            gap: gap
        )
    }

    static func ledgerPortrait(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 4
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: snapshot.generatedAtLabel,
                footer: usageFooterPortrait(snapshot)
            ),
            snapshot: snapshot,
            gap: gap
        )
        let groups = rows.map { quota in
            column(
                [
                    row(
                        [
                            text(quota.providerDisplayName, pixelBold),
                            text(quota.countdown, pixel, width: .flex(1), align: .trailing)
                                .bound(.quota(quota.fieldID, .countdown))
                        ],
                        height: .points(12)
                    ),
                    row(
                        [
                            text(quota.windowTitle, pixel, width: .points(48)),
                            horizontalBar(quota.remainingPercent).bound(.quota(quota.fieldID, .percent)),
                            text("\(quota.remainingPercent)%", sans(14), width: .points(34), align: .trailing)
                                .bound(.quota(quota.fieldID, .percent))
                        ],
                        height: .points(14),
                        gap: 4,
                        align: .center
                    )
                ],
                height: .points(28),
                gap: 2
            ).module(slotModule(quota.fieldID))
        }
        return screen(
            chrome.compose(groups + [verticalSpacer()]),
            frame: frame,
            gap: gap
        )
    }

    // MARK: - Rings

    /// Rings always print the two-line form, centred: the cell is 48 px wide
    /// and no one-line name fits it.
    static func ringCell(_ quota: EInkQuotaRow, size: Int, labelSize: Int) -> EInkNode {
        column(
            [
                ring(quota.remainingPercent, size: size, stroke: 6, labelSize: labelSize)
                    .bound(.quota(quota.fieldID, .percent)),
                text(quota.providerDisplayName, pixelBold, align: .center),
                text(quota.windowTitle, pixel, align: .center),
                text(quota.countdown, pixel, align: .center).bound(.quota(quota.fieldID, .countdown))
            ],
            width: .flex(1),
            height: .auto,
            gap: 1,
            align: .center
        ).module(slotModule(quota.fieldID))
    }

    static func ringsLandscape(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 4
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: "QUOTA LEFT · \(snapshot.generatedAtLabel)",
                footer: usageFooter(snapshot)
            ),
            snapshot: snapshot,
            gap: gap
        )
        let size = chrome.compact ? 60 : 48
        let cells = longestInMiddle(rows).map { ringCell($0, size: size, labelSize: chrome.compact ? 16 : 14) }
        return screen(
            chrome.compose([row(cells, height: .flex(1), align: .start)]),
            frame: frame,
            gap: gap
        )
    }

    static func ringsPortrait(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 4
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(right: snapshot.generatedAtLabel),
            snapshot: snapshot,
            gap: gap
        )
        var lines: [EInkNode] = []
        for start in stride(from: 0, to: rows.count, by: 2) {
            let chunk = Array(rows[start..<min(start + 2, rows.count)])
            lines.append(row(chunk.map { ringCell($0, size: 44, labelSize: 13) }, height: .points(83), align: .start))
        }
        return screen(chrome.compose(lines), frame: frame, gap: gap)
    }

    // MARK: - Rail

    static func railCell(_ quota: EInkQuotaRow, barHeight: Int, width: EInkLength) -> EInkNode {
        column(
            [
                text("\(quota.remainingPercent)", sans(13), align: .center)
                    .bound(.quota(quota.fieldID, .percent)),
                verticalBar(quota.remainingPercent, width: 22, height: barHeight)
                    .bound(.quota(quota.fieldID, .percent)),
                text(quota.providerDisplayName, pixelBold, align: .center),
                text(quota.windowTitle, pixel, align: .center)
            ],
            width: width,
            height: .auto,
            gap: 2,
            align: .center
        ).module(slotModule(quota.fieldID))
    }

    static func railLandscape(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 4
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: "QUOTA LEFT · \(snapshot.generatedAtLabel)",
                footer: usageFooter(snapshot)
            ),
            snapshot: snapshot,
            gap: gap
        )
        let barHeight = chrome.compact ? 84 : 60
        let cells = longestInMiddle(rows).map { railCell($0, barHeight: barHeight, width: .flex(1)) }
        return screen(
            chrome.compose([row(cells, height: .flex(1), align: .end)]),
            frame: frame,
            gap: gap
        )
    }

    static func railPortrait(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 6
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(right: snapshot.generatedAtLabel),
            snapshot: snapshot,
            gap: gap
        )
        let widths: [EInkLength] = [.points(60), .points(40), .points(40)]
        var lines: [EInkNode] = []
        for start in stride(from: 0, to: rows.count, by: 3) {
            let chunk = longestFirst(Array(rows[start..<min(start + 3, rows.count)]))
            let cells = chunk.enumerated().map { index, quota in
                railCell(quota, barHeight: 84, width: widths[min(index, widths.count - 1)])
            }
            lines.append(row(cells, height: .points(127), justify: .between, align: .end))
        }
        return screen(chrome.compose(lines), frame: frame, gap: gap)
    }
}
