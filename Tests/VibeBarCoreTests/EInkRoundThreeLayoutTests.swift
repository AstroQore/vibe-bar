import XCTest
@testable import VibeBarCore

/// Round 3's geometry, stated in the terms the owner's build 82 review used:
/// a label column holds what it draws and nothing more, a centred cell is as
/// wide as its own name needs, and the figure keeps every pixel the words gave
/// back.
final class EInkRoundThreeLayoutTests: XCTestCase {
    private let landscape = EInkRect(x: 0, y: 0, width: 296, height: 152)

    private func snapshot(_ count: Int = 3) -> EInkDataSnapshot {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = EInkFixtures.longNameRows(count: count)
        snapshot.logos = EInkFixtures.logos(for: snapshot.quota)
        return snapshot
    }

    private func drawn(
        _ preset: EInkPreset,
        _ options: EInkSlideOptions,
        _ snapshot: EInkDataSnapshot,
        orientation: EInkOrientation = .degrees0
    ) throws -> [EInkDrawBox] {
        var slide = EInkFixtures.slide(preset: preset, fieldIDs: snapshot.quota.map(\.fieldID))
        slide.options = options
        let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
        return EInkBoxLayout.resolve(
            try EInkRenderer.tree(
                slide: slide,
                orientation: orientation,
                snapshot: snapshot,
                calendar: EInkFixtures.calendar()
            ),
            in: EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        )
    }

    private func options(_ style: EInkSlotLabelStyle) -> EInkSlideOptions {
        var options = EInkSlideOptions.default
        options.labelStyle = style
        return options
    }

    private func bars(_ boxes: [EInkDrawBox]) -> [EInkDrawBox] {
        boxes.filter { $0.content == .outline }
    }

    private func texts(_ boxes: [EInkDrawBox]) -> [(String, EInkDrawBox)] {
        boxes.compactMap { box in
            if case let .text(value, _, _) = box.content { return (value, box) }
            return nil
        }
    }

    private func width(_ text: String) -> Int {
        EInkTextMetrics.width(text, font: .pixel12(bold: false)) + EInkSlotLabel.measurementSlack
    }

    // MARK: - The ledger's label column

    /// "Logo only" draws a 14 px mark and no words, so the label column is
    /// nothing and the bar takes the row.
    ///
    /// This is the owner's first build 82 screenshot: the column kept round
    /// 2's 126 px floor whatever the style drew, and a ledger of marks had a
    /// hand's width of white between the mark and its bar.
    func testALogoOnlyLedgerGivesItsWholeLabelColumnToTheBar() throws {
        let snapshot = snapshot()
        let marks = try drawn(.quotaLedger, options(.logoOnly), snapshot)
        let words = try drawn(.quotaLedger, options(.text), snapshot)

        // Nothing but the mark stands before the bar.
        let mark = try XCTUnwrap(marks.first { if case .image = $0.content { return true }; return false })
        XCTAssertEqual(mark.frame.width, EInkLogo.rowSize)
        let bar = try XCTUnwrap(bars(marks).min { $0.frame.y < $1.frame.y })
        XCTAssertEqual(
            bar.frame.x,
            mark.frame.maxX + 5,
            "the bar starts one gap after the mark, with no column between them"
        )

        let widest = bars(words).map(\.frame.width).max() ?? 0
        XCTAssertGreaterThan(
            bar.frame.width,
            widest,
            "dropping the words has to buy the bar the pixels they cost"
        )
        // And the row is spent: mark, bar, percentage, countdown, three gaps.
        XCTAssertEqual(bar.frame.width, 284 - EInkLogo.rowSize - 34 - 42 - 5 * 3)
    }

    /// Every other style sizes the column to exactly what it prints.
    func testTheLabelColumnMeasuresWhateverTheStyleActuallyDraws() throws {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = [
            EInkQuotaRow(
                fieldID: "claude.weekly",
                providerDisplayName: "Claude",
                windowTitle: "Weekly",
                remainingPercent: 50,
                resetAt: EInkFixtures.referenceDate.addingTimeInterval(3_600),
                countdown: "1h 00m"
            )
        ]
        snapshot.logos = EInkFixtures.logos(for: snapshot.quota)

        // Full name: the whole label, measured.
        let whole = texts(try drawn(.quotaLedger, options(.text), snapshot))
        let wholeBox = try XCTUnwrap(whole.first { $0.0 == "Claude · Weekly" }?.1)
        XCTAssertEqual(wholeBox.frame.width, width("Claude · Weekly"))

        // Logo and window: the mark, then the window alone, measured.
        let window = texts(try drawn(.quotaLedger, options(.logoAndWindow), snapshot))
        let windowBox = try XCTUnwrap(window.first { $0.0 == "Weekly" }?.1)
        XCTAssertEqual(windowBox.frame.width, width("Weekly"))
        XCTAssertLessThan(windowBox.frame.width, wholeBox.frame.width)
    }

