import XCTest
@testable import VibeBarCore

/// Round 2 made the header and the footer optional, movable and editable. The
/// first test here is the one that matters: a slide nobody has configured
/// still draws exactly the panel round 1 drew.
final class EInkSlideOptionsTests: XCTestCase {
    private let snapshot = EInkFixtures.snapshot()

    private func boxes(
        _ preset: EInkPreset,
        orientation: EInkOrientation,
        options: EInkSlideOptions = .default
    ) throws -> [EInkDrawBox] {
        var slide = EInkFixtures.slide(preset: preset)
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

    // MARK: - Golden

    /// A settings file written by round 1 has no `options` key at all. It must
    /// decode into the defaults, and the defaults must draw the same bytes.
    func testASlideWithNoStoredOptionsDrawsTheRoundOnePanelByteForByte() throws {
        let legacy = Data("""
        {"id":"slide-1","title":"Quota · Ledger","kind":{"kind":"preset","preset":"quotaLedger"},
         "quotaFieldIDs":[],"usagePeriods":["today","week","month","allTime"]}
        """.utf8)
        let decoded = try JSONDecoder().decode(EInkSlide.self, from: legacy)
        XCTAssertEqual(decoded.options, .default)

        for preset in EInkPreset.allCases {
            for orientation in EInkOrientation.allCases {
                var slide = EInkFixtures.slide(preset: preset)
                slide.options = decoded.options
                let withDefaults = try EInkRenderer.render(
                    slide: slide,
                    device: EInkFixtures.device(orientation: orientation),
                    snapshot: snapshot,
                    calendar: EInkFixtures.calendar()
                )
                var untouched = EInkFixtures.slide(preset: preset)
                untouched.options = .default
                let reference = try EInkRenderer.render(
                    slide: untouched,
                    device: EInkFixtures.device(orientation: orientation),
                    snapshot: snapshot,
                    calendar: EInkFixtures.calendar()
                )
                XCTAssertEqual(
                    try withDefaults.jsonData(),
                    try reference.jsonData(),
                    "\(preset.rawValue) at \(orientation.rawValue)°"
                )
            }
        }
    }

    func testTheDefaultHeaderIsStillVibeBarAndTheShippedRightHandLabel() throws {
        let printed = strings(try boxes(.quotaLedger, orientation: .degrees0))
        XCTAssertEqual(printed.first, "VIBE BAR")
        XCTAssertTrue(printed.contains("QUOTA LEFT · \(snapshot.generatedAtLabel)"))
    }

    // MARK: - Header

    func testTurningTheHeaderOffRemovesItAndHandsTheHeightToTheBody() throws {
        let withHeader = try boxes(.quotaLedger, orientation: .degrees0)
        var options = EInkSlideOptions.default
        options.header = nil
        let without = try boxes(.quotaLedger, orientation: .degrees0, options: options)

        XCTAssertFalse(strings(without).contains("VIBE BAR"))
        // The first bar is the top of the body proper.
        let firstBarTop = { (list: [EInkDrawBox]) in
            list.first { $0.content == .outline }?.frame.y ?? 0
        }
        XCTAssertLessThan(
            firstBarTop(without),
            firstBarTop(withHeader),
            "the body starts higher when there is no header above it"
        )
    }

    func testMovingTheHeaderToTheBottomPutsItUnderEverythingElse() throws {
        var options = EInkSlideOptions.default
        options.header = EInkBarConfig(position: .bottom)
        let drawn = try boxes(.quotaLedger, orientation: .degrees0, options: options)
        let header = try XCTUnwrap(drawn.first { box in
            if case let .text(value, _, _) = box.content { return value == "VIBE BAR" }
            return false
        })
        let others = drawn.filter { $0.frame != header.frame }.map(\.frame.y)
        XCTAssertGreaterThan(header.frame.y, others.min() ?? 0)
    }

    func testEachBarSideCanBeFixedTextAClockADateOrTheProviderStatus() throws {
        var options = EInkSlideOptions.default
        options.header = EInkBarConfig(position: .top, left: .text("DESK PANEL"), right: .clock)
        XCTAssertTrue(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains("DESK PANEL"))
        XCTAssertTrue(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains(snapshot.clockLabel))

        options.header = EInkBarConfig(position: .top, left: .date, right: .providerStatus)
        XCTAssertFalse(snapshot.providerStatusLine.isEmpty)
        let printed = strings(try boxes(.quotaLedger, orientation: .degrees0, options: options))
        XCTAssertTrue(printed.contains(snapshot.dateLabel))
        XCTAssertTrue(printed.contains(snapshot.providerStatusLine))

        options.header = EInkBarConfig(position: .top, left: .none, right: .none)
        XCTAssertFalse(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains("VIBE BAR"))
    }

    /// One line of provider health, in English, naming the provider that is
    /// actually in trouble.
    func testTheProviderStatusLineNamesTheWorstProvider() {
        XCTAssertEqual(EInkProviderStatusLine.compose([]), "")
        let healthy = ServiceStatusSnapshot(
            tool: .claude,
            indicator: .none,
            description: "",
            updatedAt: EInkFixtures.referenceDate,
            groups: [],
            components: [],
            recentIncidents: []
        )
        XCTAssertEqual(EInkProviderStatusLine.compose([healthy]), "All providers operational")
        let degraded = ServiceStatusSnapshot(
            tool: .claude,
            indicator: .minor,
            description: "",
            updatedAt: EInkFixtures.referenceDate,
            groups: [],
            components: [],
            recentIncidents: []
        )
        XCTAssertEqual(EInkProviderStatusLine.compose([healthy, degraded]), "Anthropic: degraded")
    }

    // MARK: - Footer

    func testTheFooterCanBeTurnedOffOrReplacedWithAClockOrFixedText() throws {
        var options = EInkSlideOptions.default
        let shipped = strings(try boxes(.quotaLedger, orientation: .degrees0))
        XCTAssertTrue(shipped.contains { $0.hasPrefix("TODAY ") })

        options.footer = nil
        XCTAssertFalse(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains { $0.hasPrefix("TODAY ") })

        options.footer = EInkFooterConfig(content: .text("DESK PANEL"))
        XCTAssertTrue(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains("DESK PANEL"))

        options.footer = EInkFooterConfig(content: .clock)
        XCTAssertTrue(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains(snapshot.generatedAtLabel))

        options.footer = EInkFooterConfig(content: .usageSummary(periods: [.month]))
        XCTAssertTrue(strings(try boxes(.quotaLedger, orientation: .degrees0, options: options)).contains { $0.hasPrefix("30 DAYS ") })
    }

    func testWithBothBarsOffTheRowsGrowToFillThePanel() throws {
        var options = EInkSlideOptions.default
        options.header = nil
        options.footer = nil
        options.compact = true
        let compact = try boxes(.quotaLedger, orientation: .degrees0, options: options)
        options.compact = false
        let plain = try boxes(.quotaLedger, orientation: .degrees0, options: options)
        func span(_ list: [EInkDrawBox]) -> Int { (list.map(\.frame.maxY).max() ?? 0) - (list.map(\.frame.y).min() ?? 0) }
        XCTAssertGreaterThan(span(compact), span(plain), "compact fills the height the bars gave back")
        XCTAssertLessThanOrEqual(compact.map(\.frame.maxY).max() ?? 0, 146, "and still respects the safe margin")
    }

    // MARK: - Slot order

    func testSlotOrderPutsTheSelectedBucketsInTheOrderTheEditorChose() throws {
        var slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: ["claude.five_hour", "claude.weekly", "codex.weekly"])
        slide.options.slotOrder = ["codex.weekly", "claude.weekly"]
        XCTAssertEqual(slide.orderedQuotaFieldIDs, ["codex.weekly", "claude.weekly", "claude.five_hour"])
    }

