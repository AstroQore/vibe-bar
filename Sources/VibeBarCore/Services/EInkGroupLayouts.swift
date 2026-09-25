import Foundation

/// Layouts for a canvas made of several physical screens.
///
/// A combined group page is authored on one canvas — 592 × 152 for two
/// panels side by side, 296 × 304 for two stacked — but it is *shown* on
/// separate panels with a bezel between them. Round 1 laid every template out
/// as if the canvas were one very wide panel, which is how the owner's
/// two-screen Forecast came back with the names on the left panel, a column
/// of verdicts on the right one, every text box cut by the seam, and the rows
/// that did not fit the height piled on top of each other at the bottom edge.
///
/// Everything here works screen by screen instead. Each screen (a *pane*,
/// in canvas coordinates) gets a subtree of its own, drawn at the pane's own
/// size and clamped to the pane's own safe margin, so no box can cross the
/// bezel. What crosses it is the *selection*: one list of buckets, continued
/// from one screen to the next.
///
/// - A template with a list (the quota layouts, the usage tiles and split) is
///   *tiled*: every screen draws that template with its share of the list.
/// - The group templates (`headline`, `wideLedger`, `cards`) decide what
///   each screen draws.
/// - A template that is one picture (the heatmap, the trend, the harness
///   tables) still spans the canvas; `keepingTextOffSeams` then moves any text
///   box the seam would cut onto the screen its glyphs are on.
public enum EInkGroupLayouts {
    static let margin = EInkPresets.margin

    // MARK: - Panes

    /// Down the stack, then across the row — the order every group list reads
    /// its screens in (`EInkScreenGroup.orderedScreenIDs`).
    public static func readingOrder(_ panes: [EInkRect]) -> [EInkRect] {
        panes.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
    }

    /// Which way one pane is authored: portrait when it is taller than wide.
    static func shape(_ pane: EInkRect) -> EInkOrientation {
        pane.height > pane.width ? .degrees90 : .degrees0
    }

    /// The pane's own frame, at the origin, which is what every preset
    /// function lays itself out in.
    static func local(_ pane: EInkRect) -> EInkRect {
        EInkRect(x: 0, y: 0, width: pane.width, height: pane.height)
    }

    /// One screen's subtree, positioned on the canvas and clamped to the
    /// screen's own safe margin rather than to the canvas's.
    static func placed(_ node: EInkNode, in pane: EInkRect) -> EInkNode {
        var copy = node
        copy.origin = EInkPoint(x: pane.x, y: pane.y)
        copy.width = .points(pane.width)
        copy.height = .points(pane.height)
        copy.clampInset = margin
        return copy
    }

    static func canvas(_ children: [EInkNode], frame: EInkRect) -> EInkNode {
        EInkNode(.stack, width: .points(frame.width), height: .points(frame.height), children: children)
    }

    /// Whether a preset is laid out screen by screen on a multi-screen canvas.
    /// The rest span the canvas as one picture.
    public static func isPaneAware(_ preset: EInkPreset) -> Bool {
        switch preset.selectionAxis {
        case .quotaFields, .usagePeriods: preset != .alert
        case .harnessRows, .none: false
        }
    }

    // MARK: - Capacity

    /// How many items one page holds on these panes, or `nil` for a template
    /// that spans the canvas and keeps the area rule.
    public static func capacity(_ preset: EInkPreset, panes: [EInkRect]) -> Int? {
        guard panes.count > 1, isPaneAware(preset) else { return nil }
        let panes = readingOrder(panes)
        switch preset {
        case .headline:
            return heroCapacity(panes[0]) + panes.dropFirst().map(listCapacity).reduce(0, +)
        case .wideLedger:
            return wideRuns(panes).map { run in
                run.count == 2 ? wideCapacity(run[0]) : EInkPreset.quotaLedger.capacity(for: shape(run[0]))
            }.reduce(0, +)
        case .cards:
            return panes.map(cardsCapacity).reduce(0, +)
        default:
            return panes.map { preset.capacity(for: shape($0)) }.reduce(0, +)
        }
    }

    static func heroCapacity(_ pane: EInkRect) -> Int { 2 }

    /// The headline's compact list: a ledger that is allowed its sixth row.
    static func listCapacity(_ pane: EInkRect) -> Int { 6 }

    static func wideCapacity(_ pane: EInkRect) -> Int { 6 }

    static func cardsCapacity(_ pane: EInkRect) -> Int { 4 }

    // MARK: - Entry point

