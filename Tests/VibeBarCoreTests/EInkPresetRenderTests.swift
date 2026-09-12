import XCTest
@testable import VibeBarCore

/// The contract every preset has to keep on a real panel: inside the safe
/// margin, inside the Canvas API's hard limits, and byte-identical between two
/// renders of the same input.
final class EInkPresetRenderTests: XCTestCase {
    private func selection(for preset: EInkPreset, count: Int) -> (EInkSlide, EInkDataSnapshot) {
        let snapshot: EInkDataSnapshot
        let slide: EInkSlide
        switch preset.selectionAxis {
        case .quotaFields:
            snapshot = EInkFixtures.snapshot()
            let fields = EInkFixtures.quotaRows(count: count).map(\.fieldID)
            slide = EInkFixtures.slide(preset: preset, fieldIDs: fields)
        case .usagePeriods:
            snapshot = EInkFixtures.snapshot()
            slide = EInkFixtures.slide(preset: preset, periods: Array(EInkUsagePeriod.allCases.prefix(count)))
        case .harnessRows:
            snapshot = EInkFixtures.snapshot(harnessCount: count)
            slide = EInkFixtures.slide(preset: preset)
        case .none:
            snapshot = EInkFixtures.snapshot()
            slide = EInkFixtures.slide(preset: preset)
        }
        return (slide, snapshot)
    }