    /// A saved order predates whatever the user ticked a moment ago, so it may
    /// never be the thing that hides it.
    func testAnOrderNeverDropsASlotItDoesNotMention() {
        let options = EInkSlideOptions(slotOrder: ["b", "gone"])
        XCTAssertEqual(options.ordered(["a", "b", "c"]), ["b", "a", "c"])
    }

    func testOptionsRoundTripThroughSettingsIncludingTheOffStates() throws {
        var options = EInkSlideOptions.default
        options.header = nil
        options.footer = EInkFooterConfig(content: .usageSummary(periods: [.today, .month]))
        options.slotOrder = ["claude.weekly"]
        options.customLabels = ["claude.weekly": "Weekly"]
        options.compact = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(EInkSlideOptions.self, from: try encoder.encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertNil(decoded.header)
    }

    /// `{{` is the Canvas API's template marker and a payload carrying one is
    /// rejected outright, so a bar's fixed text must not be able to hold it.
    func testFixedBarTextCannotSmuggleATemplateMarker() throws {
        let encoder = JSONEncoder()
        var options = EInkSlideOptions.default
        options.header = EInkBarConfig(position: .top, left: .text("{{alias}}"), right: .none)
        let decoded = try JSONDecoder().decode(EInkSlideOptions.self, from: try encoder.encode(options))
        if case let .text(value) = decoded.header?.left {
            XCTAssertFalse(value.contains("{{"))
        } else {
            XCTFail("the left side should still be fixed text")
        }
    }
}