    /// Whatever the column gives back, the bar takes — and the row still ends
    /// where the panel's safe margin does.
    func testTheBarGrowsByExactlyWhatTheColumnGaveUp() throws {
        let snapshot = snapshot(2)
        var widths: [EInkSlotLabelStyle: Int] = [:]
        for style in EInkSlotLabelStyle.allCases {
            let boxes = try drawn(.quotaLedger, options(style), snapshot)
            widths[style] = bars(boxes).map(\.frame.width).max() ?? 0
            for box in boxes {
                XCTAssertLessThanOrEqual(box.frame.maxX, 290, "\(style) drew past the safe margin")
            }
        }
        // The mark alone is the widest bar there is — there is nothing else in
        // the row to pay for — and no style ever drops the bar below the
        // minimum that still reads as one.
        for (style, width) in widths {
            XCTAssertGreaterThanOrEqual(widths[.logoOnly] ?? 0, width, "\(style)")
            XCTAssertGreaterThanOrEqual(width, EInkPresets.barMinimumWidth, "\(style)")
        }
        XCTAssertGreaterThan(widths[.logoOnly] ?? 0, widths[.text] ?? 0)
    }

    // MARK: - Shared columns

    /// A row of centred cells is shared out in proportion to the names, never
    /// equally, and always adds up to the row it was given.
    func testCentredColumnsShareTheRowInProportionAndSumToIt() {
        let desired = [200, 60, 90]
        let widths = EInkSlotLabel.sharedWidths(desired, total: 284, minimum: 40)
        XCTAssertEqual(widths.reduce(0, +), 284)
        XCTAssertGreaterThan(widths[0], widths[2])
        XCTAssertGreaterThan(widths[2], widths[1])
        XCTAssertTrue(widths.allSatisfy { $0 >= 40 })

        // Short names do not each swell to a third of the row and leave the
        // long one starved: the order of the widths follows the order of the
        // names that asked for them.
        let even = EInkSlotLabel.sharedWidths([80, 80, 80], total: 284, minimum: 40)
        XCTAssertEqual(even.reduce(0, +), 284)
        XCTAssertLessThanOrEqual(
            (even.max() ?? 0) - (even.min() ?? 0),
            2,
            "equal names get equal columns, give or take the rounding the last one absorbs"
        )

        // Nothing below the floor, however lopsided the request.
        let squeezed = EInkSlotLabel.sharedWidths([400, 10, 10], total: 140, minimum: 40)
        XCTAssertEqual(squeezed.reduce(0, +), 140)
        XCTAssertTrue(squeezed.allSatisfy { $0 >= 40 })
    }

    // MARK: - Two lines, and what goes before a cut

    /// The second line drops its group before anything is cut, and the window
    /// — the tier the reader came for — survives.
    func testACellDropsItsGroupRatherThanTruncateAnything() {
        let wide = EInkSlotLabel.cellLines(
            name: "AntiGravity",
            window: "Claude and GPT Models · Weekly",
            width: 200
        )
        XCTAssertEqual(wide.map(\.text), ["AntiGravity", "Claude and GPT Models · Weekly"])

        let narrow = EInkSlotLabel.cellLines(
            name: "AntiGravity",
            window: "Claude and GPT Models · Weekly",
            width: 80
        )
        XCTAssertEqual(narrow.map(\.text), ["AntiGravity", "Weekly"])
        XCTAssertFalse(
            narrow.contains { EInkSlotLabel.isTruncated($0.text) },
            "the group goes whole or not at all — nothing here is ever cut"
        )
        XCTAssertEqual(narrow.count, EInkSlotLabel.cellMaximumLines)

        // A name that fits on one line stays on one.
        let short = EInkSlotLabel.cellLines(name: "Claude", window: "Weekly", width: 200)
        XCTAssertEqual(short.map(\.text), ["Claude · Weekly"])
    }