    /// The tree for a pane-aware preset on a multi-screen canvas, or `nil`
    /// when the preset spans the canvas (or there is only one screen).
    static func tree(
        _ preset: EInkPreset,
        slide: EInkSlide,
        snapshot: EInkDataSnapshot,
        frame: EInkRect,
        panes unordered: [EInkRect],
        calendar: Calendar,
        fieldIDs: [String]? = nil,
        periods: [EInkUsagePeriod]? = nil
    ) -> EInkNode? {
        guard unordered.count > 1, isPaneAware(preset),
              let capacity = capacity(preset, panes: unordered) else { return nil }
        let panes = readingOrder(unordered)
        let options = slide.options
        switch preset.selectionAxis {
        case .quotaFields:
            let rows = snapshot.quotaRows(fieldIDs: fieldIDs ?? slide.orderedQuotaFieldIDs, limit: capacity)
                .map { $0.relabeled(with: options) }
            switch preset {
            case .headline:
                return headline(rows, snapshot, frame: frame, panes: panes, options: options, calendar: calendar)
            case .wideLedger:
                return wideLedger(rows, snapshot, frame: frame, panes: panes, options: options, calendar: calendar)
            case .cards:
                let shares = distribute(rows, capacities: panes.map(cardsCapacity))
                return canvas(zip(panes, shares).map { pane, share in
                    placed(
                        cardsPane(share, snapshot, frame: local(pane),
                                  options: chromeOptions(options, pane: pane, panes: panes), calendar: calendar),
                        in: pane
                    )
                }, frame: frame)
            default:
                return tiledQuota(preset, rows, slide: slide, snapshot: snapshot, frame: frame, panes: panes,
                                  calendar: calendar)
            }
        case .usagePeriods:
            let chosen = periods ?? EInkRenderer.resolvedPeriods(slide, capacity: capacity)
            let shares = distribute(chosen, capacities: panes.map { preset.capacity(for: shape($0)) })
            return canvas(zip(panes, shares).map { pane, share in
                var paneSlide = slide
                paneSlide.options = chromeOptions(options, pane: pane, panes: panes)
                let node = share.isEmpty
                    ? emptyPane(local(pane), options: paneSlide.options, snapshot: snapshot)
                    : EInkRenderer.presetTree(preset, slide: paneSlide, orientation: shape(pane), snapshot: snapshot,
                                              frame: local(pane), calendar: calendar, periods: share)
                return placed(node, in: pane)
            }, frame: frame)
        case .harnessRows, .none:
            return nil
        }
    }

    // MARK: - Tiling

    /// The same template on every screen, the selection continued across
    /// them.
    static func tiledQuota(
        _ preset: EInkPreset,
        _ rows: [EInkQuotaRow],
        slide: EInkSlide,
        snapshot: EInkDataSnapshot,
        frame: EInkRect,
        panes: [EInkRect],
        calendar: Calendar
    ) -> EInkNode {
        var start = 0
        var children: [EInkNode] = []
        for (index, pane) in panes.enumerated() {
            var paneSlide = slide
            paneSlide.options = chromeOptions(slide.options, pane: pane, panes: panes)
            let remaining = rows.count - start
            let panesLeft = panes.count - index
            let following = panes[(index + 1)...].reduce(0) { $0 + preset.capacity(for: shape($1)) }
            var take = paneShare(remaining, capacity: preset.capacity(for: shape(pane)), following: following, panesLeft: panesLeft)
            // A ledger of long names holds fewer slots than its capacity, and
            // the ones it would drop belong on the next screen, not on the
            // next page.
            if preset == .quotaLedger, !shape(pane).isPortrait, take > 0 {
                take = min(take, EInkPresets.ledgerRowCount(
                    Array(rows[start..<(start + take)]),
                    frame: local(pane),
                    snapshot: snapshot,
                    options: paneSlide.options
                ))
            }
            let share = Array(rows[start..<(start + take)])
            start += take
            let node = share.isEmpty
                ? emptyPane(local(pane), options: paneSlide.options, snapshot: snapshot)
                : EInkRenderer.presetTree(
                    preset,
                    slide: paneSlide,
                    orientation: shape(pane),
                    snapshot: snapshot,
                    frame: local(pane),
                    calendar: calendar,
                    fieldIDs: share.map(\.fieldID)
                )
            children.append(placed(node, in: pane))
        }
        return canvas(children, frame: frame)
    }

    /// `remaining` items over `panes` screens, rounded up so the first
    /// screens are the fuller ones.
    static func evenShare(_ remaining: Int, _ panes: Int) -> Int {
        guard remaining > 0, panes > 0 else { return 0 }
        return (remaining + panes - 1) / panes
    }

