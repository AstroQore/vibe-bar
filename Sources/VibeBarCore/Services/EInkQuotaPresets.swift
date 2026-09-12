import Foundation

// Quota presets: Ledger, Rings, Rail. Ported from the verified demo, then
// given the round 2 composition options and the round 2 long-name rule.
extension EInkPresets {
    // MARK: - Slot labels

    /// The narrowest bar that still reads as a bar from across a desk.
    ///
    /// It is the floor the label column grows against: the column takes
    /// whatever the names need until the bar would drop below this, and only
    /// then does a slot give up a line instead.
    static let barMinimumWidth = 48

    /// The landscape ledger's shipped label column. The column never shrinks
    /// below it, so a panel of short names looks exactly as it did.
    static let ledgerColumnMinimum = 126
    /// The portrait ledger's window column, same reasoning.
    static let ledgerPortraitColumnMinimum = 48

    /// The label column the ledger and the table use.
    ///
    /// It grows before anything else gives way: the owner's review found
    /// "Claude · Weekly" hiding which weekly bucket a row was, and the fix is
    /// a longer name, which is only worth printing if there is room for it.
    /// `minimum` is the shipped width, `maximum` what the row can spare once
    /// the bar has kept `barMinimumWidth`.
    static func labelColumnWidth(_ widths: [Int], minimum: Int, maximum: Int) -> Int {
        max(minimum, min(max(minimum, maximum), widths.max() ?? 0))
    }

    /// How many text rows the panel can draw, and how tall one of them gets.
    ///
    /// A two-line slot costs two rows, so dropping the trailing slots is the
    /// only honest way to fit long names: six two-line slots in 103 px would
    /// be six rows of nine-pixel type, which is a panel nobody can read
    /// pretending to show everything.
    static func fittedSlotHeights(
        units: [Int],
        available: Int,
        gap: Int,
        preferred: Int,
        minimum: Int
    ) -> (count: Int, unit: Int) {
        func unitHeight(_ count: Int) -> Int {
            let usable = available - gap * max(0, count - 1)
            let total = max(1, units.prefix(count).reduce(0, +))
            return usable / total
        }
        var count = units.count
        while count > 1, unitHeight(count) < minimum { count -= 1 }
        return (count, max(minimum, min(preferred, unitHeight(count))))
    }

    /// One drawn line of a slot's name, bound to the part of the name it
    /// prints so the Studio can explode it without freezing it.
    static func labelFragment(
        _ fragment: EInkSlotLineFragment,
        fieldID: String,
        width: EInkLength,
        height: EInkLength = .auto,
        font: EInkFont = EInkPresets.pixel,
        align: EInkTextAlignment = .leading,
        clips: Bool? = nil
    ) -> EInkNode {
        text(fragment.text, font, width: width, height: height, align: align, clips: clips)
            .bound(fragment.part.map { EInkNodeBinding.slotLabel(fieldID, part: $0) })
    }

    /// How far a centred cell's line may overhang before two names collide.
    ///
    /// The cells are drawn edge to edge and their lines are centred, so an
    /// overhang is split between the two neighbours: 16 px is 8 px each side,
    /// which the pixel font's own side bearings absorb. The verified demo
    /// spends exactly this much ("AntiGravity" is 63 px in a 56 px cell), and
    /// a hardware push of the round 2 names at three times it came back with
    /// "Claude and GPT Models" printed through "GPT-5.3 Codex Spark".
    static let cellSpill = 16

    /// A slot's name as the centred layouts draw it: broken where it reads,
    /// centred, and never wider than its cell can lend.
    ///
    /// Rings and the rail always use this — their cells are 40–94 px wide and
    /// no three-tier name has ever fitted one line of that.
    static func centredLabelLines(
        _ quota: EInkQuotaRow,
        width: Int,
        rowWidth: Int,
        maxLines: Int = 3,
        style: EInkSlotLabelStyle = .text
    ) -> [EInkSlotLineFragment] {
        // A slot wearing its provider's mark has already said who it is, so
        // only the words the style left are wrapped under it.
        guard style.drawsLogo else {
            return labelFragments(
                EInkSlotLabel.wrapped(
                    quota.slotLabel,
                    width: width + cellSpill,
                    maxLines: maxLines,
                    truncateAt: rowWidth
                ),
                quota: quota
            )
        }
        let text = style.text(of: quota)
        guard !text.isEmpty else { return [] }
        let lines = EInkSlotLabel.wrapped(
            text,
            width: width + cellSpill,
            maxLines: maxLines,
            truncateAt: rowWidth
        )
        return lines.map { EInkSlotLineFragment($0, part: lines.count == 1 ? style.part : nil) }
    }

