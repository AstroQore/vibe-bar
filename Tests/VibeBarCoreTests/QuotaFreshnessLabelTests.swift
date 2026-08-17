import Foundation
import XCTest
@testable import VibeBarCore

final class QuotaFreshnessLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailedRefreshReportsBothTheAttemptAndTheDataAge() {
        let description = QuotaFreshnessLabel.describe(
            lastSuccessAt: now.addingTimeInterval(-8 * 3_600),
            lastAttemptAt: now.addingTimeInterval(-120),
            errorMessage: "Session expired.",
            staleAfter: 600,
            now: now
        )

        XCTAssertEqual(
            description?.label,
            "Refresh failed 2m ago · data 8h old · Session expired."
        )
        XCTAssertEqual(description?.help, "Session expired.")
    }

    /// The bug this helper exists for: a refresh that fails on every cycle
    /// used to reset the displayed age, so an eight-hour-old snapshot claimed
    /// it had been "Updated just now".
    func testJustFailedRefreshStillReportsOldData() {
        let description = QuotaFreshnessLabel.describe(
            lastSuccessAt: now.addingTimeInterval(-8 * 3_600),
            lastAttemptAt: now,
            errorMessage: "Gemini Web batchexecute HTTP 401.",
            staleAfter: 600,
            now: now
        )

        XCTAssertEqual(
            description?.label,
            "Refresh failed · data 8h old · Gemini Web batchexecute HTTP 401."
        )
        XCTAssertFalse(description?.label.contains("just now") ?? true)
    }

    func testStaleDataWithoutAnErrorReportsTheSuccessAge() {
        let description = QuotaFreshnessLabel.describe(
            lastSuccessAt: now.addingTimeInterval(-45 * 60),
            lastAttemptAt: now.addingTimeInterval(-45 * 60),
            errorMessage: nil,
            staleAfter: 600,
            now: now
        )

        XCTAssertEqual(description?.label, "Stale · updated 45m ago")
        XCTAssertEqual(description?.help, QuotaFreshnessLabel.defaultHelp)
    }

    func testRecentSuccessProducesNoWarning() {
        XCTAssertNil(QuotaFreshnessLabel.describe(
            lastSuccessAt: now.addingTimeInterval(-30),
            lastAttemptAt: now.addingTimeInterval(-30),
            errorMessage: nil,
            staleAfter: 600,
            now: now
        ))
    }

    func testAccountThatNeverRefreshedProducesNoWarning() {
        XCTAssertNil(QuotaFreshnessLabel.describe(
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            errorMessage: nil,
            staleAfter: 600,
            now: now
        ))
    }

    func testFailureWithoutAnyCachedDataSaysSo() {
        let description = QuotaFreshnessLabel.describe(
            lastSuccessAt: nil,
            lastAttemptAt: now.addingTimeInterval(-90),
            errorMessage: "Not signed in.",
            staleAfter: 600,
            now: now
        )

        XCTAssertEqual(
            description?.label,
            "Refresh failed 1m ago · no cached data · Not signed in."
        )
    }

    func testStaleWithoutAnySuccessEverProducesTheNeverUpdatedLabel() {
        let description = QuotaFreshnessLabel.describe(
            lastSuccessAt: nil,
            lastAttemptAt: now.addingTimeInterval(-90),
            errorMessage: nil,
            staleAfter: 600,
            now: now
        )

        XCTAssertEqual(description?.label, "Stale · never updated")
    }

    func testLongProviderMessageIsTruncatedInTheLabelButNotTheTooltip() {
        let message = String(repeating: "quota detail ", count: 12)
            .trimmingCharacters(in: .whitespaces)
        let description = QuotaFreshnessLabel.describe(
            lastSuccessAt: now.addingTimeInterval(-3_600),
            lastAttemptAt: now.addingTimeInterval(-10),
            errorMessage: message,
            staleAfter: 600,
            now: now
        )

        XCTAssertEqual(description?.help, message)
        XCTAssertTrue(description?.label.hasSuffix("…") ?? false)
        XCTAssertLessThan(description?.label.count ?? .max, message.count)
    }

    func testCompactAgeUsesOneUnit() {
        XCTAssertEqual(QuotaFreshnessLabel.compactAge(0), "0s")
        XCTAssertEqual(QuotaFreshnessLabel.compactAge(59), "59s")
        XCTAssertEqual(QuotaFreshnessLabel.compactAge(60), "1m")
        XCTAssertEqual(QuotaFreshnessLabel.compactAge(3_600), "1h")
        XCTAssertEqual(QuotaFreshnessLabel.compactAge(8 * 3_600), "8h")
        XCTAssertEqual(QuotaFreshnessLabel.compactAge(50 * 3_600), "2d")
    }
}
