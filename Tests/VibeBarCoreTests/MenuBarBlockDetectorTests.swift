import XCTest
@testable import VibeBarCore

/// `MenuBarBlockDetector` recognizes the macOS 26 state where Control Center's
/// per-bundle-id allow-list silently blocks our status item: AppKit reports the
/// item as visible with a real window, but the system left that window at the
/// legacy 22pt default instead of placing it into a menu bar.
///
/// The constants below are measured values from the machine where this was
/// diagnosed — notched built-in with a 39pt bar, external display with a 30pt
/// bar, `NSStatusBar.thickness` of 22. A healthy item's window matched the bar
/// it sat in (30); a blocked one sat at 22 with occlusion missing `.visible`.
final class MenuBarBlockDetectorTests: XCTestCase {
    private let detector = MenuBarBlockDetector()

    private func probe(
        isVisible: Bool = true,
        hasButton: Bool = true,
        hasWindow: Bool = true,
        occlusionVisible: Bool = false,
        windowHeight: CGFloat = 22,
        statusBarThickness: CGFloat = 22,
        menuBarHeights: [CGFloat] = [39, 30]
    ) -> MenuBarItemProbe {
        MenuBarItemProbe(
            isVisible: isVisible,
            hasButton: hasButton,
            hasWindow: hasWindow,
            occlusionVisible: occlusionVisible,
            windowHeight: windowHeight,
            statusBarThickness: statusBarThickness,
            menuBarHeights: menuBarHeights
        )
    }

    func testStubHeightWhileBarsAreTallerIsBlocked() {
        XCTAssertEqual(detector.verdict(for: probe()), .blocked)
    }

    func testItemPlacedInItsBarIsHealthy() {
        let healthy = probe(occlusionVisible: true, windowHeight: 30)
        XCTAssertEqual(detector.verdict(for: healthy), .healthy)
    }

    /// The item sits in a 30pt bar but something covers it — a full-screen app
    /// on that display, or a menu bar mid-auto-hide. It was placed correctly,
    /// so this is not our failure.
    func testHiddenAtBarHeightIsInconclusive() {
        let covered = probe(occlusionVisible: false, windowHeight: 30)
        XCTAssertEqual(detector.verdict(for: covered), .inconclusive)
    }

    /// No bar on any screen: nothing can be visible, so hiding proves nothing.
    func testNoMenuBarAnywhereIsInconclusive() {
        XCTAssertEqual(detector.verdict(for: probe(menuBarHeights: [])), .inconclusive)
        XCTAssertEqual(detector.verdict(for: probe(menuBarHeights: [0, 0])), .inconclusive)
    }

    func testItemWeNeverAskedToShowIsInconclusive() {
        XCTAssertEqual(detector.verdict(for: probe(isVisible: false)), .inconclusive)
    }

    func testWindowNotYetMaterializedIsInconclusive() {
        XCTAssertEqual(detector.verdict(for: probe(hasWindow: false)), .inconclusive)
        XCTAssertEqual(detector.verdict(for: probe(hasButton: false)), .inconclusive)
    }

    /// A Mac whose only bar is as short as the stub gives us nothing to
    /// separate the two states with.
    func testBarNoTallerThanTheStubIsInconclusive() {
        XCTAssertEqual(detector.verdict(for: probe(menuBarHeights: [22])), .inconclusive)
    }

    /// Only the built-in has a bar right now (the external is running a
    /// full-screen app), and our 30pt window lives on the external. It is
    /// taller than the stub, so it was placed — no alarm.
    func testWindowTallerThanStubOnAPartlyCoveredSetupIsInconclusive() {
        let partial = probe(windowHeight: 30, menuBarHeights: [39])
        XCTAssertEqual(detector.verdict(for: partial), .inconclusive)
    }

    // MARK: - Evaluator

    func testEvaluatorRequiresConsecutiveConfirmations() {
        var evaluator = MenuBarBlockEvaluator(confirmationsRequired: 3)
        XCTAssertFalse(evaluator.record(probe()))
        XCTAssertFalse(evaluator.record(probe()))
        XCTAssertTrue(evaluator.record(probe()), "third consecutive probe confirms")
    }

    func testEvaluatorReportsOnlyOncePerStreak() {
        var evaluator = MenuBarBlockEvaluator(confirmationsRequired: 2)
        _ = evaluator.record(probe())
        XCTAssertTrue(evaluator.record(probe()))
        XCTAssertFalse(evaluator.record(probe()), "must not nag on every later probe")
        XCTAssertFalse(evaluator.record(probe()))
    }

    func testInconclusiveProbeBreaksTheStreak() {
        var evaluator = MenuBarBlockEvaluator(confirmationsRequired: 2)
        _ = evaluator.record(probe())
        _ = evaluator.record(probe(windowHeight: 30))
        XCTAssertEqual(evaluator.consecutiveBlocked, 0)
        XCTAssertFalse(evaluator.record(probe()), "streak restarted, one probe is not enough")
    }

    /// The block relapses — Control Center rewrites those mappings whenever a
    /// hidden app re-registers its items — so recovering must re-arm the alert.
    func testRecoveryReArmsReporting() {
        var evaluator = MenuBarBlockEvaluator(confirmationsRequired: 2)
        _ = evaluator.record(probe())
        XCTAssertTrue(evaluator.record(probe()))

        XCTAssertFalse(evaluator.record(probe(occlusionVisible: true, windowHeight: 30)))
        XCTAssertFalse(evaluator.hasReported)

        _ = evaluator.record(probe())
        XCTAssertTrue(evaluator.record(probe()), "a relapse after recovery should report again")
    }
}
