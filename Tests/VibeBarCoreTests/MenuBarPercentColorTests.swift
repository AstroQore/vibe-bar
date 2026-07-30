import XCTest
@testable import VibeBarCore

final class MenuBarPercentColorTests: XCTestCase {
    /// Every verdict the forecast can produce. `Verdict` is not `CaseIterable`,
    /// so the list is spelled out — a new case fails to compile here, which is
    /// the point.
    private static let allVerdicts: [QuotaPaceForecast.Verdict] = [
        .enough, .surplus, .watch, .atRisk, .learning
    ]

    private func resolve(
        _ basis: MenuBarColorBasis,
        _ verdict: QuotaPaceForecast.Verdict?,
        _ percent: Double,
        _ mode: DisplayMode
    ) -> MenuBarPercentColor {
        MenuBarPercentColor.resolve(
            basis: basis,
            verdict: verdict,
            percent: percent,
            displayMode: mode
        )
    }

    // MARK: - Actual basis

    func testActualBasisMatchesLegacyRemainingThresholds() {
        // Exactly the boundaries the pre-forecast menu bar used: < 10 red,
        // < 30 orange, otherwise green. Regression fence for "Actual" being
        // a true opt-back-in rather than a new palette.
        let cases: [(Double, MenuBarPercentColor)] = [
            (0, .risk),
            (9.9, .risk),
            (10, .watch),
            (29.9, .watch),
            (30, .healthy),
            (100, .healthy)
        ]
        for (percent, expected) in cases {
            XCTAssertEqual(
                resolve(.actual, nil, percent, .remaining),
                expected,
                "remaining \(percent)"
            )
        }
    }

    func testActualBasisMatchesLegacyUsedThresholds() {
        let cases: [(Double, MenuBarPercentColor)] = [
            (0, .healthy),
            (69.9, .healthy),
            (70, .watch),
            (89.9, .watch),
            (90, .risk),
            (100, .risk)
        ]
        for (percent, expected) in cases {
            XCTAssertEqual(
                resolve(.actual, nil, percent, .used),
                expected,
                "used \(percent)"
            )
        }
    }

    func testActualBasisIgnoresEveryVerdict() {
        // The forecast may be fully converged and still must not touch the
        // color once the user asked for raw thresholds.
        for verdict in Self.allVerdicts {
            XCTAssertEqual(resolve(.actual, verdict, 5, .remaining), .risk)
            XCTAssertEqual(resolve(.actual, verdict, 55, .remaining), .healthy)
            XCTAssertEqual(resolve(.actual, verdict, 95, .used), .risk)
            XCTAssertEqual(resolve(.actual, verdict, 5, .used), .healthy)
        }
    }

    func testActualBasisNeverReportsSurplus() {
        for percent in stride(from: 0.0, through: 100.0, by: 0.5) {
            for mode in DisplayMode.allCases {
                XCTAssertNotEqual(resolve(.actual, nil, percent, mode), .surplus)
            }
        }
    }

    // MARK: - Forecast basis

    func testForecastBasisMapsVerdictsRegardlessOfPercentOrMode() {
        let mapping: [(QuotaPaceForecast.Verdict, MenuBarPercentColor)] = [
            (.enough, .healthy),
            (.surplus, .surplus),
            (.watch, .watch),
            (.atRisk, .risk)
        ]
        for (verdict, expected) in mapping {
            for percent in [0.0, 9.0, 24.0, 30.0, 70.0, 90.0, 100.0] {
                for mode in DisplayMode.allCases {
                    XCTAssertEqual(
                        resolve(.forecast, verdict, percent, mode),
                        expected,
                        "\(verdict) at \(percent) \(mode)"
                    )
                }
            }
        }
    }

    func testForecastBasisTurnsALowButSurvivableQuotaGreen() {
        // The reported case: 24% remaining, reset hours away, forecast says it
        // lasts. Raw thresholds call that orange; the forecast basis must not.
        XCTAssertEqual(resolve(.actual, .enough, 24, .remaining), .watch)
        XCTAssertEqual(resolve(.forecast, .enough, 24, .remaining), .healthy)
    }

    func testForecastBasisWithoutAVerdictFallsBackToThresholds() {
        // No account, or no observations recorded yet. A menu bar cannot show
        // "unknown" — a gray percentage reads as a broken app.
        for (percent, mode, expected) in [
            (5.0, DisplayMode.remaining, MenuBarPercentColor.risk),
            (20.0, DisplayMode.remaining, MenuBarPercentColor.watch),
            (80.0, DisplayMode.remaining, MenuBarPercentColor.healthy),
            (95.0, DisplayMode.used, MenuBarPercentColor.risk),
            (75.0, DisplayMode.used, MenuBarPercentColor.watch),
            (10.0, DisplayMode.used, MenuBarPercentColor.healthy)
        ] {
            XCTAssertEqual(resolve(.forecast, nil, percent, mode), expected)
        }
    }

    func testForecastBasisWhileLearningFallsBackToThresholds() {
        // Same constraint as a missing verdict: until the forecast converges
        // the thresholds are the only thing left to say.
        for (percent, mode, expected) in [
            (5.0, DisplayMode.remaining, MenuBarPercentColor.risk),
            (20.0, DisplayMode.remaining, MenuBarPercentColor.watch),
            (80.0, DisplayMode.remaining, MenuBarPercentColor.healthy),
            (95.0, DisplayMode.used, MenuBarPercentColor.risk),
            (75.0, DisplayMode.used, MenuBarPercentColor.watch),
            (10.0, DisplayMode.used, MenuBarPercentColor.healthy)
        ] {
            XCTAssertEqual(resolve(.forecast, .learning, percent, mode), expected)
            XCTAssertEqual(
                resolve(.forecast, .learning, percent, mode),
                resolve(.actual, nil, percent, mode)
            )
        }
    }

    // MARK: - Basis enum

    func testColorBasisRawValuesAreStable() {
        // Persisted in settings.json — renaming a raw value silently resets
        // the user's choice.
        XCTAssertEqual(MenuBarColorBasis.forecast.rawValue, "forecast")
        XCTAssertEqual(MenuBarColorBasis.actual.rawValue, "actual")
        XCTAssertEqual(MenuBarColorBasis.allCases, [.forecast, .actual])
    }

    func testForecastBasisCaptionNamesEveryColorItCanPaint() {
        // The menu bar shows a bare colored number, so this caption is the only
        // legend the feature has — blue especially cannot be guessed.
        let detail = MenuBarColorBasis.forecast.detail.lowercased()
        for word in ["green", "blue", "orange", "red"] {
            XCTAssertTrue(detail.contains(word), "caption omits \(word)")
        }
    }
}
