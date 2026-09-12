import XCTest
@testable import VibeBarCore

/// The five layouts the owner asked for after round 1, plus the engine's own
/// alert panel.
final class EInkRoundTwoPresetTests: XCTestCase {
    private let snapshot = EInkFixtures.snapshot()

    private func payload(_ preset: EInkPreset, _ orientation: EInkOrientation) throws -> DotCanvasPayload {
        try EInkRenderer.render(
            slide: EInkFixtures.slide(preset: preset),
            device: EInkFixtures.device(orientation: orientation),
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        )
    }

    private func strings(_ preset: EInkPreset, _ orientation: EInkOrientation) throws -> [String] {
        try payload(preset, orientation).windowData.allStrings.filter { !$0.hasPrefix("data:") }
    }

    private func boxes(_ preset: EInkPreset, _ orientation: EInkOrientation) throws -> [EInkDrawBox] {
        let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
        return EInkBoxLayout.resolve(
            try EInkRenderer.tree(
                slide: EInkFixtures.slide(preset: preset),
                orientation: orientation,
                snapshot: snapshot,
                calendar: EInkFixtures.calendar()
            ),
            in: EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        )
    }

    /// Every new layout has to encode inside the device's own limits at every
    /// orientation, or it is a layout that works on a Mac and fails on a desk.
    func testEveryNewLayoutEncodesWithinTheDeviceLimitsAtEveryOrientation() throws {
        for preset in [EInkPreset.briefing, .forecast, .resets, .heatmap, .topModels, .alert] {
            for orientation in EInkOrientation.allCases {
                let payload = try payload(preset, orientation)
                XCTAssertLessThanOrEqual(
                    payload.windowData.elementCount,
                    DotCanvasEncoder.Limits.maxElements,
                    "\(preset.rawValue) at \(orientation.rawValue)°"
                )
                let boxes = try boxes(preset, orientation)
                let size = EInkDeviceProfile.quote0.frameSize(for: orientation)
                for box in boxes {
                    XCTAssertGreaterThanOrEqual(box.frame.x, 0)
                    XCTAssertGreaterThanOrEqual(box.frame.y, 0)
                    XCTAssertLessThanOrEqual(box.frame.maxX, size.width, "\(preset.rawValue)")
                    XCTAssertLessThanOrEqual(box.frame.maxY, size.height, "\(preset.rawValue)")
                }
            }
        }
    }

    // MARK: - Briefing

    func testBriefingPrintsOneLinePerSlotPlusTheTwoUsageLines() throws {
        let printed = try strings(.briefing, .degrees0)
        XCTAssertTrue(printed.contains { $0.hasPrefix("Today $") && $0.contains("requests") })
        XCTAssertTrue(printed.contains { $0.hasPrefix("7 days $") && $0.contains("busiest") })
        XCTAssertTrue(printed.contains { $0.contains("% left") || $0.contains("pace") })
        XCTAssertTrue(printed.contains("Claude · 5 Hours"))
    }

    func testBriefingUsesTwoLinesPerSlotInPortrait() throws {
        let boxes = try boxes(.briefing, .degrees90)
        let labelRow = try XCTUnwrap(boxes.first { box in
            if case let .text(value, _, _) = box.content { return value == "Claude · 5 Hours" }
            return false
        })
        let statsUnderneath = boxes.contains { box in
            guard case let .text(value, _, _) = box.content else { return false }
            return value.contains("%") && box.frame.y == labelRow.frame.maxY + 1
        }
        XCTAssertTrue(statsUnderneath, "the figures sit on their own line under the name")
    }

    // MARK: - Forecast

    func testForecastPrintsTheVerdictInFullAndARunOutTimeWhenThereIsOne() throws {
        let printed = try strings(.forecast, .degrees0)
        XCTAssertTrue(printed.contains("SURPLUS"))
        XCTAssertTrue(printed.contains { $0.hasPrefix("runs out ") })
        // "AT RISK", never "RISK" or an arrow.
        XCTAssertFalse(printed.contains { $0 == "RISK" })
    }