    /// A name with no tier left to drop, wider than the whole panel, gets the
    /// one ellipsis the panel is allowed to draw — and loses its binding, so
    /// the Studio reports it rather than passing it off as the bucket's name.
    func testANameWiderThanTheRowIsCutRatherThanDrawnThroughTheEdge() {
        let huge = String(repeating: "Desk Panel ", count: 8)
        let lines = EInkSlotLabel.cellLines(name: huge, window: "", width: 94, rowWidth: 284)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(EInkSlotLabel.isTruncated(lines[0].text))
        XCTAssertTrue(EInkSlotLabel.fits(lines[0].text, width: 284))
        XCTAssertNil(lines[0].part, "a cut name is not the bucket's name")

        // And the presets pass the row width, so a panel never draws one.
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = [
            EInkQuotaRow(fieldID: "claude.weekly", providerDisplayName: huge, windowTitle: "", remainingPercent: 50)
        ]
        for preset in [EInkPreset.quotaRings, .quotaRail] {
            for orientation in EInkOrientation.allCases {
                let content = orientation.isPortrait ? 140 : 284
                for (value, box) in texts(try! drawn(preset, .default, snapshot, orientation: orientation)) {
                    XCTAssertLessThanOrEqual(
                        EInkTextMetrics.width(value, font: .pixel12(bold: false)),
                        content + EInkPresets.cellSpill,
                        "\(preset.rawValue)/\(orientation.rawValue)°: \"\(value)\" at \(box.frame.width) px"
                    )
                }
            }
        }
    }

    /// The rail never stacks more than two lines of name under a bar,
    /// whatever the names are.
    ///
    /// Counted off the panel rather than off the planner: the lines under a
    /// bar are the only centred text a rail cell draws, so the number of
    /// distinct rows between one bar row and the next *is* the wrap.
    func testTheRailNeverStacksMoreThanTwoLinesUnderABar() throws {
        for orientation in EInkOrientation.allCases {
            for count in 1...EInkPreset.quotaRail.capacity(for: orientation) {
                let boxes = try drawn(.quotaRail, .default, snapshot(count), orientation: orientation)
                // The label lines, and only those: a cell's percentage is
                // centred too, and it is drawn in the numbers' font.
                let centred = texts(boxes).filter { pair in
                    guard case let .text(_, font, alignment) = pair.1.content else { return false }
                    guard case .pixel12 = font else { return false }
                    return alignment == .center
                }
                // A cell's bar and its lines share a centre, so the bar is
                // what identifies the column its labels belong to.
                let allBars = bars(boxes)
                for bar in allBars {
                    let centre = bar.frame.x + bar.frame.width / 2
                    func sharesColumn(_ frame: EInkRect) -> Bool {
                        abs((frame.x + frame.width / 2) - centre) <= 4
                    }
                    // A portrait rail stacks rows of cells in the same
                    // columns, so the next bar down is where this cell ends.
                    let ceiling = allBars
                        .filter { sharesColumn($0.frame) && $0.frame.y > bar.frame.y }
                        .map(\.frame.y)
                        .min() ?? Int.max
                    let rows = Set(
                        centred
                            .filter { sharesColumn($0.1.frame) }
                            .filter { $0.1.frame.y >= bar.frame.maxY && $0.1.frame.y < ceiling }
                            .map(\.1.frame.y)
                    )
                    XCTAssertLessThanOrEqual(
                        rows.count,
                        EInkSlotLabel.cellMaximumLines,
                        "rail/\(orientation.rawValue)°/\(count) stacked \(rows.count) lines under a bar"
                    )
                }
            }
        }
    }

    /// And neither helper can produce a third line in the first place.
    func testNeitherCellHelperEverReturnsMoreThanTwoLines() {
        let row = EInkQuotaRow(
            fieldID: "antigravity.claude_gpt_weekly",
            providerDisplayName: "AntiGravity",
            windowTitle: "Claude and GPT Models · Weekly",
            remainingPercent: 50
        )
        for width in [20, 40, 60, 94, 140, 284] {
            for style in EInkSlotLabelStyle.allCases {
                XCTAssertLessThanOrEqual(
                    EInkPresets.cellLabelLines(row, style: style, width: width).count,
                    EInkSlotLabel.cellMaximumLines,
                    "\(style) at \(width) px"
                )
            }
        }
    }

    // MARK: - Height

    /// Shorter labels are taller bars. The rail's whole job is the bar, and
    /// round 2 spent its height on a name that had wrapped three times.
    func testTheRailBarGrowsAsTheLabelsShrink() throws {
        let long = snapshot(3)
        var short = EInkFixtures.snapshot()
        short.quota = long.quota.map { row in
            var copy = row
            copy.providerDisplayName = "Grok"
            copy.windowTitle = "Weekly"
            return copy
        }
        short.logos = EInkFixtures.logos(for: short.quota)

        func tallestBar(_ snapshot: EInkDataSnapshot, _ options: EInkSlideOptions) throws -> Int {
            bars(try drawn(.quotaRail, options, snapshot)).map(\.frame.height).max() ?? 0
        }
        let wrapped = try tallestBar(long, .default)
        let plain = try tallestBar(short, .default)
        XCTAssertGreaterThan(plain, wrapped, "one line of name is a taller bar than two")

        // And a mark with no words under it is taller again.
        let marks = try tallestBar(long, options(.logoOnly))
        XCTAssertGreaterThan(marks, wrapped)
    }