    /// This screen's share: an even split for balance, but never so few
    /// that the screens after it — with their own capacities — could not
    /// hold the rest. A portrait pane of 8 next to a landscape pane of 4
    /// takes 8 of 12 rows, not 6, so the last two do not spill onto a page
    /// of their own.
    static func paneShare(_ remaining: Int, capacity: Int, following: Int, panesLeft: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(capacity, max(evenShare(remaining, panesLeft), remaining - following))
    }

    /// Items spread over screens: as even as the capacities allow, in order.
    static func distribute<T>(_ items: [T], capacities: [Int]) -> [[T]] {
        var result: [[T]] = []
        var start = 0
        for (index, capacity) in capacities.enumerated() {
            let following = capacities[(index + 1)...].reduce(0, +)
            let take = paneShare(items.count - start, capacity: capacity, following: following, panesLeft: capacities.count - index)
            result.append(Array(items[start..<(start + take)]))
            start += take
        }
        return result
    }

    /// A screen with nothing left to show: its bars, and paper.
    static func emptyPane(_ frame: EInkRect, options: EInkSlideOptions, snapshot: EInkDataSnapshot) -> EInkNode {
        let chrome = EInkPresets.chrome(
            options,
            defaults: EInkPresets.ChromeDefaults(
                right: "",
                footer: frame.height > frame.width
                    ? EInkPresets.usageFooterPortrait(snapshot)
                    : EInkPresets.usageFooter(snapshot)
            ),
            snapshot: snapshot,
            gap: 4
        )
        return EInkPresets.screen(chrome.compose([EInkPresets.verticalSpacer()]), frame: frame, gap: 4)
    }

    /// One screen's share of the slide's header and footer.
    ///
    /// The header reads as one bar across the screens along its edge: its
    /// left words on the first of them, its right words on the last. The
    /// footer closes the page, so it is drawn once, on the last screen.
    static func chromeOptions(_ options: EInkSlideOptions, pane: EInkRect, panes: [EInkRect]) -> EInkSlideOptions {
        var copy = options
        if var header = options.header {
            let bottom = header.position == .bottom
            let edge = bottom ? (panes.map(\.maxY).max() ?? 0) : (panes.map(\.y).min() ?? 0)
            let along = panes.filter { (bottom ? $0.maxY : $0.y) == edge }.sorted { $0.x < $1.x }
            if !along.contains(pane) {
                copy.header = nil
            } else if along.count > 1 {
                if pane != along.first { header.left = .none }
                if pane != along.last { header.right = .none }
                copy.header = header
            }
        }
        if options.footer != nil, pane != readingOrder(panes).last { copy.footer = nil }
        return copy
    }

    /// The ledger a group template continues its list in: the single-panel
    /// ledger, with its percentages held inside their rows.
    static func ledger(_ rows: [EInkQuotaRow], _ snapshot: EInkDataSnapshot, pane: EInkRect,
                       options: EInkSlideOptions) -> EInkNode {
        if rows.isEmpty { return emptyPane(local(pane), options: options, snapshot: snapshot) }
        return shape(pane).isPortrait
            ? EInkPresets.ledgerPortrait(rows, snapshot, frame: local(pane), options: options)
            : EInkPresets.ledgerLandscape(rows, snapshot, frame: local(pane), options: options, rowBoundFigures: true)
    }

    // MARK: - Headline

    static func headline(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        panes: [EInkRect],
        options: EInkSlideOptions,
        calendar: Calendar
    ) -> EInkNode {
        let hero = panes[0]
        let heroes = Array(rows.prefix(heroCapacity(hero)))
        let listPanes = Array(panes.dropFirst())
        let shares = distribute(Array(rows.dropFirst(heroes.count)), capacities: listPanes.map(listCapacity))
        var children = [
            placed(heroPane(heroes, snapshot, frame: local(hero), options: options, calendar: calendar), in: hero)
        ]
        for (pane, share) in zip(listPanes, shares) {
            var paneSlide = EInkSlide(kind: .preset(.quotaLedger))
            paneSlide.options = chromeOptions(options, pane: pane, panes: listPanes)
            children.append(placed(ledger(share, snapshot, pane: pane, options: paneSlide.options), in: pane))
        }
        return canvas(children, frame: frame)
    }

