import XCTest
@testable import VibeBarCore

final class UsageHeatmapActivityTests: XCTestCase {
    // MARK: - formatHourLabel

    /// The label is a clock hour spelled the way the *app's* language spells
    /// one, not a hardcoded English 12-hour string: an English reader gets
    /// "3 PM", a Chinese reader "15时". Pinning the language is what makes
    /// these assertions independent of the machine's own locale.
    private func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = language
        body()
    }

    /// English day periods are joined by U+202F NARROW NO-BREAK SPACE, not by
    /// an ordinary space. Spelled as an escape rather than pasted in, because
    /// an invisible character in a literal is a test nobody can debug.
    private func englishHour(_ hour: String, _ period: String) -> String {
        "\(hour)\u{202F}\(period)"
    }

    func testFormatHourLabelMidnight() {
        withLanguage(.english) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(0), englishHour("12", "AM"))
        }
        withLanguage(.simplifiedChinese) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(0), "0时")
        }
    }

    func testFormatHourLabelNoon() {
        withLanguage(.english) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(12), englishHour("12", "PM"))
        }
        withLanguage(.simplifiedChinese) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(12), "12时")
        }
    }

    func testFormatHourLabelMorning() {
        withLanguage(.english) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(3), englishHour("3", "AM"))
            XCTAssertEqual(UsageHeatmap.formatHourLabel(11), englishHour("11", "AM"))
        }
    }

    func testFormatHourLabelAfternoon() {
        withLanguage(.english) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(15), englishHour("3", "PM"))
            XCTAssertEqual(UsageHeatmap.formatHourLabel(23), englishHour("11", "PM"))
        }
        withLanguage(.simplifiedChinese) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(15), "15时")
        }
    }

    /// An hour outside 0...23 is clamped rather than rolling into the next day.
    func testFormatHourLabelClampsOutOfRange() {
        withLanguage(.english) {
            XCTAssertEqual(UsageHeatmap.formatHourLabel(-1), englishHour("12", "AM"))
            XCTAssertEqual(UsageHeatmap.formatHourLabel(99), englishHour("11", "PM"))
        }
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