    /// With no header, no footer and nothing but marks, the bars take the
    /// panel.
    ///
    /// Round 2 picked the bar from a fixed list — 60 px, or 84 with the bars
    /// off — so a rail that had been handed the whole panel drew the same
    /// short bar with white underneath it.
    func testTheRailBarTakesThePanelWhenNothingElseWantsIt() throws {
        let snapshot = snapshot(3)
        var bare = options(.logoOnly)
        bare.header = nil
        bare.footer = nil
        bare.compact = true

        func tallestBar(_ options: EInkSlideOptions, _ orientation: EInkOrientation) throws -> Int {
            bars(try drawn(.quotaRail, options, snapshot, orientation: orientation))
                .map(\.frame.height)
                .max() ?? 0
        }

        for (orientation, content) in [(EInkOrientation.degrees0, 140), (.degrees90, 284)] {
            let full = try tallestBar(bare, orientation)
            XCTAssertGreaterThan(
                full,
                try tallestBar(options(.logoOnly), orientation),
                "\(orientation.rawValue)°: turning the bars off has to lengthen the bar"
            )
            // The percentage, the mark and the gaps are all that is left.
            XCTAssertGreaterThanOrEqual(
                full,
                content - 13 - EInkLogo.cellSize - 8,
                "\(orientation.rawValue)°: a \(full) px bar in \(content) px of panel"
            )
            XCTAssertLessThanOrEqual(full, content)
        }
    }

    /// The same for the rings: the arc takes the height the words left.
    func testTheRingGrowsAsTheLabelsShrink() throws {
        let long = snapshot(3)
        func ring(_ options: EInkSlideOptions) throws -> Int {
            try drawn(.quotaRings, options, long).compactMap { box in
                if case .ring = box.content { return box.frame.height }
                return nil
            }.max() ?? 0
        }
        XCTAssertGreaterThan(try ring(options(.logoOnly)), try ring(.default))
    }

    // MARK: - Level labels

    /// A SubProvider renamed once prints its new name on every bucket under
    /// it, without five per-slot overrides kept in step by hand.
    func testRenamingALevelRenamesEveryBucketUnderIt() throws {
        var options = EInkSlideOptions.default
        let subProvider = try XCTUnwrap(EInkSlotLabel.subProviderLevelKey(for: "codex.gpt_5_3_codex_spark_weekly"))
        options.levelLabels[subProvider] = "Codex"

        XCTAssertEqual(
            EInkSlotLabel.resolved(for: "codex.weekly", options: options),
            "Codex · Weekly"
        )
        XCTAssertEqual(
            EInkSlotLabel.resolved(for: "codex.gpt_5_3_codex_spark_weekly", options: options),
            "Codex · GPT-5.3 Codex Spark · Weekly"
        )

        // The group is a level of its own.
        let group = try XCTUnwrap(EInkSlotLabel.groupLevelKey(for: "codex.gpt_5_3_codex_spark_weekly"))
        options.levelLabels[group] = "Spark"
        XCTAssertEqual(
            EInkSlotLabel.resolved(for: "codex.gpt_5_3_codex_spark_weekly", options: options),
            "Codex · Spark · Weekly"
        )

        // A slot's own name still wins over both.
        options.customLabels["codex.gpt_5_3_codex_spark_weekly"] = "Desk · Weekly"
        XCTAssertEqual(
            EInkSlotLabel.resolved(for: "codex.gpt_5_3_codex_spark_weekly", options: options),
            "Desk · Weekly"
        )
    }

    /// A bucket with no group tier has no group row to rename, so the editor
    /// does not offer one.
    func testABucketWithNoGroupHasNoGroupLevel() {
        XCTAssertNil(EInkSlotLabel.groupLevelKey(for: "claude.weekly"))
        XCTAssertNotNil(EInkSlotLabel.subProviderLevelKey(for: "claude.weekly"))
        // And the key is the one the mini windows already store under.
        XCTAssertEqual(
            EInkSlotLabel.subProviderLevelKey(for: "claude.weekly"),
            MenuBarFieldCatalog.subProviderLabelKey(
                tool: .claude,
                name: ToolType.claude.quotaSubProviderName(bucketID: "weekly")
            )
        )
    }

