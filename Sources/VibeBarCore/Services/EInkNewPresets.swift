import Foundation

// The round 2 layouts: Briefing, Forecast, Resets, Heatmap, Top Models, and
// the engine's own Alert.
//
// They exist because the owner's review of round 1 said the panel was showing
// him numbers he already knew. Each one answers a question instead: what is
// the state of everything (Briefing), am I on pace (Forecast), when does
// anything come back (Resets), when do I actually work (Heatmap), what is the
// money going on (Top Models).
extension EInkPresets {
    // MARK: - Shared pieces

    /// How much of a slot's figures the row can afford beside its name.
    ///
    /// Three widths rather than two: a panel showing six buckets from six
    /// different SubProviders has names 270 px long, and spending the whole
    /// row on "on pace 59%" leaves the reader looking at a column of truncated
    /// names — which is the exact complaint round 2 exists to fix.
    enum BriefingDetail: CaseIterable {
        /// "67% left · resets in 5d 03h · on pace 59%"
        case full
        /// "67% · 5d 03h · pace 59%"
        case terse
        /// "67% · 5d 03h"
        case figuresOnly
    }

    static func briefingStats(_ quota: EInkQuotaRow, detail: BriefingDetail) -> String {
        var parts: [String] = []
        parts.append(detail == .full ? "\(quota.remainingPercent)% left" : "\(quota.remainingPercent)%")
        if !quota.countdown.isEmpty {
            parts.append(detail == .full ? "resets in \(quota.countdown)" : quota.countdown)
        }
        if detail != .figuresOnly, let forecast = quota.forecast {
            let pace = Int(forecast.projectedUsedPercent.rounded())
            parts.append(detail == .full ? "on pace \(pace)%" : "pace \(pace)%")
        }
        return parts.joined(separator: " · ")
    }

    /// "Today $427 · 538M tokens · 1,848 requests".
    static func briefingTodayLine(_ snapshot: EInkDataSnapshot) -> String {
        let today = snapshot.usage.today
        return "Today \(EInkFormat.money(today.costUSD)) · \(EInkFormat.tokens(today.tokens)) tokens"
            + " · \(EInkFormat.int(today.requests)) requests"
    }

    /// "7 days $6,169 · busiest 09-09 $1,486".
    static func briefingWeekLine(_ snapshot: EInkDataSnapshot) -> String {
        let week = snapshot.usage.week
        var line = "7 days \(EInkFormat.money(week.costUSD))"
        if let busiest = snapshot.trend.max(by: { $0.costUSD < $1.costUSD }), busiest.costUSD > 0 {
            line += " · busiest \(busiest.dayLabel) \(EInkFormat.money(busiest.costUSD))"
        }
        return line
    }

    // MARK: - Briefing