    /// The tick stands where the bar is expected to end up at reset, not where
    /// it is now.
    func testForecastDrawsTheProjectedTickInsideTheBar() {
        var row = EInkFixtures.quotaRows(count: 1)[0]
        row.remainingPercent = 80
        row.forecast = EInkQuotaForecast(verdict: .atRisk, projectedUsedPercent: 90, runOutAt: nil)
        let node = EInkPresets.forecastBar(row, width: 100, height: 10)
        let boxes = EInkBoxLayout.resolve(node, in: EInkRect(x: 0, y: 0, width: 296, height: 152), bounds: EInkRect(x: 0, y: 0, width: 296, height: 152))
        let ticks = boxes.filter { $0.content == .fill && $0.frame.width == 1 }
        XCTAssertEqual(ticks.count, 1)
        // 100 − 90 projected use = 10 % left, so the tick sits near the left.
        XCTAssertEqual(ticks.first?.frame.x, 10)
    }

    /// No forecast at all means no tick — an invented one would be a guess the
    /// reader cannot tell from a measurement.
    func testForecastDrawsNoTickWithoutAForecast() {
        var row = EInkFixtures.quotaRows(count: 1)[0]
        row.forecast = nil
        let node = EInkPresets.forecastBar(row, width: 100, height: 10)
        let boxes = EInkBoxLayout.resolve(node, in: EInkRect(x: 0, y: 0, width: 296, height: 152), bounds: EInkRect(x: 0, y: 0, width: 296, height: 152))
        XCTAssertFalse(boxes.contains { $0.content == .fill && $0.frame.width == 1 })
    }

    // MARK: - Resets

    func testResetsSortsBySoonestAndPrintsTheCountdownBeforeTheName() throws {
        let printed = try strings(.resets, .degrees0)
        let countdowns = printed.filter { $0.hasPrefix("in ") }
        XCTAssertFalse(countdowns.isEmpty)
        XCTAssertEqual(countdowns.first, "in 30m", "the soonest reset leads")
        XCTAssertTrue(printed.contains("NEXT SEVEN DAYS"))
    }

    func testResetsDrawsOneTickPerBucketOnItsTimeline() throws {
        let boxes = try boxes(.resets, .degrees0)
        let ticks = boxes.filter { $0.content == .fill && $0.frame.width == 2 && $0.frame.height == 7 }
        let rows = snapshot.quotaRows(fieldIDs: [], limit: EInkPreset.resets.capacity(for: .degrees0))
        XCTAssertEqual(ticks.count, rows.filter { $0.resetAt != nil }.count)
    }

    // MARK: - Heatmap

    func testHeatmapShipsOnePreThresholdedImageAndNamesTheBusiestHourInWords() throws {
        let payload = try payload(.heatmap, .degrees0)
        let images = payload.windowData.allStrings.filter { $0.hasPrefix("data:image/png") }
        XCTAssertEqual(images.count, 1, "one image, not 168 elements")
        let printed = try strings(.heatmap, .degrees0)
        XCTAssertTrue(printed.contains("busiest Tue 21:00"))
        XCTAssertTrue(printed.contains("Mon"))
    }