    /// Drawn lines tagged with the part of the name each one holds, so the
    /// Studio can explode them and keep them following the bucket.
    static func labelFragments(_ lines: [String], quota: EInkQuotaRow) -> [EInkSlotLineFragment] {
        guard lines.count > 1 else {
            return lines.map { EInkSlotLineFragment($0, part: $0 == quota.slotLabel ? .whole : nil) }
        }
        return lines.map { line in
            if line == quota.providerDisplayName { return EInkSlotLineFragment(line, part: .name) }
            if line == quota.windowTitle { return EInkSlotLineFragment(line, part: .window) }
            return EInkSlotLineFragment(line)
        }
    }

    /// A slot's name packed into lines of `width`: whole while it fits, then
    /// broken where it reads.
    static func labelLines(
        _ quota: EInkQuotaRow,
        width: Int,
        rowWidth: Int? = nil,
        maxLines: Int = 3
    ) -> [EInkSlotLineFragment] {
        if EInkSlotLabel.fits(quota.slotLabel, width: width) {
            return [EInkSlotLineFragment(quota.slotLabel, part: .whole)]
        }
        return centredLabelLines(
            quota,
            width: width,
            rowWidth: rowWidth ?? width,
            maxLines: maxLines
        )
    }

    // MARK: - Marks

    /// How a slot names itself on this slide, given what the snapshot could
    /// rasterize.
    ///
    /// A style that asks for a mark the snapshot does not carry falls back to
    /// the full name rather than drawing a slot nobody can identify: a missing
    /// logo is a rendering problem, and a nameless row is a wrong panel.
    static func labelStyle(
        _ quota: EInkQuotaRow,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions,
        size: Int
    ) -> EInkSlotLabelStyle {
        let style = options.labelStyle(for: quota.fieldID)
        guard style.drawsLogo else { return .text }
        return snapshot.logo(fieldID: quota.fieldID, size: size) == nil ? .text : style
    }

    /// The mark itself, sized for the row or the cell it stands in.
    static func logoNode(
        _ quota: EInkQuotaRow,
        snapshot: EInkDataSnapshot,
        size: Int
    ) -> EInkNode? {
        guard let uri = snapshot.logo(fieldID: quota.fieldID, size: size) else { return nil }
        return EInkNode(.image(uri), width: .points(size), height: .points(size))
            .bound(.slotLabel(quota.fieldID, part: .name))
    }

    /// What the ledger's label column holds for one slot, in words.
    static func ledgerLines(
        _ quota: EInkQuotaRow,
        style: EInkSlotLabelStyle,
        column: Int,
        full: Int
    ) -> EInkSlotLines {
        guard style.drawsLogo else {
            return EInkSlotLabel.slotLines(
                name: quota.providerDisplayName,
                window: quota.windowTitle,
                column: column,
                full: full
            )
        }
        return EInkSlotLabel.slotLines(
            text: style.text(of: quota),
            part: style.part,
            column: column,
            full: full
        )
    }

    // MARK: - Ledger

    /// What one landscape ledger slot draws, before the panel decides how
    /// many of them fit.
    struct LedgerPlan {
        var column: Int
        var lines: [EInkSlotLines]
        var styles: [EInkSlotLabelStyle]
        /// What the marks take off the front of every row, so the bars still
        /// line up when only some slots carry one.
        var logoWidth: Int
    }