    /// And the renamed level reaches the panel, not only the string helper.
    func testAPanelPrintsTheRenamedLevel() throws {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = [
            EInkQuotaRow(
                fieldID: "codex.weekly",
                providerDisplayName: "ChatGPT Agentic",
                windowTitle: "Weekly",
                remainingPercent: 50,
                resetAt: EInkFixtures.referenceDate.addingTimeInterval(3_600),
                countdown: "1h 00m"
            )
        ]
        var options = EInkSlideOptions.default
        options.levelLabels[try XCTUnwrap(EInkSlotLabel.subProviderLevelKey(for: "codex.weekly"))] = "Codex"
        let printed = texts(try drawn(.quotaLedger, options, snapshot)).map(\.0)
        XCTAssertTrue(printed.contains("Codex · Weekly"))
        XCTAssertFalse(printed.contains("ChatGPT Agentic · Weekly"))
    }

    // MARK: - The device's own shape

    /// Where the blank half of the bar sits, per rotation.
    ///
    /// The Quote/0 is a long bar with the panel at one end; the body is on the
    /// device's own right when its top is up, which is a quarter turn
    /// clockwise from `uprightDeviceEdge`. This is the table the orientation
    /// picker draws, and drawing it wrong is a picture that says the device is
    /// hung the other way up.
    func testTheBlankBodySitsOnTheRightEdgeForEveryRotation() {
        let expected: [EInkOrientation: (
            top: EInkOrientation.DeviceEdge,
            body: EInkOrientation.DeviceEdge,
            port: EInkOrientation.DeviceEdge
        )] = [
            .degrees0: (.top, .right, .left),
            .degrees90: (.left, .top, .bottom),
            .degrees180: (.bottom, .left, .right),
            .degrees270: (.right, .bottom, .top)
        ]
        for orientation in EInkOrientation.allCases {
            let want = try! XCTUnwrap(expected[orientation])
            XCTAssertEqual(orientation.uprightDeviceEdge, want.top, "\(orientation.rawValue)° top")
            XCTAssertEqual(orientation.uprightBodyEdge, want.body, "\(orientation.rawValue)° body")
            XCTAssertEqual(orientation.uprightPortEdge, want.port, "\(orientation.rawValue)° port")
            // The port is always the edge opposite the body, and the body is
            // always on a short edge of the panel as it is read.
            XCTAssertNotEqual(orientation.uprightBodyEdge, orientation.uprightPortEdge)
            let isVertical = { (edge: EInkOrientation.DeviceEdge) in edge == .top || edge == .bottom }
            XCTAssertEqual(isVertical(orientation.uprightBodyEdge), isVertical(orientation.uprightPortEdge))
            // A portrait panel's bar runs vertically; a landscape one's runs
            // across. The body always extends off the panel's long axis.
            XCTAssertEqual(
                isVertical(orientation.uprightBodyEdge),
                orientation.isPortrait,
                "\(orientation.rawValue)°: the bar runs along the panel's long side"
            )
        }
    }

    /// Level names survive a settings round trip, and an empty one is not
    /// stored at all.
    func testLevelLabelsRoundTripAndSanitize() throws {
        var options = EInkSlideOptions.default
        options.levelLabels = ["subprovider:codex/ChatGPT Agentic": "Codex", "blank": "   "]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(EInkSlideOptions.self, from: try encoder.encode(options))
        XCTAssertEqual(decoded.levelLabels, options.levelLabels)
        XCTAssertEqual(decoded.sanitized.levelLabels, ["subprovider:codex/ChatGPT Agentic": "Codex"])
        XCTAssertNil(decoded.sanitized.levelLabel(for: "blank"))

        // A file written before this round has no key and decodes to none.
        let legacy = Data(#"{"hasHeader":true,"hasFooter":true,"slotOrder":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EInkSlideOptions.self, from: legacy).levelLabels, [:])
    }

    /// A slide that renames nothing draws exactly what it drew before the
    /// level names existed — the option is inert until it is used.
    func testAnEmptyLevelMapChangesNothing() throws {
        let snapshot = snapshot()
        var options = EInkSlideOptions.default
        options.levelLabels = [:]
        for preset in EInkPreset.allCases where preset.isQuotaPreset {
            for orientation in EInkOrientation.allCases {
                XCTAssertEqual(
                    try drawn(preset, options, snapshot, orientation: orientation),
                    try drawn(preset, .default, snapshot, orientation: orientation),
                    "\(preset.rawValue)/\(orientation.rawValue)°"
                )
            }
        }
    }
}