    func testHeatmapDotSizesComeFromQuantilesNotFromTheMaximum() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for hour in 0..<9 { cells[0][hour] = hour + 1 }
        // One enormous outlier must not flatten the other nine hours.
        cells[0][23] = 10_000_000
        let levels = EInkHeatmapRasterizer.quantileLevels(EInkHeatmap(cells: cells, totalTokens: 1))
        XCTAssertEqual(levels[0][0], 1)
        XCTAssertEqual(levels[0][8], 3)
        XCTAssertEqual(levels[0][23], 3)
        XCTAssertEqual(levels[1][0], 0, "an empty cell draws nothing")
        XCTAssertTrue(levels[0][0...8].contains(2), "the middle quantile is used")
    }

    func testHeatmapRasterizerProducesAPNGOfTheStatedSize() throws {
        let data = try EInkHeatmapRasterizer.pngData(heatmap: EInkFixtures.heatmap(), cellSize: 10, weekdaysAcross: false)
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG magic")
        let size = EInkHeatmapRasterizer.size(cellSize: 10, weekdaysAcross: false)
        XCTAssertEqual(size.width, 240)
        XCTAssertEqual(size.height, 70)
        XCTAssertThrowsError(try EInkHeatmapRasterizer.pngData(heatmap: .empty, cellSize: 1, weekdaysAcross: false))
    }

    func testAnEmptyHeatmapClaimsNoBusiestHour() {
        XCTAssertEqual(EInkHeatmap.empty.busiestLabel, "")
        XCTAssertNil(EInkHeatmap.empty.busiest)
    }

    func testSummingAddsEveryProvidersGrid() {
        let one = UsageHeatmap(tool: .claude, cells: (0..<7).map { row in (0..<24).map { _ in row } }, totalTokens: 1)
        let two = UsageHeatmap(tool: .codex, cells: (0..<7).map { row in (0..<24).map { _ in row } }, totalTokens: 1)
        let summed = EInkHeatmap.summing([one, two])
        XCTAssertEqual(summed.cells[3][0], 6)
        XCTAssertEqual(summed.cells[0][0], 0)
    }

    // MARK: - Top models

    func testTopModelsListsTodaysHeaviestAndFootersTheLeadersShare() throws {
        let printed = try strings(.topModels, .degrees0)
        XCTAssertTrue(printed.contains("claude-opus-5"))
        XCTAssertTrue(printed.contains("TOP MODEL"))
        XCTAssertTrue(printed.contains { $0.hasSuffix("% of today's cost") })
        XCTAssertEqual(
            printed.filter { $0.hasPrefix("claude-") || $0.hasPrefix("gpt-") || $0.hasPrefix("gemini-") || $0.hasPrefix("grok-") }.count,
            EInkPreset.topModels.rowCount(for: .degrees0)
        )
    }

    func testTopModelsSaysSoWhenThereIsNothingRatherThanDrawingAnEmptyTable() throws {
        var empty = snapshot
        empty.topModels = []
        let tree = EInkRenderer.presetTree(
            .topModels,
            slide: EInkFixtures.slide(preset: .topModels),
            orientation: .degrees0,
            snapshot: empty,
            frame: EInkRect(x: 0, y: 0, width: 296, height: 152)
        )
        let printed = EInkBoxLayout.resolve(tree, in: EInkRect(x: 0, y: 0, width: 296, height: 152)).compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(printed.contains("NO MODEL ACTIVITY TODAY"))
    }

    // MARK: - Alert

    func testTheAlertSlideNamesTheOffendingBucketAndItsRunOutTime() throws {
        let slide = EInkAlertEvaluator.alertSlide(fieldID: "cursor.models")
        let tree = try EInkRenderer.tree(
            slide: slide,
            orientation: .degrees0,
            snapshot: snapshot,
            calendar: EInkFixtures.calendar()
        )
        let printed = EInkBoxLayout.resolve(tree, in: EInkRect(x: 0, y: 0, width: 296, height: 152)).compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        // Two centred lines: the SubProvider, then the rest of the name.
        XCTAssertTrue(printed.contains("CURSOR"))
        XCTAssertTrue(printed.contains("MODELS"))
        XCTAssertTrue(printed.contains { $0.hasPrefix("RUNS OUT ") || $0.hasSuffix("% LEFT") })
        XCTAssertTrue(printed.contains { $0.hasPrefix("RESETS IN ") })
    }

    /// The alert is the engine's, so it never appears in a picker.
    func testTheAlertLayoutIsNotUserSelectable() {
        XCTAssertFalse(EInkPreset.userSelectable.contains(.alert))
        XCTAssertTrue(EInkPreset.allCases.contains(.alert))
    }
}
