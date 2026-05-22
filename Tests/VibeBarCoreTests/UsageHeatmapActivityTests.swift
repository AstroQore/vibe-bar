import XCTest
@testable import VibeBarCore

final class UsageHeatmapActivityTests: XCTestCase {
    // MARK: - formatHourLabel

    func testFormatHourLabelMidnight() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(0), "12am")
    }

    func testFormatHourLabelNoon() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(12), "12pm")
    }

    func testFormatHourLabelMorning() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(3), "3am")
        XCTAssertEqual(UsageHeatmap.formatHourLabel(11), "11am")
    }

    func testFormatHourLabelAfternoon() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(15), "3pm")
        XCTAssertEqual(UsageHeatmap.formatHourLabel(23), "11pm")
    }

    // MARK: - hourTotals

    func testHourTotalsSumsColumns() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][3] = 10
        cells[1][3] = 20
        cells[2][3] = 30
        cells[0][15] = 1
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 61)
        let totals = heatmap.hourTotals
        XCTAssertEqual(totals.count, 24)
        XCTAssertEqual(totals[3], 60)
        XCTAssertEqual(totals[15], 1)
        XCTAssertEqual(totals[0], 0)
    }

    // MARK: - peakHour

    func testPeakHourOfEmptyHeatmapIsNil() {
        let heatmap = UsageHeatmap.empty(tool: .claude)
        XCTAssertNil(heatmap.peakHour)
    }

    func testPeakHourReturnsHourOfHighestColumnTotal() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][9] = 5
        cells[1][9] = 5
        cells[0][15] = 11
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 21)
        XCTAssertEqual(heatmap.peakHour, 15)
    }

    func testPeakHourTieReturnsEarliestHour() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][7] = 10
        cells[0][20] = 10
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 20)
        XCTAssertEqual(heatmap.peakHour, 7)
    }

    // MARK: - peakCell

    func testPeakCellOfEmptyHeatmapIsNil() {
        let heatmap = UsageHeatmap.empty(tool: .claude)
        XCTAssertNil(heatmap.peakCell)
    }

    func testPeakCellReturnsWeekdayAndHourOfMaxCell() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][9] = 30
        cells[4][15] = 90 // Thu 3pm — biggest single cell
        cells[5][3] = 50
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 170)
        let peak = heatmap.peakCell
        XCTAssertEqual(peak?.weekday, 4)
        XCTAssertEqual(peak?.hour, 15)
    }

    func testPeakCellTieReturnsFirstScannedCell() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[2][10] = 50
        cells[5][3] = 50
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 100)
        let peak = heatmap.peakCell
        // Scanning order is weekday 0..7, hour 0..24 → (2, 10) wins over (5, 3).
        XCTAssertEqual(peak?.weekday, 2)
        XCTAssertEqual(peak?.hour, 10)
    }
}