    /// The label column and the per-slot line break-up for a landscape
    /// ledger `content` px wide.
    static func ledgerPlan(
        _ rows: [EInkQuotaRow],
        content: Int,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions
    ) -> LedgerPlan {
        let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.rowSize) }
        let logoWidth = styles.contains(where: \.drawsLogo) ? EInkLogo.rowSize + 5 : 0
        // 34 percent + 42 countdown + three 5 px gaps is what the figures
        // cost; the bar keeps `barMinimumWidth` of the rest and the column
        // takes everything left over.
        let figures = 34 + 42 + 5 * 3
        let maximum = content - figures - barMinimumWidth - logoWidth
        let ceiling = max(ledgerColumnMinimum - logoWidth, maximum)
        let column = labelColumnWidth(
            zip(rows, styles).map { quota, style in
                guard style.drawsLogo else {
                    return EInkSlotLabel.columnWidth(
                        name: quota.providerDisplayName,
                        window: quota.windowTitle,
                        maximum: ceiling
                    )
                }
                let text = style.text(of: quota)
                guard EInkSlotLabel.fits(text, width: ceiling) else { return 0 }
                return EInkTextMetrics.width(text, font: pixel) + EInkSlotLabel.measurementSlack
            },
            minimum: max(0, ledgerColumnMinimum - logoWidth),
            maximum: maximum
        )
        return LedgerPlan(
            column: column,
            lines: zip(rows, styles).map { ledgerLines($0, style: $1, column: column, full: content - logoWidth) },
            styles: styles,
            logoWidth: logoWidth
        )
    }

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
        let content = frame.width - 2 * margin
        let available = frame.height - 2 * margin - chrome.reserved
        let plan = ledgerPlan(rows, content: content, snapshot: snapshot, options: options)
        // The column grew first. Whatever still does not fit takes a second
        // line, a second line costs a row, and the rows that no longer fit the
        // panel are dropped from the end rather than squeezed.
        let fitted = fittedSlotHeights(
            units: plan.lines.map(\.lineCount),
            available: available,
            gap: gap,
            preferred: chrome.preferredRowHeight(18),
            minimum: 13
        )
        let list = rows.prefix(fitted.count).enumerated().map { index, quota -> EInkNode in
            ledgerSlot(
                quota,
                lines: plan.lines[index],
                columnWidth: plan.column,
                unit: fitted.unit,
                content: content,
                logo: plan.styles[index].drawsLogo
                    ? logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize)
                    : nil,
                logoWidth: plan.logoWidth
            )
        }
        return screen(
            chrome.compose([column(Array(list), height: .flex(1), gap: gap)]),
            frame: frame,
            gap: gap
        )
    }

    /// One landscape ledger slot: the figures always share a row with as much
    /// of the name as the column holds, and the rest of the name gets lines of
    /// its own.
    static func ledgerSlot(
        _ quota: EInkQuotaRow,
        lines: EInkSlotLines,
        columnWidth: Int,
        unit: Int,
        content: Int,
        logo: EInkNode? = nil,
        logoWidth: Int = 0
    ) -> EInkNode {
        // Every row reserves the same width for a mark, drawn or not: a panel
        // where three slots carry a logo and two do not still has one column
        // of bars, not two.
        let mark: [EInkNode] = logoWidth > 0
            ? [logo ?? spacer(.points(EInkLogo.rowSize))]
            : []
        let figures = row(
            mark + [
                labelFragment(
                    lines.column,
                    fieldID: quota.fieldID,
                    width: .points(columnWidth),
                    font: lines.column.part == .name ? pixelBold : pixel
                ),
                horizontalBar(quota.remainingPercent).bound(.quota(quota.fieldID, .percent)),
                text("\(quota.remainingPercent)%", sans(14), width: .points(34), align: .trailing)
                    .bound(.quota(quota.fieldID, .percent)),
                text(quota.countdown, pixel, width: .points(42), align: .trailing)
                    .bound(.quota(quota.fieldID, .countdown))
            ],
            height: .points(unit),
            gap: 5,
            align: .center
        )
        guard lines.lineCount > 1 else { return figures.module(slotModule(quota.fieldID)) }
        func wide(_ fragment: EInkSlotLineFragment) -> EInkNode {
            labelFragment(
                fragment,
                fieldID: quota.fieldID,
                width: .points(content - logoWidth),
                height: .points(unit),
                clips: true
            )
        }
        return column(
            lines.leading.map(wide) + [figures] + lines.trailing.map(wide),
            height: .points(unit * lines.lineCount),
            gap: 0
        ).module(slotModule(quota.fieldID))
    }

    /// How many slots a landscape ledger of these names actually prints.
    static func ledgerRowCount(
        _ rows: [EInkQuotaRow],
        frame: EInkRect,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions
    ) -> Int {
        let gap = 4
        let content = frame.width - 2 * margin
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(right: "", footer: usageFooter(snapshot)),
            snapshot: snapshot,
            gap: gap
        )
        return fittedSlotHeights(
            units: ledgerPlan(rows, content: content, snapshot: snapshot, options: options).lines.map(\.lineCount),
            available: frame.height - 2 * margin - chrome.reserved,
            gap: gap,
            preferred: chrome.preferredRowHeight(18),
            minimum: 13
        ).count
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
        let content = frame.width - 2 * margin
        let available = frame.height - 2 * margin - chrome.reserved
        // The bar row is [window][bar][percent]: the window column grows until
        // the bar would fall under its minimum.
        let maximum = content - 34 - barMinimumWidth - 4 * 2
        let ceiling = max(ledgerPortraitColumnMinimum, maximum)
        let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.rowSize) }
        let widths: [Int] = zip(rows, styles).map { quota, style in
            let text = style.drawsLogo ? style.text(of: quota) : quota.windowTitle
            guard EInkSlotLabel.fits(text, width: ceiling) else { return 0 }
            return EInkTextMetrics.width(text, font: pixel) + EInkSlotLabel.measurementSlack
        }
        var windowColumn = labelColumnWidth(widths, minimum: ledgerPortraitColumnMinimum, maximum: maximum)
        // A panel where every window took a line of its own has no column to
        // keep: handing its 48 px back to the bar is the whole reason the
        // column is measured rather than fixed.
        if widths.allSatisfy({ $0 == 0 }) { windowColumn = 0 }
        let plans = zip(rows, styles).map {
            portraitSlotPlan($0, style: $1, column: windowColumn, content: content)
        }
        var kept = plans.count
        while kept > 1, plans.prefix(kept).map(\.height).reduce(0, +) + gap * (kept - 1) > available {
            kept -= 1
        }
        let groups = plans.prefix(kept).map {
            ledgerPortraitSlot(
                $0,
                columnWidth: windowColumn,
                content: content,
                logo: $0.style.drawsLogo
                    ? logoNode($0.quota, snapshot: snapshot, size: EInkLogo.rowSize)
                    : nil
            )
        }
        return screen(
            chrome.compose(Array(groups) + [verticalSpacer()]),
            frame: frame,
            gap: gap
        )
    }

    /// One portrait ledger slot, before it is drawn.
    struct LedgerPortraitPlan {
        var quota: EInkQuotaRow
        var style: EInkSlotLabelStyle = .text
        /// Full-width lines between the name and the bar. Empty when the
        /// window fits its column.
        var wide: [EInkSlotLineFragment]
        /// What sits in the window column beside the bar.
        var column: EInkSlotLineFragment
        var height: Int { (style.drawsLogo ? EInkLogo.rowSize : 12) + 2 + wide.count * (12 + 2) + 14 }
    }

    static func portraitSlotPlan(
        _ quota: EInkQuotaRow,
        style: EInkSlotLabelStyle = .text,
        column: Int,
        content: Int
    ) -> LedgerPortraitPlan {
        // With a mark on the first line, the words under it are whatever the
        // style left; without one they are the group and the window.
        let text = style.drawsLogo ? style.text(of: quota) : quota.windowTitle
        let part: EInkSlotLabelPart? = style.drawsLogo ? style.part : .window
        if EInkSlotLabel.fits(text, width: column) {
            return LedgerPortraitPlan(
                quota: quota,
                style: style,
                wide: [],
                column: EInkSlotLineFragment(text, part: part)
            )
        }
        // A window too long for its column takes full-width lines above the
        // bar rather than being cut at 48 px, which is what put "Claude and
        // GPT Mo…" on the owner's panel.
        let wrapped = EInkSlotLabel.wrapped(text, width: content, maxLines: 2)
        return LedgerPortraitPlan(
            quota: quota,
            style: style,
            wide: wrapped.map { EInkSlotLineFragment($0, part: wrapped.count == 1 ? part : nil) },
            column: EInkSlotLineFragment("")
        )
    }

    static func ledgerPortraitSlot(
        _ plan: LedgerPortraitPlan,
        columnWidth: Int,
        content: Int,
        logo: EInkNode? = nil
    ) -> EInkNode {
        let quota = plan.quota
        let name = row(
            [
                // The mark stands where the SubProvider's name would be: it
                // is the same identity, drawn instead of spelled.
                logo ?? text(quota.providerDisplayName, pixelBold)
                    .bound(.slotLabel(quota.fieldID, part: .name)),
                text(quota.countdown, pixel, width: .flex(1), align: .trailing)
                    .bound(.quota(quota.fieldID, .countdown))
            ],
            height: .points(logo == nil ? 12 : EInkLogo.rowSize),
            align: .center
        )
        let wide: [EInkNode] = plan.wide.map { fragment in
            labelFragment(
                fragment,
                fieldID: quota.fieldID,
                width: .points(content),
                height: .points(12),
                clips: true
            )
        }
        let figures = row(
            [
                labelFragment(plan.column, fieldID: quota.fieldID, width: .points(columnWidth)),
                horizontalBar(quota.remainingPercent).bound(.quota(quota.fieldID, .percent)),
                text("\(quota.remainingPercent)%", sans(14), width: .points(34), align: .trailing)
                    .bound(.quota(quota.fieldID, .percent))
            ],
            height: .points(14),
            gap: 4,
            align: .center
        )
        return column(
            [name] + wide + [figures],
            height: .points(plan.height),
            gap: 2
        ).module(slotModule(quota.fieldID))
    }

    // MARK: - Rings

    /// Rings always print the two-line form, centred: the cell is 48–70 px
    /// wide and no one-line three-tier name fits it.
    static func ringCell(
        _ quota: EInkQuotaRow,
        size: Int,
        labelSize: Int,
        cellWidth: Int,
        rowWidth: Int,
        maxLines: Int,
        style: EInkSlotLabelStyle = .text,
        logo: EInkNode? = nil
    ) -> EInkNode {
        let lines = centredLabelLines(quota, width: cellWidth, rowWidth: rowWidth, maxLines: maxLines, style: style)
        return column(
            [
                ring(quota.remainingPercent, size: size, stroke: 6, labelSize: labelSize)
                    .bound(.quota(quota.fieldID, .percent))
            ] + (style.drawsLogo ? [logo].compactMap { $0 } : []) + lines.enumerated().map { index, fragment in
                labelFragment(
                    fragment,
                    fieldID: quota.fieldID,
                    width: .auto,
                    font: index == 0 ? pixelBold : pixel,
                    align: .center
                )
            } + [
                text(quota.countdown, pixel, align: .center).bound(.quota(quota.fieldID, .countdown))
            ],
            width: .flex(1),
            height: .auto,
            gap: 1,
            align: .center
        ).module(slotModule(quota.fieldID))
    }

    /// A centred grid: how many cells to a row, how big the figure in one,
    /// how many label lines they need, and how many slots the panel can hold.
    ///
    /// Cells share the row, so more of them means a narrower one means more
    /// lines. The layout gives up columns first (a name printed through its
    /// neighbour is not a name), then the figure's size one step at a time,
    /// then the trailing slot — which is the ledger's order, for the same
    /// reason.
    struct CentredGrid {
        var count: Int
        var perRow: Int
        var size: Int
        /// Text lines under the figure. The mark, when there is one, costs
        /// `markLines` on top of them.
        var lines: Int
        var markLines: Int
        var cellWidth: Int

        /// Every line the cell draws under its ring or bar.
        var totalLines: Int { lines + markLines }
    }

    static func centredGrid(
        _ rows: [EInkQuotaRow],
        content: Int,
        available: Int,
        maxPerRow: Int,
        singleRow: Bool,
        sizes: [Int],
        gap: Int,
        maxLines: Int,
        styles: [EInkSlotLabelStyle] = [],
        height: (Int, Int) -> Int
    ) -> CentredGrid {
        let total = max(1, rows.count)
        func style(_ index: Int) -> EInkSlotLabelStyle {
            index < styles.count ? styles[index] : .text
        }
        func plans(_ perRow: Int) -> (lines: Int, widest: Int, cell: Int) {
            let cell = content / max(1, perRow)
            // A single-row layout only draws its first `perRow` slots, so a
            // name in a slot it already dropped must not go on costing it
            // columns.
            let measured = singleRow ? Array(rows.prefix(perRow)) : rows
            let drawn = measured.enumerated().map {
                centredLabelLines($1, width: cell, rowWidth: content, maxLines: maxLines, style: style($0))
            }
            return (
                drawn.map(\.count).max() ?? 1,
                drawn.flatMap { $0 }.map { EInkTextMetrics.width($0.text, font: pixel) }.max() ?? 0,
                cell
            )
        }
        // A 16 px mark is a line and a third of pixel type; it is budgeted
        // as two so the cell never ends up a pixel short of its countdown.
        let markLines = rows.indices.contains(where: { style($0).drawsLogo }) ? 2 : 0
        for perRow in stride(from: min(maxPerRow, total), through: 1, by: -1) {
            let plan = plans(perRow)
            // A cell whose widest line overhangs by more than the neighbours
            // can lend is a collision, not a layout.
            if plan.widest > plan.cell + cellSpill { continue }
            for size in sizes {
                let rowHeight = height(size, plan.lines + markLines)
                guard rowHeight <= available else { continue }
                let rowsOfCells = singleRow ? 1 : max(1, (available + gap) / (rowHeight + gap))
                return CentredGrid(
                    count: min(total, rowsOfCells * perRow),
                    perRow: perRow,
                    size: size,
                    lines: plan.lines,
                    markLines: markLines,
                    cellWidth: plan.cell
                )
            }
        }
        // Nothing fits: one cell, the smallest figure, and the name wrapped
        // into whatever the height allows.
        let plan = plans(1)
        return CentredGrid(
            count: 1,
            perRow: 1,
            size: sizes.last ?? 0,
            lines: plan.lines,
            markLines: markLines,
            cellWidth: plan.cell
        )
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
        let content = frame.width - 2 * margin
        let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.cellSize) }
        let grid = centredGrid(
            rows,
            content: content,
            available: frame.height - 2 * margin - chrome.reserved,
            maxPerRow: max(1, rows.count),
            singleRow: true,
            sizes: chrome.compact ? [60, 52, 44, 36] : [48, 40, 32],
            gap: gap,
            maxLines: 4,
            styles: styles,
            // ring + mark + label lines + countdown, and a 1 px gap between.
            height: { size, lines in size + (lines + 1) * 12 + lines + 1 }
        )
        let kept = Array(rows.prefix(grid.count))
        let styleByField = Dictionary(zip(rows.map(\.fieldID), styles), uniquingKeysWith: { first, _ in first })
        let ordered = longestInMiddle(kept)
        let cells = ordered.map { quota in
            ringCell(
                quota,
                size: grid.size,
                labelSize: chrome.compact ? 16 : 14,
                cellWidth: grid.cellWidth,
                rowWidth: content,
                maxLines: grid.lines,
                style: styleByField[quota.fieldID] ?? .text,
                logo: logoNode(quota, snapshot: snapshot, size: EInkLogo.cellSize)
            )
        }
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
        let content = frame.width - 2 * margin
        let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.cellSize) }
        let grid = centredGrid(
            rows,
            content: content,
            available: frame.height - 2 * margin - chrome.reserved,
            maxPerRow: min(2, max(1, rows.count)),
            singleRow: false,
            sizes: [44, 36, 28],
            gap: gap,
            maxLines: 4,
            styles: styles,
            height: { size, lines in max(83, size + (lines + 1) * 12 + lines + 1) }
        )
        let kept = Array(rows.prefix(grid.count))
        let cellHeight = max(83, grid.size + (grid.totalLines + 1) * 12 + grid.totalLines + 1)
        var lines: [EInkNode] = []
        for start in stride(from: 0, to: kept.count, by: grid.perRow) {
            let chunk = Array(kept[start..<min(start + grid.perRow, kept.count)])
            lines.append(
                row(
                    chunk.enumerated().map { index, quota in
                        ringCell(
                            quota,
                            size: grid.size,
                            labelSize: 13,
                            cellWidth: grid.cellWidth,
                            rowWidth: content,
                            maxLines: grid.lines,
                            style: styles[min(start + index, styles.count - 1)],
                            logo: logoNode(quota, snapshot: snapshot, size: EInkLogo.cellSize)
                        )
                    },
                    height: .points(cellHeight),
                    align: .start
                )
            )
        }
        return screen(chrome.compose(lines), frame: frame, gap: gap)
    }

    // MARK: - Rail

    static func railCell(
        _ quota: EInkQuotaRow,
        barHeight: Int,
        width: EInkLength,
        cellWidth: Int,
        rowWidth: Int,
        maxLines: Int,
        style: EInkSlotLabelStyle = .text,
        logo: EInkNode? = nil
    ) -> EInkNode {
        let lines = centredLabelLines(quota, width: cellWidth, rowWidth: rowWidth, maxLines: maxLines, style: style)
        return column(
            [
                text("\(quota.remainingPercent)", sans(13), align: .center)
                    .bound(.quota(quota.fieldID, .percent)),
                verticalBar(quota.remainingPercent, width: 22, height: barHeight)
                    .bound(.quota(quota.fieldID, .percent))
            ] + (style.drawsLogo ? [logo].compactMap { $0 } : []) + lines.enumerated().map { index, fragment in
                labelFragment(
                    fragment,
                    fieldID: quota.fieldID,
                    width: .auto,
                    font: index == 0 ? pixelBold : pixel,
                    align: .center
                )
            },
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
        let content = frame.width - 2 * margin
        let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.cellSize) }
        let grid = centredGrid(
            rows,
            content: content,
            available: frame.height - 2 * margin - chrome.reserved,
            maxPerRow: max(1, rows.count),
            singleRow: true,
            sizes: chrome.compact ? [84, 72, 60, 48] : [60, 48, 36, 30],
            gap: gap,
            maxLines: 4,
            styles: styles,
            // the percentage, the bar, the label lines, and a 2 px gap between.
            height: { bar, lines in 13 + bar + lines * 12 + (1 + lines) * 2 }
        )
        let styleByField = Dictionary(zip(rows.map(\.fieldID), styles), uniquingKeysWith: { first, _ in first })
        let ordered = longestInMiddle(Array(rows.prefix(grid.count)))
        let cells = ordered.map { quota in
            railCell(
                quota,
                barHeight: grid.size,
                width: .flex(1),
                cellWidth: grid.cellWidth,
                rowWidth: content,
                maxLines: grid.lines,
                style: styleByField[quota.fieldID] ?? .text,
                logo: logoNode(quota, snapshot: snapshot, size: EInkLogo.cellSize)
            )
        }
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
        let content = frame.width - 2 * margin
        let available = frame.height - 2 * margin - chrome.reserved
        let ordered = longestFirst(rows)
        let styleByField = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0.fieldID, labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.cellSize))
            }
        )
        // The demo's wide-first columns, kept while the names fit them. A
        // panel of three-tier names gets equal columns instead, and fewer of
        // them, rather than three names printed through each other.
        let demo = [60, 40, 40]
        func fits(_ widths: [Int]) -> Int? {
            let drawn = ordered.enumerated().map { index, quota in
                (
                    widths[min(index % widths.count, widths.count - 1)],
                    centredLabelLines(
                        quota,
                        width: widths[min(index % widths.count, widths.count - 1)],
                        rowWidth: content,
                        maxLines: 4,
                        style: styleByField[quota.fieldID] ?? .text
                    )
                )
            }
            for (width, lines) in drawn {
                let widest = lines.map { EInkTextMetrics.width($0.text, font: pixel) }.max() ?? 0
                if widest > width + cellSpill { return nil }
            }
            return drawn.map(\.1.count).max() ?? 2
        }
        var widths = demo
        var needed = fits(demo)
        if needed == nil {
            for perRow in [2, 1] {
                let equal = Array(repeating: content / perRow, count: perRow)
                if let lines = fits(equal) {
                    widths = equal
                    needed = lines
                    break
                }
            }
        }
        let lineCountPerCell = needed ?? 2
        let markLines = styleByField.values.contains(where: \.drawsLogo) ? 2 : 0
        var barHeight = 84
        func rowHeight() -> Int {
            max(127, 13 + barHeight + (lineCountPerCell + markLines) * 12 + (1 + lineCountPerCell + markLines) * 2)
        }
        var rowsOfCells = (rows.count + widths.count - 1) / widths.count
        while rowsOfCells > 1, rowHeight() * rowsOfCells + gap * (rowsOfCells - 1) > available {
            if barHeight > 36 { barHeight -= 12 } else { rowsOfCells -= 1 }
        }
        let kept = Array(rows.prefix(rowsOfCells * widths.count))
        var lines: [EInkNode] = []
        for start in stride(from: 0, to: kept.count, by: widths.count) {
            let chunk = longestFirst(Array(kept[start..<min(start + widths.count, kept.count)]))
            let cells = chunk.enumerated().map { index, quota in
                railCell(
                    quota,
                    barHeight: barHeight,
                    width: .points(widths[min(index, widths.count - 1)]),
                    cellWidth: widths[min(index, widths.count - 1)],
                    rowWidth: content,
                    maxLines: lineCountPerCell,
                    style: styleByField[quota.fieldID] ?? .text,
                    logo: logoNode(quota, snapshot: snapshot, size: EInkLogo.cellSize)
                )
            }
            lines.append(row(cells, height: .points(rowHeight()), justify: .between, align: .end))
        }
        return screen(chrome.compose(lines), frame: frame, gap: gap)
    }
}
