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

    func testResetStatusCountsDownBeforeTheReset() {
        let now = date(2026, 8, 17, 14, 0)
        let reset = date(2026, 8, 17, 17, 5)

        let status = ResetCountdownFormatter.resetStatus(
            resetAt: reset,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        )

        XCTAssertEqual(status?.isExpired, false)
        XCTAssertEqual(status?.label, "resets in 3h 5m · 17:05")
    }

    /// Inside the boundary-refresh grace the row still reads as live — the
    /// scheduler is mid-handoff and a fresh snapshot is seconds away.
    func testResetStatusWithinGraceStillReadsAsLive() {
        let reset = date(2026, 8, 17, 17, 5)
        let now = reset.addingTimeInterval(120)

        let status = ResetCountdownFormatter.resetStatus(
            resetAt: reset,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        )

        XCTAssertEqual(status?.isExpired, false)
        XCTAssertEqual(status?.label, "resets in now · 17:05")
    }

    /// Past the grace the snapshot belongs to a cycle that no longer exists,
    /// so the row must stop saying "resets in now" next to a live-looking bar.
    func testResetStatusPastGraceReportsAnExpiredWindow() {
        let reset = date(2026, 8, 17, 17, 5)
        let now = date(2026, 8, 18, 1, 5)

        let status = ResetCountdownFormatter.resetStatus(
            resetAt: reset,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        )

        XCTAssertEqual(status?.isExpired, true)
        XCTAssertEqual(status?.label, "reset passed · Aug 17, 17:05")
    }

    func testResetStatusExpiresExactlyAtTheGraceBoundary() {
        let reset = date(2026, 8, 17, 17, 5)
        let grace = QuotaWindowEvaluation.postResetGraceSeconds

        XCTAssertEqual(
            ResetCountdownFormatter.resetStatus(
                resetAt: reset,
                now: reset.addingTimeInterval(grace),
                calendar: calendar,
                timeZone: timeZone
            )?.isExpired,
            false
        )
        XCTAssertEqual(
            ResetCountdownFormatter.resetStatus(
                resetAt: reset,
                now: reset.addingTimeInterval(grace + 1),
                calendar: calendar,
                timeZone: timeZone
            )?.isExpired,
            true
        )
    }

    func testResetStatusIsNilWithoutAResetTime() {
        XCTAssertNil(ResetCountdownFormatter.resetStatus(resetAt: nil, now: Date()))
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