    /// Up to two buckets, large: the name, the figure in 32 px, the verdict
    /// and the reset beside it, and a thick bar with the forecast tick.
    ///
    /// Carries no header: the screen *is* the headline, and the list screens
    /// carry the bar.
    static func heroPane(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions,
        calendar: Calendar
    ) -> EInkNode {
        let gap = 8
        let slots = 2
        let content = frame.width - 2 * margin
        let available = frame.height - 2 * margin
        let blockHeight = (available - gap * (slots - 1)) / slots
        let blocks = rows.prefix(slots).map {
            heroBlock($0, snapshot, width: content, height: blockHeight, options: options, calendar: calendar)
        }
        return EInkPresets.screen(blocks + [EInkPresets.verticalSpacer()], frame: frame, gap: gap)
    }

    static func heroBlock(
        _ quota: EInkQuotaRow,
        _ snapshot: EInkDataSnapshot,
        width: Int,
        height: Int,
        options: EInkSlideOptions,
        calendar: Calendar
    ) -> EInkNode {
        let pixel = EInkPresets.pixel
        let bold = EInkPresets.pixelBold
        let wide = width >= 200
        let style = EInkPresets.labelStyle(quota, snapshot: snapshot, options: options, size: EInkLogo.rowSize)
        let mark = style.drawsLogo ? EInkPresets.logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize) : nil
        let markWidth = mark == nil ? 0 : EInkLogo.rowSize + 4
        let words = mark == nil ? quota.slotLabel : style.text(of: quota)
        let verdict = quota.forecast?.word
        let verdictWidth = verdict.map { EInkTextMetrics.width($0, font: pixel) + EInkSlotLabel.measurementSlack } ?? 0
        let resets = quota.countdown.isEmpty ? "" : "resets in \(quota.countdown)"
        let runsOut = quota.forecast?.runOutAt.map { "runs out \(EInkFormat.clockLabel($0, calendar: calendar))" }

        // The verdict shares the name's line when both fit; otherwise the
        // name takes the whole line (and a second one if it needs it) and the
        // verdict joins the figures.
        let beside = wide ? max(0, width - markWidth - (verdict == nil ? 0 : verdictWidth + 4)) : 0
        let oneLine = wide && EInkSlotLabel.fits(words, width: beside, font: bold)
        let nameLines: [String] = words.isEmpty
            ? []
            : (oneLine
                ? [words]
                : EInkSlotLabel.wrapped(words, width: width - markWidth, font: bold, maxLines: wide ? 2 : 3))
        let verdictBeside = oneLine && verdict != nil

        let headHeight = mark == nil ? 12 : EInkLogo.rowSize
        var notes: [String] = []
        if !verdictBeside, let verdict { notes.append(verdict) }
        if !resets.isEmpty { notes.append(resets) }
        if let runsOut { notes.append(runsOut) }

