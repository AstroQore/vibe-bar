import XCTest
@testable import VibeBarCore

/// Round 2's other half of the naming fix: a slot may wear its provider's
/// mark instead of spelling it out.
///
/// The owner's panel carries "ChatGPT Agentic · GPT-5.3 Codex Spark · Weekly",
/// and the first tier of that is the one his menu bar has been identifying
/// with a logo all along. Swapping it for the mark buys back the width that
/// forced the slot onto two lines.
final class EInkSlotLogoTests: XCTestCase {
    private func snapshot(_ count: Int = 5) -> EInkDataSnapshot {
        var snapshot = EInkFixtures.snapshot()
        snapshot.quota = EInkFixtures.longNameRows(count: count)
        snapshot.logos = EInkFixtures.logos(for: snapshot.quota)
        return snapshot
    }

    private func options(_ style: EInkSlotLabelStyle) -> EInkSlideOptions {
        var options = EInkSlideOptions.default
        options.labelStyle = style
        return options
    }

    private func drawn(
        _ preset: EInkPreset,
        _ orientation: EInkOrientation,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions,
        count: Int = 5
    ) throws -> [EInkDrawBox] {
        var slide = EInkFixtures.slide(
            preset: preset,
            fieldIDs: Array(snapshot.quota.prefix(count)).map(\.fieldID)
        )
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

    // MARK: - The monogram fallback

    func testAProviderWithNoArtGetsTwoLetters() {
        XCTAssertEqual(EInkLogo.monogram(for: "ChatGPT Agentic"), "CA")
        XCTAssertEqual(EInkLogo.monogram(for: "Claude"), "CL")
        XCTAssertEqual(EInkLogo.monogram(for: "OpenAI"), "OP")
        XCTAssertEqual(EInkLogo.monogram(for: "Grok Bot"), "GB")
        XCTAssertEqual(EInkLogo.monogram(for: ""), "??")
    }

    func testTheMonogramRasterizesToAOneBitSquareWithInkInIt() throws {
        for size in EInkLogo.sizes {
            let data = try EInkMonogramRasterizer.pngData(initials: "CA", size: size)
            XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG magic at \(size)")
            // Straight out of the IHDR, because ImageIO expands a 1-bit
            // image to 8 on decode and would hide exactly the regression
            // this is here to catch.
            let header = [UInt8](data.prefix(26))
            XCTAssertEqual(Int(header[19]), size, "width")
            XCTAssertEqual(Int(header[23]), size, "height")
            XCTAssertEqual(header[24], 1, "the panel takes 1-bit art and nothing else")
            XCTAssertEqual(header[25], 0, "greyscale, no palette")
        }
        XCTAssertThrowsError(try EInkMonogramRasterizer.pngData(initials: "CA", size: 4))
        // The same initials come back byte for byte, which is what the cache
        // in front of this is allowed to assume.
        XCTAssertEqual(
            try EInkMonogramRasterizer.dataURI(initials: "CL", size: 14),
            try EInkMonogramRasterizer.dataURI(initials: "CL", size: 14)
        )
    }

    func testInkCoverageAndDilationAreWhatTheyClaim() {
        let blank = [UInt8](repeating: 255, count: 16)
        XCTAssertEqual(EInkBitmap.inkCoverage(gray: blank, threshold: 128), 0)
        var speck = blank
        speck[5] = 0
        XCTAssertEqual(EInkBitmap.inkCoverage(gray: speck, threshold: 128), 1.0 / 16)
        // One pass spreads that speck to its four neighbours: 5 of 16.
        let bolder = EInkBitmap.dilated(gray: speck, size: 4)
        XCTAssertEqual(EInkBitmap.inkCoverage(gray: bolder, threshold: 128), 5.0 / 16)
        XCTAssertEqual(EInkBitmap.dilated(gray: blank, size: 4), blank, "nothing to spread")
    }

    // MARK: - What the mark buys

    /// The whole point: the bucket that needed two lines fits one.
    func testTheMarkFitsTheSparkBucketOnOneLine() throws {
        let snapshot = snapshot()
        let spark = snapshot.quota[0]
        XCTAssertEqual(spark.fieldID, "codex.spark_weekly")

        func lines(_ style: EInkSlotLabelStyle) -> Int {
            EInkPresets.ledgerPlan(
                [spark],
                content: 284,
                snapshot: snapshot,
                options: options(style)
            ).lines[0].lineCount
        }
        // The mark buys back the SubProvider's 92 px, and for this bucket the
        // group and the window still want 174 of the 145 the row can spare —
        // so the words take a line of their own, with the mark naming the row
        // beside the bar. Trading the group away as well is what makes it one
        // line, and the picker is where that trade is offered.
        XCTAssertEqual(lines(.text), 2, "the name alone does not fit the column")
        XCTAssertEqual(lines(.logoAndGroup), 2)
        XCTAssertEqual(lines(.logoAndWindow), 1, "the mark and the window alone fit beside the bar")
        XCTAssertEqual(lines(.logoOnly), 1)

        // And the panel draws the mark, the words, and nothing cut.
        let boxes = try drawn(.quotaLedger, .degrees0, snapshot: snapshot, options: options(.logoAndGroup), count: 2)
        let printed = boxes.compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(printed.contains("GPT-5.3 Codex Spark · Weekly"), "in full, on the line under the mark")
        XCTAssertTrue(printed.contains("Claude and GPT Models · Weekly"))
        XCTAssertFalse(printed.contains("ChatGPT Agentic"), "the mark says that part")
        XCTAssertEqual(boxes.filter { if case .image = $0.content { return true } else { return false } }.count, 2)
        for box in boxes {
            guard box.clipsContent, case let .text(value, font, _) = box.content else { continue }
            XCTAssertLessThanOrEqual(EInkTextMetrics.width(value, font: font), box.frame.width, value)
        }
    }

    /// Every quota layout, every orientation: a mark never pushes anything
    /// out of the panel or into a box too small for it.
    func testEveryQuotaPresetDrawsTheMarkWithoutClippingAnything() throws {
        let snapshot = snapshot()
        let safe = EInkInsets(all: Int(EInkCanvasLayout.safeMargin))
        for style in EInkSlotLabelStyle.allCases where style.drawsLogo {
            for preset in EInkPreset.allCases where preset.isQuotaPreset {
                for orientation in EInkOrientation.allCases {
                    let count = min(5, preset.capacity(for: orientation))
                    let boxes = try drawn(
                        preset,
                        orientation,
                        snapshot: snapshot,
                        options: options(style),
                        count: count
                    )
                    let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
                    let bounds = EInkRect(x: 0, y: 0, width: size.width, height: size.height).inset(by: safe)
                    let label = "\(style.rawValue)/\(preset.rawValue)/\(orientation.rawValue)°"
                    for box in boxes {
                        XCTAssertTrue(bounds.contains(box.frame), "\(label): \(box.frame) escaped")
                        guard box.clipsContent, case let .text(value, font, _) = box.content else { continue }
                        XCTAssertLessThanOrEqual(
                            EInkTextMetrics.width(value, font: font),
                            box.frame.width,
                            "\(label): \"\(value)\" is cut"
                        )
                    }
                }
            }
        }
    }

    /// The marks are elements too, and the device counts them: a panel of
    /// five marked slots must still encode inside the Canvas API's budget.
    func testAMarkedPanelStaysInsideTheDevicesElementBudget() throws {
        let snapshot = snapshot()
        for style in EInkSlotLabelStyle.allCases {
            for preset in EInkPreset.allCases where preset.isQuotaPreset {
                for orientation in EInkOrientation.allCases {
                    var slide = EInkFixtures.slide(
                        preset: preset,
                        fieldIDs: Array(snapshot.quota.prefix(preset.capacity(for: orientation))).map(\.fieldID)
                    )
                    slide.options = options(style)
                    let payload = try EInkRenderer.render(
                        slide: slide,
                        device: EInkFixtures.device(orientation: orientation),
                        snapshot: snapshot,
                        calendar: EInkFixtures.calendar()
                    )
                    let label = "\(style.rawValue)/\(preset.rawValue)/\(orientation.rawValue)°"
                    XCTAssertLessThanOrEqual(
                        payload.windowData.elementCount,
                        DotCanvasEncoder.Limits.maxElements,
                        label
                    )
                    XCTAssertLessThanOrEqual(try payload.jsonData().count, 128 * 1024, label)
                }
            }
        }
    }

    /// A style whose mark the snapshot could not rasterize falls back to the
    /// words. A slot nobody can identify is worse than a long name.
    func testAMissingMarkFallsBackToTheFullName() throws {
        var bare = snapshot()
        bare.logos = [:]
        let boxes = try drawn(.quotaLedger, .degrees0, snapshot: bare, options: options(.logoOnly), count: 2)
        let printed = boxes.compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(printed.contains("ChatGPT Agentic"))
        XCTAssertFalse(boxes.contains { if case .image = $0.content { return true } else { return false } })
    }

    /// A per-slot override beats the slide's own setting, so a panel can spell
    /// out the buckets that fit and mark the ones that do not.
    func testOneSlotCanOverrideTheSlidesStyle() throws {
        let snapshot = snapshot()
        var options = EInkSlideOptions.default
        options.labelStyle = .text
        options.labelStyles = ["codex.spark_weekly": .logoAndGroup]
        XCTAssertEqual(options.labelStyle(for: "codex.spark_weekly"), .logoAndGroup)
        XCTAssertEqual(options.labelStyle(for: "claude.fable_weekly"), .text)

        let boxes = try drawn(.quotaLedger, .degrees0, snapshot: snapshot, options: options, count: 3)
        XCTAssertEqual(boxes.filter { if case .image = $0.content { return true } else { return false } }.count, 1)
    }

    /// Both snapshot builders carry the marks.
    ///
    /// The device's own refresh goes through `assemble`, not `snapshot()`, and
    /// a mark missing from that one is every configured logo style silently
    /// reverting to words on the panel — which looks exactly like the feature
    /// not existing.
    func testEverySnapshotBuilderCarriesTheMarks() async {
        let sources = EInkDataAssembler(
            quotaLookup: { tool in
                guard tool == .claude else { return nil }
                return AccountQuota(
                    accountId: "synthetic-account",
                    tool: .claude,
                    buckets: [
                        QuotaBucket(
                            id: "weekly",
                            title: "Weekly",
                            shortLabel: "7d",
                            usedPercent: 30,
                            resetAt: EInkFixtures.referenceDate.addingTimeInterval(3_600)
                        )
                    ],
                    plan: "Test Plan"
                )
            },
            usage: EInkEmptyUsageSource(),
            allTimeCostSnapshots: { [] },
            calendar: EInkFixtures.calendar()
        )
        // `includeUsage: false` is the quota-only refresh a panel of ledger
        // slides actually performs, and the one that was dropping the marks.
        let assembled = await sources.assemble(now: EInkFixtures.referenceDate, includeUsage: false).snapshot
        XCTAssertFalse(assembled.quota.isEmpty)
        XCTAssertEqual(assembled.logos, sources.marks(for: assembled.quota))
        for row in assembled.quota {
            for size in EInkLogo.sizes {
                XCTAssertNotNil(
                    assembled.logo(fieldID: row.fieldID, size: size),
                    "\(row.fieldID) has no mark at \(size) px"
                )
            }
        }
    }

    // MARK: - Persistence and the Studio

    func testTheStyleRoundTripsAndARoundOneSlideStillReadsAsWords() throws {
        var options = EInkSlideOptions.default
        options.labelStyle = .logoAndWindow
        options.labelStyles = ["claude.weekly": .logoOnly]
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(EInkSlideOptions.self, from: data)
        XCTAssertEqual(decoded, options)

        let legacy = Data("""
        {"hasHeader":true,"hasFooter":true,"slotOrder":[],"customLabels":{},"compact":false}
        """.utf8)
        let old = try JSONDecoder().decode(EInkSlideOptions.self, from: legacy)
        XCTAssertEqual(old.labelStyle, .text)
        XCTAssertTrue(old.labelStyles.isEmpty)
    }

    /// A marked slot survives "Edit in Studio": the image comes back as an
    /// element and the words beside it still follow their bucket.
    func testAMarkedSlotExplodesIntoTheSameBoxesAndKeepsItsBinding() throws {
        let snapshot = snapshot()
        var slide = EInkFixtures.slide(
            preset: .quotaLedger,
            fieldIDs: Array(snapshot.quota.prefix(3)).map(\.fieldID)
        )
        slide.options = options(.logoAndGroup)
        let layout = EInkPresetExploder.explode(
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        )
        let frame = EInkRect(x: 0, y: 0, width: 296, height: 152)
        XCTAssertEqual(
            EInkBoxLayout.resolve(
                EInkCustomLayoutRenderer.tree(
                    layout: layout,
                    slide: slide,
                    orientation: .degrees0,
                    snapshot: snapshot
                ),
                in: frame
            ),
            EInkBoxLayout.resolve(
                try EInkRenderer.tree(
                    slide: slide,
                    orientation: .degrees0,
                    snapshot: snapshot,
                    calendar: EInkFixtures.calendar()
                ),
                in: frame
            )
        )
        let slot = layout.elements.filter { $0.moduleID == "slot:codex.spark_weekly" }
        XCTAssertTrue(slot.contains { $0.kind == .image && !$0.imageSource.isEmpty }, "the mark is an element")
        let words = try XCTUnwrap(slot.first { $0.textBinding == .label && $0.labelPart == .window })
        XCTAssertEqual(
            EInkCustomLayoutRenderer.text(for: words, snapshot: snapshot),
            "GPT-5.3 Codex Spark · Weekly"
        )
    }
}
