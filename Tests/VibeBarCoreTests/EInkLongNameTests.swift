import XCTest
@testable import VibeBarCore

/// Round 2's long-name rule, tested with the names the owner's own panel
/// carries.
///
/// The complaint that started it was a column of cut names — "ChatGPT Agentic
/// · Weekl", "AntiGravity · Claude and GPT Mo…" — so the contract here is
/// stated in the only terms the device understands: no box ever draws a string
/// wider than itself, at any capacity, in either orientation.
final class EInkLongNameTests: XCTestCase {
    private func snapshot(_ count: Int) -> EInkDataSnapshot {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = EInkFixtures.longNameRows(count: count)
        return snapshot
    }

    private func drawn(
        _ preset: EInkPreset,
        _ orientation: EInkOrientation,
        count: Int,
        options: EInkSlideOptions = .default
    ) throws -> [EInkDrawBox] {
        let snapshot = snapshot(count)
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

    private func strings(_ boxes: [EInkDrawBox]) -> [String] {
        boxes.compactMap { box in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
    }

    // MARK: - The contract

    /// Every quota layout, every capacity, both orientations: nothing is cut
    /// by the box it sits in.
    func testNoQuotaPresetDrawsAClippedBoxForTheOwnersOwnNames() throws {
        var checked = 0
        for preset in EInkPreset.allCases where preset.isQuotaPreset {
            for orientation in EInkOrientation.allCases {
                for count in 1...preset.capacity(for: orientation) {
                    let boxes = try drawn(preset, orientation, count: count)
                    let label = "\(preset.rawValue)/\(orientation.rawValue)°/\(count)"
                    for box in boxes {
                        guard box.clipsContent, case let .text(value, font, _) = box.content else { continue }
                        checked += 1
                        XCTAssertLessThanOrEqual(
                            EInkTextMetrics.width(value, font: font),
                            box.frame.width,
                            "\(label): \"\(value)\" is cut by its \(box.frame.width) px box"
                        )
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "the scan has to actually reach the fixed-width boxes")
    }

    /// The same, with the header and the footer switched off: a compact slide
    /// hands the body more height, and more height is where a two-line slot
    /// could quietly go back to clipping.
    func testTheSameHoldsWithNoHeaderAndNoFooter() throws {
        var options = EInkSlideOptions.default
        options.header = nil
        options.footer = nil
        options.compact = true
        for preset in EInkPreset.allCases where preset.isQuotaPreset {
            for orientation in EInkOrientation.allCases {
                let boxes = try drawn(
                    preset,
                    orientation,
                    count: preset.capacity(for: orientation),
                    options: options
                )
                for box in boxes {
                    guard box.clipsContent, case let .text(value, font, _) = box.content else { continue }
                    XCTAssertLessThanOrEqual(
                        EInkTextMetrics.width(value, font: font),
                        box.frame.width,
                        "\(preset.rawValue)/\(orientation.rawValue)°: \"\(value)\" is cut"
                    )
                }
            }
        }
    }

    /// Nothing leaves the panel either — a name that grew a column must not
    /// have pushed a figure off the right edge.
    func testEveryBoxStaysInsideTheSafeMargin() throws {
        let safe = EInkInsets(all: Int(EInkCanvasLayout.safeMargin))
        for preset in EInkPreset.allCases where preset.isQuotaPreset {
            for orientation in EInkOrientation.allCases {
                let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
                let bounds = EInkRect(x: 0, y: 0, width: size.width, height: size.height).inset(by: safe)
                for box in try drawn(preset, orientation, count: preset.capacity(for: orientation)) {
                    XCTAssertTrue(
                        bounds.contains(box.frame),
                        "\(preset.rawValue)/\(orientation.rawValue)°: \(box.frame) escaped \(bounds)"
                    )
                }
            }
        }
    }

    // MARK: - The ledger

    /// The ledger prints the owner's two worst names in full, on two lines,
    /// in both orientations. This is the panel he asked for.
    func testTheLedgerPrintsTheLongestNamesInFull() throws {
        // Landscape has the width for the whole of the second line.
        let landscape = strings(try drawn(.quotaLedger, .degrees0, count: 2))
        XCTAssertTrue(landscape.contains("ChatGPT Agentic"))
        XCTAssertTrue(landscape.contains("GPT-5.3 Codex Spark · Weekly"))
        XCTAssertTrue(landscape.contains("AntiGravity"))
        XCTAssertTrue(landscape.contains("Claude and GPT Models · Weekly"))

        // Portrait is 140 px across, so the name breaks at one more tier —
        // still every word of it, still nothing cut.
        let portrait = strings(try drawn(.quotaLedger, .degrees90, count: 2))
        for tier in ["ChatGPT Agentic", "GPT-5.3 Codex Spark", "AntiGravity", "Claude and GPT Models"] {
            XCTAssertTrue(portrait.contains(tier), "portrait dropped \"\(tier)\"")
        }
        XCTAssertEqual(portrait.filter { $0 == "Weekly" }.count, 2)

        for printed in [landscape, portrait] {
            XCTAssertFalse(
                printed.contains { EInkSlotLabel.isTruncated($0) },
                "the ledger never has to truncate these"
            )
        }
    }

    /// A two-line slot costs a row, so the ledger prints fewer of them — and
    /// says so, instead of letting the panel drop a row without a word.
    func testTwoLineSlotsCostARowAndTheCapacityAdmitsIt() {
        let short = ["Claude · Weekly", "Codex · Weekly", "Grok Bot · Weekly", "Cursor · Monthly", "Gemini · Daily"]
        XCTAssertEqual(
            EInkPreset.quotaLedger.rowCount(for: .degrees0, labels: short),
            EInkPreset.quotaLedger.capacity(for: .degrees0),
            "short names still fill the panel"
        )
        let long = EInkFixtures.longNameRows(count: 5).map(\.slotLabel)
        let fitted = EInkPreset.quotaLedger.rowCount(for: .degrees0, labels: long)
        XCTAssertLessThan(fitted, EInkPreset.quotaLedger.capacity(for: .degrees0))
        XCTAssertGreaterThan(fitted, 0)

        // And the drawn panel agrees with the number the settings UI is told.
        let printed = strings(try! drawn(.quotaLedger, .degrees0, count: 5))
        let names = printed.filter { $0.hasPrefix("ChatGPT Agentic") || $0.hasPrefix("AntiGravity") || $0 == "Claude" }
        XCTAssertEqual(names.count, fitted)
    }

    /// The bar never gives up more than it can afford, however long the names
    /// get: a 20 px bar is a decoration, not a reading.
    func testTheBarKeepsItsMinimumWidthWhateverTheNamesDo() throws {
        for count in 1...EInkPreset.quotaLedger.capacity(for: .degrees0) {
            for box in try drawn(.quotaLedger, .degrees0, count: count) where box.content == .outline {
                XCTAssertGreaterThanOrEqual(
                    box.frame.width,
                    EInkPresets.barMinimumWidth,
                    "a \(count)-slot ledger drew a \(box.frame.width) px bar"
                )
            }
        }
    }

    // MARK: - Rings and the rail

    /// Rings and the rail always print the two-line centred form: the
    /// SubProvider, then the group and window under it.
    func testRingsAndRailAlwaysPrintTheTwoLineCentredForm() throws {
        for preset in [EInkPreset.quotaRings, .quotaRail] {
            for orientation in [EInkOrientation.degrees0, .degrees90] {
                let boxes = try drawn(preset, orientation, count: 3)
                let name = try XCTUnwrap(
                    boxes.first { box in
                        if case let .text(value, _, alignment) = box.content {
                            return value.hasPrefix("ChatGPT") && alignment == .center
                        }
                        return false
                    },
                    "\(preset.rawValue)/\(orientation.rawValue)° never printed the SubProvider centred"
                )
                let under = boxes.contains { box in
                    guard case let .text(value, _, alignment) = box.content else { return false }
                    return value.hasPrefix("GPT-5.3") && alignment == .center && box.frame.y > name.frame.y
                }
                XCTAssertTrue(under, "\(preset.rawValue)/\(orientation.rawValue)°: the rest goes underneath")
                // And no two names on the same line print through each other,
                // which is exactly what the panel did with these names before
                // the cells learned to break a tier at its spaces.
                let byLine = Dictionary(grouping: boxes.filter { box in
                    if case let .text(_, _, alignment) = box.content { return alignment == .center }
                    return false
                }, by: \.frame.y)
                for (_, line) in byLine {
                    for (index, box) in line.enumerated() {
                        for other in line[(index + 1)...] {
                            XCTAssertTrue(
                                box.frame.maxX <= other.frame.x || other.frame.maxX <= box.frame.x,
                                "\(preset.rawValue)/\(orientation.rawValue)°: \(box.content) overlaps \(other.content)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Truncation

    /// One-line lists have no second line to give, so they truncate — and the
    /// Studio has to say so rather than let a trailing "…" pass for a name.
    func testTheStudioFlagsAnyNameTheLayoutHadToTruncate() throws {
        let snapshot = snapshot(4)
        var slide = EInkFixtures.slide(preset: .resets, fieldIDs: snapshot.quota.map(\.fieldID))
        let layout = EInkPresetExploder.explode(
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        )
        slide.kind = .custom(layoutID: "layout-1")
        let cut = layout.elements.filter { EInkSlotLabel.isTruncated($0.text) }
        XCTAssertFalse(cut.isEmpty, "the resets list cannot hold these names whole")
        let report = EInkLayoutDiagnostics.report(
            layout: layout,
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot
        )
        for element in cut {
            XCTAssertTrue(
                report.issues(for: element.id).contains(.textOverflow(elementID: element.id)),
                "\"\(element.text)\" was cut and the Studio said nothing"
            )
        }
    }

    // MARK: - Fitting primitives

    func testAMeasurementIsOnlyTrustedWithAGlyphOfSlackOnIt() {
        let label = "AntiGravity · Weekly"
        let measured = EInkTextMetrics.width(label, font: .pixel12(bold: false))
        XCTAssertFalse(EInkSlotLabel.fits(label, width: measured))
        XCTAssertTrue(EInkSlotLabel.fits(label, width: measured + EInkSlotLabel.measurementSlack))
    }

    func testTruncationCutsUntilItFitsAndSaysSo() {
        let cut = EInkSlotLabel.truncated("AntiGravity · Claude and GPT Models · Weekly", width: 100)
        XCTAssertTrue(EInkSlotLabel.isTruncated(cut))
        XCTAssertTrue(EInkSlotLabel.fits(cut, width: 100))
        XCTAssertTrue("AntiGravity · Claude and GPT Models · Weekly".hasPrefix(cut.dropLast()))
        // A name that fits is returned untouched, ellipsis and all.
        XCTAssertEqual(EInkSlotLabel.truncated("Claude · Weekly", width: 200), "Claude · Weekly")
    }

    func testWrappingBreaksTheNameAtItsTiers() {
        let lines = EInkSlotLabel.wrapped("ChatGPT Agentic · GPT-5.3 Codex Spark · Weekly", width: 140)
        XCTAssertEqual(lines, ["ChatGPT Agentic", "GPT-5.3 Codex Spark", "Weekly"])
        XCTAssertEqual(EInkSlotLabel.wrapped("Claude · Weekly", width: 140), ["Claude · Weekly"])
        // A tier wider than the line breaks at its spaces rather than being
        // cut, and truncating against the whole row is what lets a single
        // word still spill onto a neighbour's slack.
        XCTAssertEqual(
            EInkSlotLabel.wrapped("Claude and GPT Models", width: 94, maxLines: 3, truncateAt: 284),
            ["Claude and", "GPT Models"]
        )
        XCTAssertEqual(
            EInkSlotLabel.wrapped("AntiGravity", width: 56, maxLines: 2, truncateAt: 284),
            ["AntiGravity"],
            "one word is never broken, and a 7 px overhang is what the demo always spent"
        )
    }

    func testSlotLinesPutTheSubProviderBesideTheFiguresAndTheRestUnderneath() {
        let whole = EInkSlotLabel.slotLines(name: "Claude", window: "Weekly", column: 126, full: 284)
        XCTAssertEqual(whole.lineCount, 1)
        XCTAssertEqual(whole.column, EInkSlotLineFragment("Claude · Weekly", part: .whole))

        let split = EInkSlotLabel.slotLines(
            name: "ChatGPT Agentic",
            window: "GPT-5.3 Codex Spark · Weekly",
            column: 126,
            full: 284
        )
        XCTAssertEqual(split.lineCount, 2)
        XCTAssertEqual(split.column, EInkSlotLineFragment("ChatGPT Agentic", part: .name))
        XCTAssertEqual(split.trailing, [EInkSlotLineFragment("GPT-5.3 Codex Spark · Weekly", part: .window)])
        XCTAssertFalse(split.isTruncated)
    }
}