        func build(big: Int, noteCount: Int) -> [EInkNode] {
            let barHeight = big >= 32 ? 14 : 12
            var children: [EInkNode] = []
            // The name, with the mark in front of its first line.
            var head: [EInkNode] = mark.map { [$0] } ?? []
            head.append(
                EInkPresets.text(nameLines.first ?? "", bold, width: .flex(1), clips: true)
                    .bound(nameLines.count == 1 ? .quota(quota.fieldID, .label) : nil)
            )
            if verdictBeside, let verdict {
                head.append(EInkPresets.text(verdict, pixel, width: .points(verdictWidth), align: .trailing))
            }
            children.append(EInkPresets.row(head, height: .points(headHeight), gap: 4, align: .center))
            for line in nameLines.dropFirst() {
                children.append(EInkPresets.text(line, bold, width: .flex(1), height: .points(12), clips: true))
            }
            // The figure, and what the bucket is doing.
            let percent = EInkPresets.text("\(quota.remainingPercent)%", EInkPresets.sans(big))
                .bound(.quota(quota.fieldID, .percent))
            let shown = Array(notes.prefix(noteCount))
            if wide {
                let column = EInkPresets.column(
                    shown.map { note in
                        EInkPresets.text(note, pixel, width: .flex(1), height: .points(12), align: .trailing)
                            .bound(note == resets ? .quota(quota.fieldID, .countdown) : nil)
                    },
                    width: .flex(1),
                    gap: 1,
                    justify: .center
                )
                children.append(EInkPresets.row([percent, column], height: .points(big), gap: 6, align: .center))
            } else {
                // A portrait screen is too narrow for both: the notes go under.
                children.append(EInkPresets.row([percent], height: .points(big), align: .center))
                for note in shown {
                    children.append(
                        EInkPresets.text(note, note == verdict ? bold : pixel, width: .flex(1), height: .points(12))
                            .bound(note == resets ? .quota(quota.fieldID, .countdown) : nil)
                    )
                }
            }
            children.append(EInkPresets.forecastBar(quota, width: width, height: barHeight))
            return children
        }
        func total(_ nodes: [EInkNode]) -> Int {
            nodes.map(EInkBoxLayout.intrinsicHeight).reduce(0, +) + 2 * max(0, nodes.count - 1)
        }
        // Largest figure first; what gives way is the figure's size, then the
        // notes from the bottom — never the name, the figure or the bar.
        var candidates: [(big: Int, notes: Int)] = []
        for big in (nameLines.count > 1 && wide ? [24, 18] : [32, 24, 18]) {
            let most = wide ? min(notes.count, (big + 1) / 13) : notes.count
            for count in stride(from: most, through: 0, by: -1) { candidates.append((big, count)) }
        }
        let chosen = candidates.first { total(build(big: $0.big, noteCount: $0.notes)) <= height }
            ?? candidates.last ?? (18, 0)
        let children = build(big: chosen.big, noteCount: chosen.notes)
        return EInkPresets.column(children, height: .points(height), gap: 2)
            .module(EInkPresets.slotModule(quota.fieldID))
    }

    // MARK: - Wide ledger

    /// Landscape screens side by side, taken two at a time. A screen with no
    /// partner — the third of three, any screen in a stack, or a portrait
    /// screen, whose 140 px cannot hold a name or a bar worth widening — draws
    /// a ledger of its own.
    static func wideRuns(_ panes: [EInkRect]) -> [[EInkRect]] {
        var rows: [[EInkRect]] = []
        for pane in readingOrder(panes) {
            if let last = rows.last?.last, !shape(pane).isPortrait, !shape(last).isPortrait,
               last.y == pane.y, last.height == pane.height, last.maxX == pane.x {
                rows[rows.count - 1].append(pane)
            } else {
                rows.append([pane])
            }
        }
        return rows.flatMap { row in
            stride(from: 0, to: row.count, by: 2).map { Array(row[$0..<min($0 + 2, row.count)]) }
        }
    }

    static func wideLedger(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        panes: [EInkRect],
        options: EInkSlideOptions,
        calendar: Calendar
    ) -> EInkNode {
        let runs = wideRuns(panes)
        let capacities = runs.map { $0.count == 2 ? wideCapacity($0[0]) : EInkPreset.quotaLedger.capacity(for: shape($0[0])) }
        var children: [EInkNode] = []
        var start = 0
        for (index, run) in runs.enumerated() {
            let following = capacities[(index + 1)...].reduce(0, +)
            let take = paneShare(rows.count - start, capacity: capacities[index], following: following, panesLeft: runs.count - index)
            let share = Array(rows[start..<(start + take)])
            start += take
            if run.count == 2 {
                let pair = widePair(share, snapshot, left: run[0], right: run[1], options: options,
                                    panes: panes, calendar: calendar)
                children.append(placed(pair.left, in: run[0]))
                children.append(placed(pair.right, in: run[1]))
            } else {
                let pane = run[0]
                let paneOptions = chromeOptions(options, pane: pane, panes: panes)
                children.append(placed(ledger(share, snapshot, pane: pane, options: paneOptions), in: pane))
            }
        }
        return canvas(children, frame: frame)
    }

    /// One ledger read across two screens.
    ///
    /// Both halves are laid out on the same rows — the same header height,
    /// the same footer height (the left screen reserves what the right one
    /// prints), the same slot heights — so a row that starts with a name on
    /// the left panel ends with its bar at exactly the same height on the
    /// right one.
    static func widePair(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        left: EInkRect,
        right: EInkRect,
        options: EInkSlideOptions,
        panes: [EInkRect],
        calendar: Calendar
    ) -> (left: EInkNode, right: EInkNode) {
        let gap = 4
        let pixel = EInkPresets.pixel
        let bold = EInkPresets.pixelBold
        let leftOptions = chromeOptions(options, pane: left, panes: panes)
        let rightOptions = chromeOptions(options, pane: right, panes: panes)

        // Bars: both screens carry a header row when either has words for
        // it, so the rows below start at the same height on both.
        var headers: (left: EInkNode?, right: EInkNode?) = (nil, nil)
        var headerAtBottom = false
        let defaults = EInkPresets.ChromeDefaults(right: "QUOTA LEFT · \(snapshot.generatedAtLabel)")
        if let bar = options.header {
            let leftWords = leftOptions.header.map { EInkPresets.barText($0.left, default: defaults.left, snapshot: snapshot) } ?? ""
            let rightWords = rightOptions.header.map { EInkPresets.barText($0.right, default: defaults.right, snapshot: snapshot) } ?? ""
            if !leftWords.isEmpty || !rightWords.isEmpty {
                headers = (
                    EInkPresets.header(leftWords, "", leftBinding: EInkPresets.binding(for: bar.left))
                        .module(EInkPresets.headerModule),
                    EInkPresets.header("", rightWords, rightBinding: EInkPresets.binding(for: bar.right))
                        .module(EInkPresets.headerModule)
                )
                headerAtBottom = bar.position == .bottom
            }
        }
        let footer = rightOptions.footer.flatMap {
            EInkPresets.footerNode(
                $0.content,
                defaults: EInkPresets.ChromeDefaults(right: "", footer: EInkPresets.usageFooter(snapshot)),
                snapshot: snapshot
            )
        }
        let footerHeight = footer.map(EInkBoxLayout.intrinsicHeight) ?? 0
        let reserved = (headers.left == nil ? 0 : 14 + gap) + (footer == nil ? 0 : footerHeight + gap)
        let height = min(left.height, right.height)
        let available = height - 2 * margin - reserved
        let leftContent = left.width - 2 * margin
        let rightContent = right.width - 2 * margin

        // The left screen: the name in full and the percentage.
        let styles = rows.map { EInkPresets.labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.rowSize) }
        let logoWidth = styles.contains(where: \.drawsLogo) ? EInkLogo.rowSize + 5 : 0
        let percentWidth = 34
        let nameWidth = max(0, leftContent - logoWidth - percentWidth - 5)
        let names: [[String]] = zip(rows, styles).map { quota, style in
            let words = style.drawsLogo ? style.text(of: quota) : quota.slotLabel
            guard !words.isEmpty else { return [""] }
            if EInkSlotLabel.fits(words, width: nameWidth, font: bold) { return [words] }
            return EInkSlotLabel.wrapped(words, width: nameWidth, font: bold, maxLines: 2)
        }
        let fitted = EInkPresets.fittedSlotHeights(
            units: names.map { max(1, $0.count) },
            available: available,
            gap: gap,
            preferred: options.compact ? 1_000 : 18,
            minimum: 13
        )
        let unit = fitted.unit

        // The right screen: the bar, the countdown and the verdict.
        let countdownWidth = max(
            42,
            (rows.map { EInkTextMetrics.width($0.countdown, font: pixel) }.max() ?? 0) + EInkSlotLabel.measurementSlack
        )
        let verdicts = rows.compactMap { $0.forecast?.word }
        let verdictWidth = verdicts.isEmpty
            ? 0
            : (verdicts.map { EInkTextMetrics.width($0, font: pixel) }.max() ?? 0) + EInkSlotLabel.measurementSlack

        var leftSlots: [EInkNode] = []
        var rightSlots: [EInkNode] = []
        for index in 0..<min(fitted.count, rows.count) {
            let quota = rows[index]
            let lines = names[index]
            let span = max(1, lines.count)
            let mark: [EInkNode] = logoWidth > 0
                ? [
                    (styles[index].drawsLogo ? EInkPresets.logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize) : nil)
                        ?? EInkPresets.spacer(.points(EInkLogo.rowSize))
                ]
                : []
            let first = EInkPresets.row(
                mark + [
                    EInkPresets.text(lines.first ?? "", bold, width: .points(nameWidth), clips: true)
                        .bound(lines.count == 1 ? .quota(quota.fieldID, .label) : nil),
                    // Held to the row, and never clipped: a 13 px row keeps the
                    // 14 px figure's box off the line under it.
                    EInkPresets.text("\(quota.remainingPercent)%", EInkPresets.sans(14), width: .points(percentWidth),
                                     height: .points(unit), align: .trailing, clips: false)
                        .bound(.quota(quota.fieldID, .percent))
                ],
                height: .points(unit),
                gap: 5,
                align: .center
            )
            let rest = lines.dropFirst().map {
                EInkPresets.row(
                    [EInkPresets.spacer(.points(logoWidth > 0 ? logoWidth - 5 : 0)),
                     EInkPresets.text($0, bold, width: .points(nameWidth), clips: true)],
                    height: .points(unit),
                    gap: logoWidth > 0 ? 5 : 0,
                    align: .center
                )
            }
            leftSlots.append(
                EInkPresets.column([first] + rest, height: .points(unit * span), gap: 0)
                    .module(EInkPresets.slotModule(quota.fieldID))
            )

            var figures: [EInkNode] = [
                EInkPresets.forecastBar(quota, width: max(EInkPresets.barMinimumWidth,
                    rightContent - countdownWidth - (verdictWidth > 0 ? verdictWidth + 5 : 0) - 5), height: 10),
                EInkPresets.text(quota.countdown, pixel, width: .points(countdownWidth), align: .trailing)
                    .bound(.quota(quota.fieldID, .countdown))
            ]
            if verdictWidth > 0 {
                figures.append(EInkPresets.text(quota.forecast?.word ?? "", pixel, width: .points(verdictWidth), align: .trailing))
            }
            rightSlots.append(
                EInkPresets.column(
                    [EInkPresets.row(figures, height: .points(unit), gap: 5, align: .center)],
                    height: .points(unit * span),
                    gap: 0
                ).module(EInkPresets.slotModule(quota.fieldID))
            )
        }

        func compose(_ header: EInkNode?, _ body: [EInkNode], _ bottom: EInkNode?) -> [EInkNode] {
            var children: [EInkNode] = []
            if let header, !headerAtBottom { children.append(header) }
            children.append(EInkPresets.column(body, height: .flex(1), gap: gap))
            if let bottom { children.append(bottom) }
            if let header, headerAtBottom { children.append(header) }
            return children
        }
        let reserve = footer.map { _ in EInkNode(.row, width: .flex(1), height: .points(footerHeight)) }
        return (
            EInkPresets.screen(compose(headers.left, leftSlots, reserve), frame: local(left), gap: gap),
            EInkPresets.screen(compose(headers.right, rightSlots, footer?.module(EInkPresets.footerModule)),
                               frame: local(right), gap: gap)
        )
    }

    // MARK: - Cards

    /// A grid of cards, one bucket each: two across a landscape screen, one
    /// across a portrait one, split by a cross of rules.
    static func cardsPane(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        options: EInkSlideOptions,
        calendar: Calendar
    ) -> EInkNode {
        let gap = 3
        let portrait = frame.height > frame.width
        let chrome = EInkPresets.chrome(
            options,
            defaults: EInkPresets.ChromeDefaults(
                right: portrait ? snapshot.generatedAtLabel : "QUOTA LEFT · \(snapshot.generatedAtLabel)",
                footer: portrait ? EInkPresets.usageFooterPortrait(snapshot) : EInkPresets.usageFooter(snapshot)
            ),
            snapshot: snapshot,
            gap: gap
        )
        let content = frame.width - 2 * margin
        let available = frame.height - 2 * margin - chrome.reserved
        // Always the whole grid, so a screen with two cards draws them the
        // same size as its neighbour with four.
        let columns = content >= 200 ? 2 : 1
        let lines = cardsCapacity(frame) / columns
        // A rule with four pixels of paper either side, between every two
        // cards in both directions.
        let ruleSpan = 1 + 2 * 4
        let cellWidth = (content - (columns - 1) * ruleSpan) / columns
        let cellHeight = (available - (lines - 1) * ruleSpan) / lines
        let cells = Array(rows.prefix(columns * lines))

        var gridRows: [EInkNode] = []
        for line in 0..<lines {
            var items: [EInkNode] = []
            for column in 0..<columns {
                let index = line * columns + column
                if column > 0 {
                    items.append(EInkPresets.spacer(.points(4)))
                    items.append(EInkNode(.fill, width: .points(1), height: .flex(1)))
                    items.append(EInkPresets.spacer(.points(4)))
                }
                items.append(
                    cells.indices.contains(index)
                        ? card(cells[index], snapshot, width: cellWidth, height: cellHeight, options: options)
                        : EInkPresets.spacer(.points(cellWidth))
                )
            }
            if line > 0 {
                gridRows.append(EInkNode(.row, width: .flex(1), height: .points(4)))
                gridRows.append(EInkPresets.rule())
                gridRows.append(EInkNode(.row, width: .flex(1), height: .points(4)))
            }
            gridRows.append(EInkPresets.row(items, height: .points(cellHeight)))
        }
        return EInkPresets.screen(
            chrome.compose([EInkPresets.column(gridRows, height: .flex(1), gap: 0)]),
            frame: frame,
            gap: gap
        )
    }

    /// One card: the name (on two lines when it has the room), the figure and
    /// the countdown, and a bar with the forecast tick.
    static func card(
        _ quota: EInkQuotaRow,
        _ snapshot: EInkDataSnapshot,
        width: Int,
        height: Int,
        options: EInkSlideOptions
    ) -> EInkNode {
        let pixel = EInkPresets.pixel
        let bold = EInkPresets.pixelBold
        let style = EInkPresets.labelStyle(quota, snapshot: snapshot, options: options, size: EInkLogo.rowSize)
        let mark = style.drawsLogo ? EInkPresets.logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize) : nil
        let markWidth = mark == nil ? 0 : EInkLogo.rowSize + 4
        let words = mark == nil ? quota.slotLabel : style.text(of: quota)
        let headHeight = mark == nil ? 12 : EInkLogo.rowSize
        let barHeight = 8
        // The figure is as large as the card allows once the name has its
        // lines: 18 px when there is room, 14 when there is not.
        func figureSize(_ nameLines: Int) -> Int? {
            let fixed = headHeight + 12 * max(0, nameLines - 1) + barHeight + 2 * 2
            if fixed + 18 <= height { return 18 }
            if fixed + 14 <= height { return 14 }
            return nil
        }
        let wrapped = words.isEmpty ? [] : EInkSlotLabel.wrapped(words, width: width - markWidth, font: bold, maxLines: 2)
        let nameLines: [String]
        if wrapped.count > 1, figureSize(wrapped.count) != nil {
            nameLines = wrapped
        } else {
            // One line: the whole name when it fits, and the one truncation
            // the panel allows when a card's whole width cannot hold it.
            nameLines = words.isEmpty ? [] : [EInkSlotLabel.truncated(words, width: width - markWidth, font: bold)]
        }
        let figure = figureSize(nameLines.count) ?? 14

        var head: [EInkNode] = mark.map { [$0] } ?? []
        head.append(
            EInkPresets.text(nameLines.first ?? "", bold, width: .flex(1), clips: true)
                .bound(nameLines.count == 1 && !EInkSlotLabel.isTruncated(nameLines[0]) ? .quota(quota.fieldID, .label) : nil)
        )
        var children = [EInkPresets.row(head, height: .points(headHeight), gap: 4, align: .center)]
        for line in nameLines.dropFirst() {
            children.append(EInkPresets.text(line, bold, width: .flex(1), height: .points(12), clips: true))
        }
        children.append(
            EInkPresets.row(
                [
                    EInkPresets.text("\(quota.remainingPercent)%", EInkPresets.sans(figure))
                        .bound(.quota(quota.fieldID, .percent)),
                    EInkPresets.text(quota.countdown, pixel, width: .flex(1), align: .trailing)
                        .bound(.quota(quota.fieldID, .countdown))
                ],
                height: .points(figure),
                gap: 4,
                align: .center
            )
        )
        children.append(EInkPresets.forecastBar(quota, width: width, height: barHeight))
        children.append(EInkPresets.verticalSpacer())
        return EInkPresets.column(children, width: .points(width), height: .points(height), gap: 2)
            .module(EInkPresets.slotModule(quota.fieldID))
    }

    // MARK: - Templates that span the canvas

    /// Moves every text box the seam would cut onto the one screen its glyphs
    /// are on.
    ///
    /// For the templates that are one picture across the screens — the
    /// heatmap, the trend, the harness tables — where a bar crossing the bezel
    /// still reads as a bar but a word crossing it does not. A flexed header
    /// label 527 px wide whose right-aligned words sit on the right panel
    /// becomes a box on the right panel only; a label whose glyphs straddle
    /// the seam is nudged wholly onto the side that held more of it.
    public static func keepingTextOffSeams(_ boxes: [EInkDrawBox], panes: [EInkRect]) -> [EInkDrawBox] {
        guard panes.count > 1 else { return boxes }
        return boxes.map { box in
            guard case let .text(value, font, alignment) = box.content,
                  panes.filter({ overlap(box.frame, $0) > 0 }).count > 1 else { return box }
            let measured = EInkTextMetrics.width(value, font: font) + EInkSlotLabel.measurementSlack
            let width = min(box.frame.width, measured)
            let x: Int
            switch alignment {
            case .leading: x = box.frame.x
            case .trailing: x = box.frame.maxX - width
            case .center: x = box.frame.x + (box.frame.width - width) / 2
            }
            let glyphs = EInkRect(x: x, y: box.frame.y, width: width, height: box.frame.height)
            guard let target = panes.max(by: { overlap(glyphs, $0) < overlap(glyphs, $1) }) else { return box }
            let safe = target.inset(by: EInkInsets(all: margin))
            var copy = box
            copy.frame = EInkBoxLayout.clamp(glyphs, to: safe)
            return copy
        }
    }

    static func overlap(_ a: EInkRect, _ b: EInkRect) -> Int {
        let width = min(a.maxX, b.maxX) - max(a.x, b.x)
        let height = min(a.maxY, b.maxY) - max(a.y, b.y)
        return width > 0 && height > 0 ? width * height : 0
    }
}
