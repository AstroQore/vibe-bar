import Foundation
import XCTest
@testable import VibeBarCore

final class ResetCountdownFormatterTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!
    private var restoreLanguage: AppLanguage!

    // Every string below is a rendered date, and a rendered date follows
    // `AppSettings.language`. Pinning it makes the expectations mean what they
    // say instead of whatever the machine running the suite is set to.
    override func setUp() {
        super.setUp()
        restoreLanguage = L10n.languageOverride
        L10n.languageOverride = .english
    }

    override func tearDown() {
        L10n.languageOverride = restoreLanguage
        super.tearDown()
    }

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
            "3d 4h · Fri, Jul 24 at 12:00"
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
            "2h · Fri, Jan 1, 2027 at 01:00"
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
        XCTAssertEqual(status?.label, "Resets in 3h 5m · 17:05")
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
        XCTAssertEqual(status?.label, "Resets in now · 17:05")
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
        XCTAssertEqual(status?.label, "reset passed · Mon, Aug 17 at 17:05")
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

    // MARK: - The format table

    /// One row per format, so the table is readable as a table.
    func testEachFormatPrintsTheComponentsItNames() {
        let now = date(2026, 7, 21, 8, 0)
        let reset = date(2026, 7, 24, 12, 0)

        let expected: [ResetTimeFormat: String] = [
            .time: "12:00",
            .weekdayTime: "Fri 12:00",
            .date: "Jul 24",
            .dateTime: "Jul 24 at 12:00",
            .weekdayDateTime: "Fri, Jul 24 at 12:00",
            .automatic: "Fri, Jul 24 at 12:00"
        ]
        for (format, string) in expected {
            XCTAssertEqual(absolute(reset, now: now, format: format), string, "\(format)")
        }
    }

    /// `.automatic` drops what the countdown beside it already says. This is
    /// why a five-hour window's row is no wider than it was before every
    /// reset time started naming a weekday.
    func testAutomaticPrintsOnlyTheTimeWhileTheResetIsStillToday() {
        let now = date(2026, 7, 21, 8, 0)
        XCTAssertEqual(absolute(date(2026, 7, 21, 18, 30), now: now, format: .automatic), "18:30")
        XCTAssertEqual(
            absolute(date(2026, 7, 21, 18, 30), now: now, format: .weekdayDateTime),
            "Tue, Jul 21 at 18:30"
        )
    }

    /// The year is the renderer's call, not the user's: a reset in another
    /// year has to say so whichever format was picked. A format carrying no
    /// date has nowhere to put one.
    func testAYearAppearsOnlyWhenTheResetIsInAnotherOne() {
        let now = date(2026, 12, 31, 23, 0)
        let reset = date(2027, 1, 1, 1, 0)
        XCTAssertEqual(absolute(reset, now: now, format: .dateTime), "Jan 1, 2027 at 01:00")
        XCTAssertEqual(absolute(reset, now: now, format: .date), "Jan 1, 2027")
        XCTAssertEqual(absolute(reset, now: now, format: .weekdayTime), "Fri 01:00")
    }

    /// The reason the shape is a CLDR skeleton and not an assembled string:
    /// Chinese puts the weekday *after* the date and the year before the
    /// month, and no call site in this app knows that.
    func testChineseOrdersTheSamePartsItsOwnWay() {
        L10n.languageOverride = .simplifiedChinese
        let now = date(2026, 7, 21, 8, 0)
        let reset = date(2026, 7, 24, 12, 0)

        XCTAssertEqual(absolute(reset, now: now, format: .weekdayDateTime), "7月24日 周五 12:00")
        XCTAssertEqual(absolute(reset, now: now, format: .weekdayTime), "周五 12:00")
    }

    private func absolute(_ reset: Date, now: Date, format: ResetTimeFormat) -> String {
        ResetCountdownFormatter.absoluteTime(
            for: reset,
            now: now,
            format: format,
            calendar: calendar,
            timeZone: timeZone
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