    static func briefing(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        portrait: Bool,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = portrait ? 3 : 2
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: portrait ? snapshot.generatedAtLabel : "BRIEFING · \(snapshot.generatedAtLabel)"
            ),
            snapshot: snapshot,
            gap: gap
        )
        let content = frame.width - 2 * margin
        var children: [EInkNode] = []
        /// Landscape only: whether a name forced the two-line row.
        var wrapped = false

        if portrait {
            // 140 px cannot hold a name and its figures on one line, so each
            // slot gets two: the name, then what it is doing. A name that will
            // not fit even a line of its own takes as many as it needs — round
            // 1 drew it at 284 px inside a 140 px box and let the panel cut it.
            let styles = rows.map { labelStyle($0, snapshot: snapshot, options: options, size: EInkLogo.rowSize) }
            let lines = zip(rows, styles).map { quota, style in
                style.drawsLogo
                    ? labelFragments(
                        // The mark shares the first line, so the words are
                        // wrapped to what is left of it.
                        EInkSlotLabel.wrapped(
                            style.text(of: quota),
                            width: content - EInkLogo.rowSize - 4,
                            maxLines: 2
                        ),
                        quota: quota
                    )
                    : labelLines(quota, width: content, maxLines: 3)
            }
            // The two usage lines and the rule above them are the footer this
            // layout builds by hand, and the slots only get what is left.
            let footer = 1 + 2 * 13 + 3 * gap
            let budget = frame.height - 2 * margin - chrome.reserved - footer
            var kept = rows.count
            func height(_ index: Int) -> Int {
                (lines[index].count + 1) * 12 + 1 + (styles[index].drawsLogo ? EInkLogo.rowSize - 12 : 0)
            }
            while kept > 1,
                  (0..<kept).map(height).reduce(0, +) + gap * (kept - 1) > budget { kept -= 1 }
            for (index, quota) in rows.prefix(kept).enumerated() {
                let named = lines[index].map {
                    labelFragment(
                        $0,
                        fieldID: quota.fieldID,
                        width: .flex(1),
                        height: .points(12),
                        font: pixelBold,
                        clips: true
                    )
                }
                let head: [EInkNode] = styles[index].drawsLogo
                    ? [
                        row(
                            [logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize)].compactMap { $0 }
                                + (named.first.map { [$0] } ?? []),
                            height: .points(EInkLogo.rowSize),
                            gap: 4,
                            align: .center
                        )
                    ] + Array(named.dropFirst())
                    : named
                children.append(
                    column(
                        head + [
                            text(briefingStats(quota, detail: .terse), pixel, width: .flex(1), height: .points(12))
                        ],
                        height: .points(height(index)),
                        gap: 1
                    ).module(slotModule(quota.fieldID))
                )
            }
        } else {
            // One line per slot, with the figures in a column of their own —
            // until a name will not fit beside them, at which point the row
            // wraps into the portrait form rather than cutting the name.
            //
            // Both halves are *fixed* width on purpose. An auto-width name
            // beside a right-aligned figure is exactly how the first hardware
            // push came back with "GPT-5.3 Codex Spark" printed through its
            // own percentage: the name outran the row and the flexed figure
            // had nowhere left to start. Plus slack, and the figures never
            // clip: `EInkTextMetrics` is an estimate of the device's font, and
            // the first hardware push came back with "67%" printed as "7%" — a
            // clipped number is a wrong number, so a figure that outruns its
            // box spills instead of being cut.
            //
            // What round 2 changes is the other column. Round 1 let the name
            // clip once it outgrew its half of the row, which is what put
            // "ChatGPT Agentic · GPT-5.3 Code…" on the owner's panel. A name
            // that does not fit now takes a line of its own — the layout gives
            // up a row, not a word.
            func statsWidth(_ detail: BriefingDetail) -> Int {
                min(
                    content - 60,
                    (rows.map { EInkTextMetrics.width(briefingStats($0, detail: detail), font: pixel) }.max() ?? 0) + 10
                )
            }
            let widestLabel = rows.map { EInkTextMetrics.width($0.slotLabel, font: pixelBold) }.max() ?? 0
            // Every name, not the median one: half the panel reading correctly
            // is still half a panel of cut names.
            let detail = BriefingDetail.allCases.first {
                content - statsWidth($0) - 6 >= widestLabel + EInkSlotLabel.measurementSlack
            }
            if let detail {
                let statsColumn = statsWidth(detail)
                let labelWidth = max(0, content - statsColumn - 6)
                for quota in rows {
                    let style = labelStyle(quota, snapshot: snapshot, options: options, size: EInkLogo.rowSize)
                    let mark = style.drawsLogo ? logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize) : nil
                    let words = style.drawsLogo ? style.text(of: quota) : quota.slotLabel
                    children.append(
                        row(
                            [mark].compactMap { $0 } + [
                                text(
                                    words,
                                    pixelBold,
                                    width: .points(labelWidth - (mark == nil ? 0 : EInkLogo.rowSize + 6)),
                                    clips: false
                                ).bound(.slotLabel(quota.fieldID, part: style.part ?? .whole)),
                                text(
                                    briefingStats(quota, detail: detail),
                                    pixel,
                                    width: .points(statsColumn),
                                    align: .trailing,
                                    clips: false
                                )
                            ],
                            height: .points(13),
                            gap: 6,
                            align: .center
                        ).module(slotModule(quota.fieldID))
                    )
                }
            } else {
                wrapped = true
                // A name too long even for a whole row breaks where it reads —
                // the same SubProvider / group · window split the rings and the
                // rail have always used. The figures stay beside the first
                // line, which leaves the whole width of the panel for the
                // second: two lines is the budget, and nothing is cut.
                let statsColumn = statsWidth(.terse)
                let firstWidth = max(0, content - statsColumn - 6)
                for quota in rows {
                    let parts = EInkSlotLabel.twoLines(quota.slotLabel)
                    let first = row(
                        [
                            text(
                                EInkSlotLabel.truncated(parts.first, width: firstWidth, font: pixelBold),
                                pixelBold,
                                width: .points(firstWidth),
                                clips: true
                            ).bound(.slotLabel(quota.fieldID, part: .name)),
                            text(
                                briefingStats(quota, detail: .terse),
                                pixel,
                                width: .points(statsColumn),
                                align: .trailing,
                                clips: false
                            )
                        ],
                        height: .points(12),
                        gap: 6
                    )
                    children.append(
                        column(
                            [
                                first,
                                // The second fragment says which part of the
                                // name it is, so exploding the slide into the
                                // Studio leaves it following the bucket rather
                                // than freezing it as text.
                                text(
                                    EInkSlotLabel.truncated(parts.second, width: content),
                                    pixel,
                                    width: .points(content),
                                    height: .points(12),
                                    clips: true
                                ).bound(.slotLabel(quota.fieldID, part: .window))
                            ],
                            height: .points(24),
                            gap: 0
                        ).module(slotModule(quota.fieldID))
                    )
                }
            }
        }

        children.append(verticalSpacer())
        children.append(rule())
        children.append(
            text(briefingTodayLine(snapshot), pixel, width: .flex(1), height: .points(13))
                .module(footerModule)
        )
        // The week's line is the first thing the wrapped landscape form gives
        // up: two 24 px rows cost exactly what it does, and four slots with
        // their names intact is the panel the owner asked for. Portrait has
        // the height for both.
        if portrait || !wrapped {
            children.append(
                text(briefingWeekLine(snapshot), pixel, width: .flex(1), height: .points(13))
                    .module(footerModule)
            )
        }
        return screen(chrome.compose(children), frame: frame, gap: gap)
    }

    // MARK: - Forecast

    /// One bar with the projected-use tick standing in it.
    ///
    /// The bar shows quota *left*, so the tick sits where the bar is expected
    /// to end up at reset: `100 − projected`. A hollow marker rather than a
    /// second fill, because the two numbers are different kinds of thing —
    /// one is measured, one is a guess.
    static func forecastBar(_ quota: EInkQuotaRow, width: Int, height: Int) -> EInkNode {
        var children: [EInkNode] = [
            EInkNode(
                .horizontalBar(percent: quota.remainingPercent),
                width: .points(width),
                height: .points(height),
                origin: EInkPoint(x: 0, y: 0),
                binding: .quota(quota.fieldID, .percent)
            )
        ]
        if let forecast = quota.forecast {
            let left = max(0, 100 - forecast.projectedTickPercent)
            let x = min(width - 2, max(1, EInkBoxLayout.fillLength(width - 2, percent: left)))
            children.append(
                EInkNode(.fill, width: .points(1), height: .points(height), origin: EInkPoint(x: x, y: 0))
            )
        }
        return EInkNode(.stack, width: .points(width), height: .points(height), children: children)
    }

    /// The slot's name on a forecast row: its mark and what the style left,
    /// or the whole name truncated to the column it has.
    static func forecastName(
        _ quota: EInkQuotaRow,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions,
        width: Int
    ) -> EInkNode {
        let style = labelStyle(quota, snapshot: snapshot, options: options, size: EInkLogo.rowSize)
        guard style.drawsLogo, let mark = logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize) else {
            return text(
                EInkSlotLabel.truncated(quota.slotLabel, width: width, font: pixelBold),
                pixelBold,
                width: .points(width),
                clips: true
            ).bound(.quota(quota.fieldID, .label))
        }
        let words = max(0, width - EInkLogo.rowSize - 4)
        return row(
            [
                mark,
                text(
                    EInkSlotLabel.truncated(style.text(of: quota), width: words, font: pixelBold),
                    pixelBold,
                    width: .points(words),
                    clips: true
                ).bound(style.part.map { .slotLabel(quota.fieldID, part: $0) })
            ],
            width: .points(width),
            height: .points(EInkLogo.rowSize),
            gap: 4,
            align: .center
        )
    }

    static func forecastRunOutText(_ quota: EInkQuotaRow, calendar: Calendar) -> String {
        if let runOutAt = quota.forecast?.runOutAt {
            return "runs out \(EInkFormat.clockLabel(runOutAt, calendar: calendar))"
        }
        return quota.countdown.isEmpty ? "" : "resets in \(quota.countdown)"
    }

    static func forecast(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        portrait: Bool,
        calendar: Calendar,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 4
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: portrait ? snapshot.generatedAtLabel : "FORECAST · \(snapshot.generatedAtLabel)"
            ),
            snapshot: snapshot,
            gap: gap
        )
        let barWidth = portrait ? 70 : 150
        let rowHeight = chrome.compact ? 28 : 25
        let content = frame.width - 2 * margin
        // The verdict word is the point of the layout, so it is measured first
        // and the name takes what is left. Round 1 let an auto-width name push
        // the flexed verdict to zero — "AT RISK" disappeared exactly when it
        // mattered — and then printed itself off the panel.
        let verdictColumn = (rows.map { EInkTextMetrics.width($0.forecast?.word ?? "LEARNING", font: pixel) }.max() ?? 0)
            + EInkSlotLabel.measurementSlack
        let nameColumn = max(0, content - verdictColumn - 4)
        let list = rows.map { quota in
            column(
                [
                    row(
                        [
                            forecastName(quota, snapshot: snapshot, options: options, width: nameColumn),
                            text(
                                quota.forecast?.word ?? "LEARNING",
                                pixel,
                                width: .points(verdictColumn),
                                align: .trailing
                            )
                        ],
                        height: .points(12),
                        gap: 4,
                        align: .center
                    ),
                    row(
                        [
                            forecastBar(quota, width: barWidth, height: 10),
                            text(
                                forecastRunOutText(quota, calendar: calendar),
                                pixel,
                                width: .flex(1),
                                align: .trailing
                            )
                        ],
                        height: .points(11),
                        gap: 4,
                        align: .center
                    )
                ],
                height: .points(rowHeight),
                gap: 1
            ).module(slotModule(quota.fieldID))
        }
        return screen(chrome.compose(list + [verticalSpacer()]), frame: frame, gap: gap)
    }

    // MARK: - Resets

    /// A seven-day strip with a tick per bucket.
    ///
    /// The strip is one rule and one short mark per reset, drawn at its share
    /// of the week: three ticks bunched at the left edge say "everything comes
    /// back today" at a glance, which no list of countdowns does.
    static func resetTimeline(_ rows: [EInkQuotaRow], now: Date, width: Int) -> EInkNode {
        let window: TimeInterval = 7 * 86_400
        var children: [EInkNode] = [
            EInkNode(.fill, width: .points(width), height: .points(1), origin: EInkPoint(x: 0, y: 6))
        ]
        for quota in rows {
            guard let resetAt = quota.resetAt else { continue }
            let fraction = max(0, min(1, resetAt.timeIntervalSince(now) / window))
            let x = min(width - 2, Int((Double(width - 2) * fraction).rounded()))
            children.append(
                EInkNode(.fill, width: .points(2), height: .points(7), origin: EInkPoint(x: x, y: 0))
            )
        }
        return EInkNode(.stack, width: .points(width), height: .points(7), children: children)
    }

    /// The slot's name on a resets line, with its mark when the slide asked
    /// for one.
    static func resetName(
        _ quota: EInkQuotaRow,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions,
        width: Int
    ) -> EInkNode {
        let style = labelStyle(quota, snapshot: snapshot, options: options, size: EInkLogo.rowSize)
        guard style.drawsLogo, let mark = logoNode(quota, snapshot: snapshot, size: EInkLogo.rowSize) else {
            return text(
                EInkSlotLabel.truncated(quota.slotLabel, width: width),
                pixel,
                width: .points(width),
                clips: true
            ).bound(.quota(quota.fieldID, .label))
        }
        let words = max(0, width - EInkLogo.rowSize - 4)
        return row(
            [
                mark,
                text(
                    EInkSlotLabel.truncated(style.text(of: quota), width: words),
                    pixel,
                    width: .points(words),
                    clips: true
                ).bound(style.part.map { .slotLabel(quota.fieldID, part: $0) })
            ],
            width: .points(width),
            height: .points(EInkLogo.rowSize),
            gap: 4,
            align: .center
        )
    }

    static func resets(
        _ rows: [EInkQuotaRow],
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        portrait: Bool,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = portrait ? 4 : 3
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: portrait ? snapshot.generatedAtLabel : "RESETS · \(snapshot.generatedAtLabel)"
            ),
            snapshot: snapshot,
            gap: gap
        )
        // Soonest first: the whole point of the layout is what comes back
        // next. A bucket with no reset time at all sorts last rather than
        // being dropped, because it is still quota the reader has.
        let sorted = rows.sorted {
            ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture)
        }
        let content = frame.width - 2 * margin
        var children: [EInkNode] = [
            resetTimeline(sorted, now: snapshot.generatedAt, width: content),
            text("NEXT SEVEN DAYS", pixel, width: .flex(1), height: .points(12))
        ]
        // Measured, not guessed: the portrait column was 50 px and "in 3h 00m"
        // is 58, so the one figure this layout exists to print was the one it
        // cut. A figure is never truncated — the name gives up the pixels.
        let countdownWidth = min(
            content / 2,
            max(
                portrait ? 50 : 62,
                (sorted.map { EInkTextMetrics.width("in \($0.countdown)", font: pixelBold) }.max() ?? 0)
                    + EInkSlotLabel.measurementSlack
            )
        )
        for quota in sorted {
            children.append(
                row(
                    [
                        text(
                            quota.countdown.isEmpty ? "unknown" : "in \(quota.countdown)",
                            pixelBold,
                            width: .points(countdownWidth)
                        ).bound(.quota(quota.fieldID, .countdown)),
                        // The list is one line per bucket and there is no
                        // second line to give it, so a name wider than the rest
                        // of the row is the one case the panel truncates.
                        resetName(
                            quota,
                            snapshot: snapshot,
                            options: options,
                            width: content - countdownWidth - 4
                        )
                    ],
                    height: .points(portrait ? 14 : 15),
                    gap: 4,
                    align: .center
                ).module(slotModule(quota.fieldID))
            )
        }
        children.append(verticalSpacer())
        return screen(chrome.compose(children), frame: frame, gap: gap)
    }

    // MARK: - Heatmap

    static func heatmap(
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        portrait: Bool,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 3
        let busiest = snapshot.heatmap.busiestLabel
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: busiest.isEmpty ? snapshot.generatedAtLabel : busiest
            ),
            snapshot: snapshot,
            gap: gap
        )
        let content = frame.width - 2 * margin
        let labelWidth = 26
        let cellSize = portrait ? max(3, (content - labelWidth) / 7) : max(3, (content - labelWidth) / 24)
        let size = EInkHeatmapRasterizer.size(cellSize: cellSize, weekdaysAcross: portrait)
        let uri = try? EInkHeatmapRasterizer.dataURI(
            heatmap: snapshot.heatmap,
            cellSize: cellSize,
            weekdaysAcross: portrait
        )

        var children: [EInkNode] = []
        if let uri {
            let axis: EInkNode
            if portrait {
                // Days across the top, hours down the side.
                axis = row(
                    [
                        column(
                            (0..<24).map { hour in
                                text(
                                    hour % 3 == 0 ? String(format: "%02d", hour) : "",
                                    pixel,
                                    width: .points(labelWidth),
                                    height: .points(cellSize),
                                    align: .trailing
                                )
                            },
                            width: .points(labelWidth),
                            height: .points(size.height)
                        ),
                        EInkNode(.image(uri), width: .points(size.width), height: .points(size.height))
                    ],
                    height: .points(size.height),
                    gap: 2
                )
                children.append(
                    row(
                        [text("", pixel, width: .points(labelWidth + 2))]
                            + EInkHeatmap.weekdayNames.map {
                                text($0, pixel, width: .points(cellSize), height: .points(12), align: .center)
                            },
                        height: .points(12)
                    )
                )
                children.append(axis)
            } else {
                axis = row(
                    [
                        column(
                            EInkHeatmap.weekdayNames.map {
                                text($0, pixel, width: .points(labelWidth), height: .points(cellSize), align: .trailing)
                            },
                            width: .points(labelWidth),
                            height: .points(size.height)
                        ),
                        EInkNode(.image(uri), width: .points(size.width), height: .points(size.height))
                    ],
                    height: .points(size.height),
                    gap: 2
                )
                children.append(axis)
                children.append(
                    row(
                        [text("", pixel, width: .points(labelWidth + 2))]
                            + (0..<24).map { hour in
                                text(
                                    hour % 6 == 0 ? String(format: "%02d", hour) : "",
                                    pixel,
                                    width: .points(cellSize),
                                    height: .points(12)
                                )
                            },
                        height: .points(12)
                    )
                )
            }
        } else {
            children.append(text("ACTIVITY UNAVAILABLE", pixel, width: .flex(1), height: .points(12), align: .center))
        }
        children.append(verticalSpacer())
        return screen(chrome.compose(children), frame: frame, gap: gap)
    }

    // MARK: - Top models

    static func topModels(
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        portrait: Bool,
        limit: Int,
        options: EInkSlideOptions = .default
    ) -> EInkNode {
        let gap = 3
        let rows = Array(snapshot.topModels.prefix(limit))
        // The whole day, not the models this layout happens to list: the
        // assembler keeps the top eight, so a busy day's tail would otherwise
        // be missing from a denominator the footer calls "today's cost".
        let listed = snapshot.topModels.reduce(0) { $0 + $1.costUSD }
        let total = max(max(snapshot.usage.today.costUSD, listed), 0.000_001)
        let shareLine: EInkNode? = rows.first.map { top in
            let share = Int((100 * top.costUSD / total).rounded())
            return topRuled(
                row(
                    [
                        text("TOP MODEL", pixelBold),
                        text("\(share)% of today's cost", pixel, width: .flex(1), align: .trailing)
                    ],
                    height: .points(14),
                    align: .center
                )
            )
        }
        let chrome = chrome(
            options,
            defaults: ChromeDefaults(
                right: portrait ? snapshot.generatedAtLabel : "TOP MODELS · TODAY · \(snapshot.generatedAtLabel)",
                footer: shareLine
            ),
            snapshot: snapshot,
            gap: gap
        )
        let costWidth = portrait ? 40 : 52
        let tokensWidth = portrait ? 34 : 46
        var children: [EInkNode] = []
        if portrait {
            children.append(
                row(
                    [
                        text("MODEL", pixelBold),
                        text("COST", pixel, width: .flex(1), align: .trailing)
                    ],
                    height: .points(12)
                )
            )
        } else {
            children.append(
                row(
                    [
                        text("MODEL", pixelBold),
                        text("COST", pixel, width: .points(costWidth), align: .trailing),
                        text("TOKENS", pixel, width: .points(tokensWidth), align: .trailing),
                        text("REQUESTS", pixel, width: .points(60), align: .trailing)
                    ],
                    height: .points(12),
                    gap: 4
                )
            )
        }
        for model in rows {
            if portrait {
                children.append(
                    column(
                        [
                            text(model.model, pixel, width: .flex(1), height: .points(12)),
                            row(
                                [
                                    text(EInkFormat.tokens(model.tokens) + " tokens", pixel),
                                    text(EInkFormat.money(model.costUSD), pixelBold, width: .flex(1), align: .trailing)
                                ],
                                height: .points(12)
                            )
                        ],
                        height: .points(25),
                        gap: 1
                    )
                )
            } else {
                children.append(
                    row(
                        [
                            text(model.model, pixel, width: .flex(1)),
                            text(EInkFormat.money(model.costUSD), sans(13), width: .points(costWidth), align: .trailing),
                            text(EInkFormat.tokens(model.tokens), pixel, width: .points(tokensWidth), align: .trailing),
                            text(EInkFormat.int(model.requests), pixel, width: .points(60), align: .trailing)
                        ],
                        height: .points(15),
                        gap: 4,
                        align: .center
                    )
                )
            }
        }
        if rows.isEmpty {
            children.append(text("NO MODEL ACTIVITY TODAY", pixel, width: .flex(1), height: .points(12), align: .center))
        }
        children.append(verticalSpacer())
        return screen(chrome.compose(children), frame: frame, gap: gap)
    }

    // MARK: - Alert

    /// The panel the engine pushes when a bucket crosses its threshold.
    ///
    /// Deliberately loud and deliberately not configurable: it names the one
    /// bucket that tripped, says when it runs out, and draws the bar. The
    /// black border comes from the payload (`border: 1`), not from here.
    static func alert(
        _ quota: EInkQuotaRow?,
        _ snapshot: EInkDataSnapshot,
        frame: EInkRect,
        portrait: Bool,
        calendar: Calendar
    ) -> EInkNode {
        let content = frame.width - 2 * margin
        guard let quota else {
            return screen(
                [
                    header("VIBE BAR", "ALERT"),
                    verticalSpacer(),
                    text("QUOTA ALERT", sans(portrait ? 18 : 24), width: .flex(1), height: .points(portrait ? 18 : 24), align: .center),
                    verticalSpacer()
                ],
                frame: frame,
                gap: 6
            )
        }
        // Two centred lines, both clipped to the panel.
        //
        // The first hardware push printed a three-tier name straight through
        // both edges of the black border: a centred `.auto` text wider than
        // its row spills symmetrically, and on an alert — the one panel that
        // exists to be read at a glance — that is unreadable. The name splits
        // where it reads, SubProvider then the rest.
        let headline = EInkSlotLabel.twoLines(quota.slotLabel)
        let runOut: String
        if let runOutAt = quota.forecast?.runOutAt {
            runOut = "RUNS OUT \(EInkFormat.clockLabel(runOutAt, calendar: calendar))"
        } else {
            runOut = "\(quota.remainingPercent)% LEFT"
        }
        return screen(
            [
                header("VIBE BAR", "ALERT · \(snapshot.generatedAtLabel)"),
                verticalSpacer(),
                text(
                    headline.first.uppercased(),
                    pixelBold,
                    width: .points(content),
                    height: .points(12),
                    align: .center
                ),
                text(
                    headline.second.uppercased(),
                    pixelBold,
                    width: .points(content),
                    height: .points(headline.second.isEmpty ? 0 : 12),
                    align: .center
                ),
                text(
                    runOut,
                    sans(portrait ? 18 : 22),
                    width: .flex(1),
                    height: .points(portrait ? 18 : 22),
                    align: .center
                ),
                EInkNode(
                    .horizontalBar(percent: quota.remainingPercent),
                    width: .points(content),
                    height: .points(12),
                    binding: .quota(quota.fieldID, .percent)
                ),
                text(
                    quota.countdown.isEmpty ? "" : "RESETS IN \(quota.countdown.uppercased())",
                    pixel,
                    width: .flex(1),
                    height: .points(12),
                    align: .center
                ).bound(.quota(quota.fieldID, .countdown)),
                verticalSpacer()
            ],
            frame: frame,
            gap: 5
        )
    }
}