    func testEveryPresetOrientationAndSelectionCountStaysInsideEveryLimit() throws {
        let safe = EInkInsets(all: Int(EInkCanvasLayout.safeMargin))
        for preset in EInkPreset.allCases {
            for orientation in EInkOrientation.allCases {
                let capacity = preset.capacity(for: orientation)
                for count in 1...capacity {
                    let (slide, snapshot) = selection(for: preset, count: count)
                    let device = EInkFixtures.device(orientation: orientation)
                    let label = "\(preset.rawValue)/\(orientation.rawValue)/\(count)"

                    let node = try EInkRenderer.tree(
                        slide: slide,
                        orientation: orientation,
                        profile: device.profile,
                        snapshot: snapshot
                    )
                    let size = device.profile.frameSize(for: orientation)
                    let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
                    let bounds = frame.inset(by: safe)
                    for box in EInkBoxLayout.resolve(node, in: frame) {
                        XCTAssertTrue(bounds.contains(box.frame), "\(label): \(box.frame) escaped \(bounds)")
                    }

                    let payload = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot)
                    let json = try payload.jsonData()
                    XCTAssertLessThanOrEqual(payload.windowData.elementCount, 80, label)
                    XCTAssertLessThanOrEqual(payload.windowData.elementDepth, 16, label)
                    XCTAssertLessThanOrEqual(json.count, 128 * 1024, label)
                    for string in payload.windowData.allStrings {
                        XCTAssertLessThanOrEqual(string.count, 4000, label)
                    }
                    let text = try XCTUnwrap(String(data: json, encoding: .utf8))
                    XCTAssertFalse(text.contains("{{"), "\(label) contains the device's template marker")
                }
            }
        }
    }

    func testRenderingIsDeterministic() throws {
        let snapshot = EInkFixtures.snapshot()
        for preset in EInkPreset.allCases {
            let device = EInkFixtures.device(orientation: .degrees90)
            let slide = EInkFixtures.slide(preset: preset)
            let first = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot).jsonData()
            let second = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot).jsonData()
            XCTAssertEqual(first, second, preset.rawValue)
        }
    }

    func testFewerSelectedFieldsMeanFewerRows() throws {
        let snapshot = EInkFixtures.snapshot()
        let device = EInkFixtures.device(orientation: .degrees0)
        func elementCount(_ fields: [String]) throws -> Int {
            let slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: fields)
            return try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot).windowData.elementCount
        }
        let one = try elementCount(["claude.weekly"])
        let three = try elementCount(["claude.weekly", "codex.weekly", "grok.weekly"])
        XCTAssertLessThan(one, three)
    }

    func testSelectionOrderAndUnknownFieldsAreHonoured() {
        let snapshot = EInkFixtures.snapshot()
        let rows = snapshot.quotaRows(fieldIDs: ["codex.weekly", "nope.nope", "claude.weekly"], limit: 5)
        XCTAssertEqual(rows.map(\.fieldID), ["codex.weekly", "claude.weekly"])
        XCTAssertEqual(snapshot.quotaRows(fieldIDs: [], limit: 3).count, 3)
    }

    func testLongestInMiddlePlacesTheWidestNameCentrally() {
        let rows = EInkFixtures.quotaRows(count: 5)
        let ordered = EInkPresets.longestInMiddle(rows)
        XCTAssertEqual(ordered.count, 5)
        XCTAssertEqual(ordered[2].providerDisplayName, "AntiGravity")
        XCTAssertEqual(Set(ordered.map(\.fieldID)), Set(rows.map(\.fieldID)))
    }

    func testLongestFirstPutsTheWidestNameInTheWideColumn() {
        let rows = Array(EInkFixtures.quotaRows(count: 5)[2...4])
        let ordered = EInkPresets.longestFirst(rows)
        XCTAssertEqual(ordered.first?.providerDisplayName, "AntiGravity")
        XCTAssertEqual(ordered[1].providerDisplayName, "Grok")
        XCTAssertEqual(Set(ordered.map(\.fieldID)), Set(rows.map(\.fieldID)))
    }

    func testACustomSlideWithNoLayoutThrowsInsteadOfDrawingQuotaContent() throws {
        let snapshot = EInkFixtures.snapshot()
        let device = EInkFixtures.device(orientation: .degrees0)
        var slide = EInkFixtures.slide(preset: .quotaLedger)
        slide.kind = .custom(layoutID: "layout-1")

        XCTAssertThrowsError(try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot)) { error in
            XCTAssertEqual(error as? EInkRenderError, .layoutMissing(layoutID: "layout-1"))
        }

        // A layout that *is* there draws, and an empty one draws an empty
        // panel rather than borrowing a preset's content.
        let layouts = ["layout-1": EInkCanvasLayout()]
        let payload = try EInkRenderer.render(
            slide: slide, device: device, snapshot: snapshot, layouts: layouts
        )
        XCTAssertEqual(payload.windowData.elementCount, 1)
    }

    /// A fixed-width text box clips, so any such box narrower than the string
    /// it holds is a silent lie about the number in it. The portrait table is
    /// the tightest layout in the set: 140 px of content width across three
    /// columns and a header row.
    func testPortraitTableColumnsFitTheirMeasuredContent() throws {
        let snapshot = EInkFixtures.snapshot(harnessCount: EInkPreset.usageTable.capacity(for: .degrees90))
        let node = try EInkRenderer.tree(
            slide: EInkFixtures.slide(preset: .usageTable),
            orientation: .degrees90,
            snapshot: snapshot
        )
        let frame = EInkRect(x: 0, y: 0, width: 152, height: 296)
        let boxes = EInkBoxLayout.resolve(node, in: frame)

        // Data cells are fixed-width and clip, so each must be wide enough
        // for the string it was given.
        var clipped = 0
        for box in boxes {
            guard box.clipsContent, case let .text(value, font, _) = box.content else { continue }
            clipped += 1
            XCTAssertLessThanOrEqual(
                EInkTextMetrics.width(value, font: font),
                box.frame.width,
                "\"\(value)\" needs more than the \(box.frame.width) px its column gives it"
            )
        }
        XCTAssertGreaterThan(clipped, 20, "the portrait table should have plenty of fixed-width cells")

        // Header cells size to their own text, so they must not clip either —
        // and "TOKENS" must be there in full, never abbreviated.
        let headers = boxes.filter {
            if case let .text(value, _, _) = $0.content { return ["HARNESS", "TOKENS", "COST"].contains(value) }
            return false
        }
        XCTAssertEqual(headers.count, 6, "two blocks, three headers each")
        for box in headers {
            guard case let .text(value, font, _) = box.content else { continue }
            XCTAssertLessThanOrEqual(EInkTextMetrics.width(value, font: font), box.frame.width, value)
            XCTAssertFalse(box.clipsContent && value == "TOKENS", "the widest header must not be a clipping box")
        }

        // The two right-hand headers keep their data columns' right edges.
        let tokensHeader = try XCTUnwrap(headers.first { if case let .text(v, _, _) = $0.content { return v == "TOKENS" } else { return false } })
        let costHeader = try XCTUnwrap(headers.first { if case let .text(v, _, _) = $0.content { return v == "COST" } else { return false } })
        XCTAssertEqual(costHeader.frame.maxX, 146, "COST ends at the right safe margin")
        XCTAssertEqual(tokensHeader.frame.maxX, 146 - 34 - 2, "TOKENS ends where its data column ends")
        XCTAssertGreaterThanOrEqual(tokensHeader.frame.width, 42, "TOKENS may extend leftwards into the row's slack")

        XCTAssertEqual(68 + 34 + 34 + 2 * 2, 140, "the data columns plus their gaps are the full content width")
    }

    /// The owner's rule for device text: no abbreviations, anywhere. A 152 px
    /// panel is read at a glance and across a desk, and "WK" or "5H" buys a
    /// few pixels at the cost of the one thing the panel is for.
    ///
    /// Matching is whole-word and case-sensitive on purpose. "TOKENS"
    /// contains "TOK" and a base64 ring contains "7D", so a substring scan
    /// would only teach people to disable it; and the lowercase countdown
    /// ("5d 23h") is a duration, not a label, so it stays legal.
    func testNoPresetEverPrintsAnAbbreviation() throws {
        let banned: Set<String> = ["TOK", "5H", "WK", "7D", "30D", "REQ", "TKN", "TOKS"]
        let snapshot = EInkFixtures.snapshot()
        for preset in EInkPreset.allCases {
            for orientation in EInkOrientation.allCases {
                let payload = try EInkRenderer.render(
                    slide: EInkFixtures.slide(preset: preset),
                    device: EInkFixtures.device(orientation: orientation),
                    snapshot: snapshot
                )
                for string in payload.windowData.allStrings where !string.hasPrefix("data:") {
                    let words = string.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                    for word in words where banned.contains(word) {
                        XCTFail("\(preset.rawValue)/\(orientation.rawValue)° prints \"\(string)\", abbreviated as \"\(word)\"")
                    }
                }
            }
        }
    }

    /// The scan is only worth having if it would actually catch a regression.
    func testTheAbbreviationScanCatchesWhatItIsFor() {
        func words(_ string: String) -> [String] {
            string.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        XCTAssertTrue(words("HARNESS TOK COST").contains("TOK"))
        XCTAssertTrue(words("5H · 62%").contains("5H"))
        XCTAssertTrue(words("WK $242").contains("WK"))
        XCTAssertFalse(words("HARNESS TOKENS COST").contains("TOK"))
        XCTAssertFalse(words("7 DAYS $6,061").contains("7D"))
        XCTAssertFalse(words("5d 23h").contains("5H"), "a lowercase countdown is a duration, not a label")
    }

    /// Trend always draws today plus the last seven days, so it exposes no
    /// selection and the slide's period list must not change what it renders.
    func testUsageTrendHasNoSelectionAxisAndIgnoresPeriods() throws {
        XCTAssertEqual(EInkPreset.usageTrend.selectionAxis, EInkPreset.SelectionAxis.none)
        XCTAssertEqual(EInkPreset.usageTrend.capacity(for: .degrees0), 1)
        XCTAssertEqual(EInkPreset.usageTrend.capacity(for: .degrees90), 1)

        let snapshot = EInkFixtures.snapshot()
        let device = EInkFixtures.device(orientation: .degrees0)
        let all = EInkFixtures.slide(preset: .usageTrend, periods: EInkUsagePeriod.allCases)
        let one = EInkFixtures.slide(preset: .usageTrend, periods: [.today])
        let none = EInkFixtures.slide(preset: .usageTrend, periods: [])
        let rendered = try [all, one, none].map {
            try EInkRenderer.render(slide: $0, device: device, snapshot: snapshot).jsonData()
        }
        XCTAssertEqual(rendered[0], rendered[1])
        XCTAssertEqual(rendered[1], rendered[2])
    }

    func testTaskAliasIsPlainEnglish() {
        let alias = EInkRenderer.defaultTaskAlias(slide: EInkFixtures.slide(preset: .usageTiles), orientation: .degrees270)
        XCTAssertEqual(alias, "Vibe Bar · Usage · Tiles · 270°")
    }

    func testRingsAppearAsImageElements() throws {
        let payload = try EInkRenderer.render(
            slide: EInkFixtures.slide(preset: .quotaRings),
            device: EInkFixtures.device(orientation: .degrees0),
            snapshot: EInkFixtures.snapshot()
        )
        let sources = payload.windowData.allStrings.filter { $0.hasPrefix("data:image/png;base64,") }
        XCTAssertEqual(sources.count, 5)
        XCTAssertTrue(payload.windowData.allStrings.contains("img-dither-none img-kernel-threshold"))
    }
}
