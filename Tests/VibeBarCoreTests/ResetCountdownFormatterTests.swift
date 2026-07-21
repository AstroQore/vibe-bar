import Foundation
import XCTest
@testable import VibeBarCore

final class ResetCountdownFormatterTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testAbsoluteResetTimeUsesTimeOnlyForSameDay() {
        let now = date(2026, 7, 21, 8, 0)
        let reset = date(2026, 7, 21, 12, 30)

        XCTAssertEqual(
            ResetCountdownFormatter.stringWithAbsoluteTime(
                from: reset,
                now: now,
                calendar: calendar,
                timeZone: timeZone
            ),
            "4h 30m · 12:30"
        )
    }

    func testAbsoluteResetTimeIncludesDateAcrossDays() {
        let now = date(2026, 7, 21, 8, 0)
        let reset = date(2026, 7, 24, 12, 0)

        XCTAssertEqual(
            ResetCountdownFormatter.stringWithAbsoluteTime(
                from: reset,
                now: now,
                calendar: calendar,
                timeZone: timeZone
            ),
            "3d 4h · Jul 24, 12:00"
        )
    }

    func testAbsoluteResetTimeIncludesYearAcrossYears() {
        let now = date(2026, 12, 31, 23, 0)
        let reset = date(2027, 1, 1, 1, 0)

        XCTAssertEqual(
            ResetCountdownFormatter.stringWithAbsoluteTime(
                from: reset,
                now: now,
                calendar: calendar,
                timeZone: timeZone
            ),
            "2h · Jan 1, 2027, 01:00"
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
