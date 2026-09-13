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

    /// The label column the ledger and the table use: exactly as wide as the
    /// widest thing actually drawn in it, and never wider than `maximum`.
    ///
    /// Round 2 gave the column a fixed 126 px floor so a panel of short names
    /// looked as it always had. The owner's round 3 review killed it: a ledger
    /// of "Logo only" slots draws a 14 px mark and nothing else, and the floor
    /// left 107 px of white between the mark and the bar. A column holds what
    /// it holds; every pixel it does not need belongs to the bar.
    static func labelColumnWidth(_ widths: [Int], maximum: Int) -> Int {
        max(0, min(maximum, widths.max() ?? 0))
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
        let maximum = max(0, content - figures - barMinimumWidth - logoWidth)
        let column = labelColumnWidth(
            zip(rows, styles).map { quota, style in
                guard style.drawsLogo else {
                    return EInkSlotLabel.columnWidth(
                        name: quota.providerDisplayName,
                        window: quota.windowTitle,
                        maximum: maximum
                    )
                }
                // A slot wearing nothing but its mark asks the column for
                // nothing: the mark has its own reserved width in front.
                let text = style.text(of: quota)
                guard !text.isEmpty, EInkSlotLabel.fits(text, width: maximum) else { return 0 }
                return EInkTextMetrics.width(text, font: pixel) + EInkSlotLabel.measurementSlack
            },
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
        // A column that holds nothing is not drawn at all: an empty box would
        // still cost the row its gap, which is the white the owner's "Logo
        // only" ledger had between the mark and the bar.
        let label: [EInkNode] = columnWidth > 0
            ? [
                labelFragment(
                    lines.column,
                    fieldID: quota.fieldID,
                    width: .points(columnWidth),
                    font: lines.column.part == .name ? pixelBold : pixel
                )
            ]
            : []
        let figures = row(
            mark + label + [
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
        let maximum = max(0, content - 34 - barMinimumWidth - 4 * 2)
        let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.rowSize) }
        let widths: [Int] = zip(rows, styles).map { quota, style in
            let text = style.drawsLogo ? style.text(of: quota) : quota.windowTitle
            guard !text.isEmpty, EInkSlotLabel.fits(text, width: maximum) else { return 0 }
            return EInkTextMetrics.width(text, font: pixel) + EInkSlotLabel.measurementSlack
        }
        // A panel where every window took a line of its own — or drew nothing
        // but a mark — has no column to keep, and the bar takes the row.
        let windowColumn = labelColumnWidth(widths, maximum: maximum)
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
        let label: [EInkNode] = columnWidth > 0
            ? [labelFragment(plan.column, fieldID: quota.fieldID, width: .points(columnWidth))]
            : []
        let figures = row(
            label + [
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

    // MARK: - Centred cells (rings and the rail)

    /// The narrowest column a centred cell can be drawn in.
    ///
    /// A rail cell holds a 22 px bar under a three-digit percentage, and a
    /// ring cell holds the smallest ring the panel still reads as one. Below
    /// this a column is not a slot, so the row drops a cell instead.
    static let railCellMinimum = 40
    static let ringCellMinimum = 44

    /// One centred cell's name: at most two lines, fitted to the column the
    /// row actually gave it.
    ///
    /// A slot wearing its provider's mark has already said who it is, so only
    /// the words the style left are drawn — and "Logo only" draws no text line
    /// at all, which is height the bar gets back.
    /// `rowWidth` is the panel's own content width: a cell lends its
    /// neighbours' slack, but nothing may be wider than the row, and a name
    /// that is gets the one ellipsis the panel is allowed to draw.
    static func cellLabelLines(
        _ quota: EInkQuotaRow,
        style: EInkSlotLabelStyle,
        width: Int,
        rowWidth: Int? = nil
    ) -> [EInkSlotLineFragment] {
        let limit = rowWidth ?? width
        guard style.drawsLogo else {
            return EInkSlotLabel.cellLines(
                name: quota.providerDisplayName,
                window: quota.windowTitle,
                width: width,
                rowWidth: limit
            )
        }
        let text = style.text(of: quota)
        guard !text.isEmpty else { return [] }
        func line(_ value: String, _ part: EInkSlotLabelPart?) -> [EInkSlotLineFragment] {
            let cut = EInkSlotLabel.truncated(value, width: limit, font: pixel)
            return [EInkSlotLineFragment(cut, part: cut == value ? part : nil)]
        }
        if EInkSlotLabel.fits(text, width: width) { return line(text, style.part) }
        // The same rule the words follow: the group goes before anything is
        // cut, and the window — the tier the reader came for — stays.
        let tiers = text.components(separatedBy: EInkSlotLabel.separator)
        guard tiers.count > 1, let last = tiers.last else { return line(text, style.part) }
        return line(last, .period)
    }

    /// The width one centred cell asks its row for.
    static func cellDesiredWidth(_ quota: EInkQuotaRow, style: EInkSlotLabelStyle) -> Int {
        guard style.drawsLogo else {
            return EInkSlotLabel.cellDesiredWidth(
                name: quota.providerDisplayName,
                window: quota.windowTitle
            )
        }
        let text = style.text(of: quota)
        guard !text.isEmpty else { return 0 }
        return EInkTextMetrics.width(text, font: pixel) + EInkSlotLabel.measurementSlack
    }

    /// One row of centred cells, sized to the names it has to print.
    ///
    /// Round 2 split the row into equal columns, which gave "Weekly" the same
    /// 94 px as "Claude and GPT Models · Weekly" and served neither: the long
    /// name wrapped onto three lines and every bar in the row shrank to the
    /// stub the owner's review reported. Here each column asks for what its
    /// own name needs, the row shares itself out in proportion, and the figure
    /// takes every pixel of height the tallest label left.
    struct CentredRowPlan {
        var rows: [EInkQuotaRow]
        var styles: [EInkSlotLabelStyle]
        var widths: [Int]
        var lines: [[EInkSlotLineFragment]]
        /// Ring diameter, or bar height.
        var figure: Int
        /// Text lines under the tallest cell's figure.
        var textLines: Int
        /// Whether any cell in the row draws a mark.
        var drawsMark: Bool
    }

    /// Fits `rows` into one row `content` wide and `available` tall.
    ///
    /// `figure` is handed the row's line count and answers with the height
    /// left for the ring or the bar; a row that cannot give it `minimumFigure`
    /// drops its last slot and tries again, which is the ledger's order and
    /// the same reason — a figure nobody can read is not a smaller figure.
    static func planRow(
        _ rows: [EInkQuotaRow],
        styleByField: [String: EInkSlotLabelStyle],
        content: Int,
        minimumCell: Int,
        order: ([EInkQuotaRow]) -> [EInkQuotaRow],
        figure: (_ widths: [Int], _ textLines: Int, _ drawsMark: Bool) -> Int
    ) -> CentredRowPlan {
        // Every cell measures against the row, not only its own column.
        let ordered = order(rows)
        let styles = ordered.map { styleByField[$0.fieldID] ?? .text }
        let widths = EInkSlotLabel.sharedWidths(
            zip(ordered, styles).map(cellDesiredWidth),
            total: content,
            minimum: minimumCell
        )
        let lines = zip(zip(ordered, styles), widths).map { pair, width in
            cellLabelLines(pair.0, style: pair.1, width: width, rowWidth: content)
        }
        let textLines = lines.map(\.count).max() ?? 0
        let drawsMark = styles.contains(where: \.drawsLogo)
        return CentredRowPlan(
            rows: ordered,
            styles: styles,
            widths: widths,
            lines: lines,
            figure: figure(widths, textLines, drawsMark),
            textLines: textLines,
            drawsMark: drawsMark
        )
    }

    /// Whether a planned row can actually be drawn.
    ///
    /// Every column keeps the minimum a figure needs, the figure keeps a size
    /// that still reads, and no cell's line overhangs by more than the
    /// neighbours can lend — the last one is what stops "ChatGPT Agentic"
    /// printing through "AntiGravity" on a 140 px panel.
    static func isDrawable(_ plan: CentredRowPlan, minimumCell: Int, minimumFigure: Int) -> Bool {
        guard plan.widths.min() ?? 0 >= minimumCell, plan.figure >= minimumFigure else { return false }
        for (index, lines) in plan.lines.enumerated() {
            let widest = lines.map { EInkTextMetrics.width($0.text, font: pixel) }.max() ?? 0
            if widest > plan.widths[index] + cellSpill { return false }
        }
        return true
    }

    /// One row of cells: as many as the names can be drawn in, dropping the
    /// trailing slot rather than printing two names through each other.
    static func centredRowPlan(
        _ rows: [EInkQuotaRow],
        styleByField: [String: EInkSlotLabelStyle],
        content: Int,
        minimumCell: Int,
        minimumFigure: Int,
        order: @escaping ([EInkQuotaRow]) -> [EInkQuotaRow] = { $0 },
        figure: (_ widths: [Int], _ textLines: Int, _ drawsMark: Bool) -> Int
    ) -> CentredRowPlan {
        func plan(_ count: Int) -> CentredRowPlan {
            planRow(
                Array(rows.prefix(count)),
                styleByField: styleByField,
                content: content,
                minimumCell: minimumCell,
                order: order,
                figure: figure
            )
        }
        for count in stride(from: max(1, rows.count), through: 2, by: -1) {
            let candidate = plan(count)
            guard isDrawable(candidate, minimumCell: minimumCell, minimumFigure: minimumFigure) else { continue }
            return candidate
        }
        return plan(1)
    }

    /// A portrait grid of centred cells: the widest number of columns every
    /// row can actually draw, then as many rows as the height holds.
    static func centredRowGrid(
        _ rows: [EInkQuotaRow],
        styleByField: [String: EInkSlotLabelStyle],
        content: Int,
        available: Int,
        gap: Int,
        maxPerRow: Int,
        minimumCell: Int,
        minimumFigure: Int,
        order: @escaping ([EInkQuotaRow]) -> [EInkQuotaRow] = { $0 },
        figure: (_ share: Int, _ widths: [Int], _ textLines: Int, _ drawsMark: Bool) -> Int,
        height: (CentredRowPlan) -> Int
    ) -> [CentredRowPlan] {
        func chunks(_ perRow: Int) -> [[EInkQuotaRow]] {
            stride(from: 0, to: rows.count, by: perRow).map {
                Array(rows[$0..<min($0 + perRow, rows.count)])
            }
        }
        func plans(_ perRow: Int) -> [CentredRowPlan] {
            let groups = chunks(perRow)
            let share = max(0, (available - gap * max(0, groups.count - 1)) / max(1, groups.count))
            return groups.map { group in
                planRow(
                    group,
                    styleByField: styleByField,
                    content: content,
                    minimumCell: minimumCell,
                    order: order,
                    figure: { figure(share, $0, $1, $2) }
                )
            }
        }
        var chosen = plans(1)
        for perRow in stride(from: max(1, min(maxPerRow, rows.count)), through: 2, by: -1) {
            let candidate = plans(perRow)
            guard candidate.allSatisfy({ isDrawable($0, minimumCell: minimumCell, minimumFigure: minimumFigure) })
            else { continue }
            chosen = candidate
            break
        }
        // The height the panel actually has decides how many of those rows
        // survive; a row that does not fit is dropped rather than squeezed.
        var kept: [CentredRowPlan] = []
        var used = 0
        for plan in chosen {
            let cost = height(plan)
            guard kept.isEmpty || used + gap + cost <= available else { break }
            used += (kept.isEmpty ? 0 : gap) + cost
            kept.append(plan)
        }
        return kept
    }

    // MARK: - Rings

    /// One ring cell: the figure, the mark the style asked for, at most two
    /// lines of name, and the countdown.
    static func ringCell(
        _ quota: EInkQuotaRow,
        size: Int,
        labelSize: Int,
        width: Int,
        lines: [EInkSlotLineFragment],
        style: EInkSlotLabelStyle = .text,
        logo: EInkNode? = nil
    ) -> EInkNode {
        column(
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
            width: .points(width),
            height: .auto,
            gap: 1,
            align: .center
        ).module(slotModule(quota.fieldID))
    }

    /// A ring cell's height, given the ring's diameter.
    ///
    /// ring + mark + label lines + countdown, with a 1 px gap between each.
    static func ringCellHeight(size: Int, textLines: Int, drawsMark: Bool) -> Int {
        let mark = drawsMark ? EInkLogo.cellSize : 0
        let children = 2 + (drawsMark ? 1 : 0) + textLines
        return size + mark + textLines * 12 + 12 + max(0, children - 1)
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
        let available = frame.height - 2 * margin - chrome.reserved
        let styleByField = styleMap(rows, snapshot: snapshot, options: options, size: EInkLogo.cellSize)
        let plan = centredRowPlan(
            rows,
            styleByField: styleByField,
            content: content,
            minimumCell: ringCellMinimum,
            minimumFigure: 28,
            order: longestInMiddle
        ) { widths, textLines, drawsMark in
            // Every pixel the labels did not take is the ring's, and the only
            // other limit is the column it has to fit inside.
            ringSize(
                available: available,
                textLines: textLines,
                drawsMark: drawsMark,
                maximum: widths.min() ?? 0
            )
        }
        let cells = plan.rows.indices.map { index in
            ringCell(
                plan.rows[index],
                size: plan.figure,
                labelSize: chrome.compact ? 16 : 14,
                width: plan.widths[index],
                lines: plan.lines[index],
                style: plan.styles[index],
                logo: logoNode(plan.rows[index], snapshot: snapshot, size: EInkLogo.cellSize)
            )
        }
        return screen(
            chrome.compose([row(cells, height: .flex(1), align: .start)]),
            frame: frame,
            gap: gap
        )
    }

    /// The largest ring the height allows, never wider than `maximum` — the
    /// narrowest column in the row, because a ring is square and one wider
    /// than its cell would be drawn through its neighbour.
    static func ringSize(available: Int, textLines: Int, drawsMark: Bool, maximum: Int) -> Int {
        let chrome = ringCellHeight(size: 0, textLines: textLines, drawsMark: drawsMark)
        return max(0, min(maximum, available - chrome))
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
        let available = frame.height - 2 * margin - chrome.reserved
        let styleByField = styleMap(rows, snapshot: snapshot, options: options, size: EInkLogo.cellSize)
        // Two to a row while the names allow it: a portrait ring cell is 70 px
        // of width, which one three-tier name uses up on its own.
        let plans = centredRowGrid(
            rows,
            styleByField: styleByField,
            content: content,
            available: available,
            gap: gap,
            maxPerRow: 2,
            minimumCell: ringCellMinimum,
            minimumFigure: 24,
            figure: { share, widths, textLines, drawsMark in
                ringSize(
                    available: share,
                    textLines: textLines,
                    drawsMark: drawsMark,
                    maximum: widths.min() ?? 0
                )
            },
            height: { ringCellHeight(size: $0.figure, textLines: $0.textLines, drawsMark: $0.drawsMark) }
        )
        let lines = plans.map { plan in
            row(
                plan.rows.indices.map { index in
                    ringCell(
                        plan.rows[index],
                        size: plan.figure,
                        labelSize: 13,
                        width: plan.widths[index],
                        lines: plan.lines[index],
                        style: plan.styles[index],
                        logo: logoNode(plan.rows[index], snapshot: snapshot, size: EInkLogo.cellSize)
                    )
                },
                height: .points(
                    ringCellHeight(size: plan.figure, textLines: plan.textLines, drawsMark: plan.drawsMark)
                ),
                align: .start
            )
        }
        return screen(chrome.compose(lines), frame: frame, gap: gap)
    }

    // MARK: - Rail

    static func railCell(
        _ quota: EInkQuotaRow,
        barHeight: Int,
        width: Int,
        lines: [EInkSlotLineFragment],
        style: EInkSlotLabelStyle = .text,
        logo: EInkNode? = nil
    ) -> EInkNode {
        column(
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
            width: .points(width),
            height: .auto,
            gap: 2,
            align: .center
        ).module(slotModule(quota.fieldID))
    }

    /// A rail cell's height: the percentage, the bar, the mark and the label
    /// lines, with a 2 px gap between each.
    static func railCellHeight(bar: Int, textLines: Int, drawsMark: Bool) -> Int {
        let mark = drawsMark ? EInkLogo.cellSize : 0
        let children = 2 + (drawsMark ? 1 : 0) + textLines
        return 13 + bar + mark + textLines * 12 + 2 * max(0, children - 1)
    }

    /// The tallest bar the height allows.
    ///
    /// Every pixel the percentage, the mark and the labels did not take. Round
    /// 2 picked from a fixed list of heights (60 / 48 / 36 / 30, or 84 / 72 /
    /// 60 / 48 with no chrome), so a rail whose names had shrunk kept drawing
    /// the same bar with white under it; a slide with no header, no footer and
    /// nothing but marks now fills the panel.
    static func railBarHeight(available: Int, textLines: Int, drawsMark: Bool) -> Int {
        max(0, available - railCellHeight(bar: 0, textLines: textLines, drawsMark: drawsMark))
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
        let available = frame.height - 2 * margin - chrome.reserved
        let styleByField = styleMap(rows, snapshot: snapshot, options: options, size: EInkLogo.cellSize)
        let plan = centredRowPlan(
            rows,
            styleByField: styleByField,
            content: content,
            minimumCell: railCellMinimum,
            minimumFigure: 30,
            order: longestInMiddle
        ) { _, textLines, drawsMark in
            // No fixed height: the bar is whatever the chrome and the labels
            // left, which is the whole panel when a slide has neither.
            railBarHeight(available: available, textLines: textLines, drawsMark: drawsMark)
        }
        let cells = plan.rows.indices.map { index in
            railCell(
                plan.rows[index],
                barHeight: plan.figure,
                width: plan.widths[index],
                lines: plan.lines[index],
                style: plan.styles[index],
                logo: logoNode(plan.rows[index], snapshot: snapshot, size: EInkLogo.cellSize)
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
        let styleByField = styleMap(rows, snapshot: snapshot, options: options, size: EInkLogo.cellSize)
        // The demo drew three to a row on a 140 px panel. Three columns of a
        // three-tier name is 46 px each, so the row keeps as many cells as the
        // names can actually be drawn in and no more.
        let plans = centredRowGrid(
            rows,
            styleByField: styleByField,
            content: content,
            available: available,
            gap: gap,
            maxPerRow: 3,
            minimumCell: railCellMinimum,
            minimumFigure: 30,
            order: longestFirst,
            figure: { share, _, textLines, drawsMark in
                railBarHeight(available: share, textLines: textLines, drawsMark: drawsMark)
            },
            height: { railCellHeight(bar: $0.figure, textLines: $0.textLines, drawsMark: $0.drawsMark) }
        )
        let lines = plans.map { plan in
            row(
                plan.rows.indices.map { index in
                    railCell(
                        plan.rows[index],
                        barHeight: plan.figure,
                        width: plan.widths[index],
                        lines: plan.lines[index],
                        style: plan.styles[index],
                        logo: logoNode(plan.rows[index], snapshot: snapshot, size: EInkLogo.cellSize)
                    )
                },
                height: .points(
                    railCellHeight(bar: plan.figure, textLines: plan.textLines, drawsMark: plan.drawsMark)
                ),
                align: .end
            )
        }
        return screen(chrome.compose(lines), frame: frame, gap: gap)
    }

    /// Every slot's resolved style, keyed by field, so a row planned twice
    /// resolves each mark once.
    static func styleMap(
        _ rows: [EInkQuotaRow],
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions,
        size: Int
    ) -> [String: EInkSlotLabelStyle] {
        Dictionary(
            rows.map { ($0.fieldID, labelStyle($0, snapshot: snapshot, options: options, size: size)) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
