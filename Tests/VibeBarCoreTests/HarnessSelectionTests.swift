import XCTest
@testable import VibeBarCore

/// The harness filter-chip arithmetic shared by Usage Stats and Sessions.
///
/// Both pages draw the same chip row, and both used to re-implement these
/// rules on their own view model. They call `HarnessSelection` now, so this
/// is where the behaviour is pinned: `nil` means every harness, `[]` means
/// none, and the All chip is a switch between the two.
final class HarnessSelectionTests: XCTestCase {
    private let options = Harness.allCases

    // MARK: - States

    func testNilIsEverythingAndEmptyIsNothing() {
        XCTAssertTrue(HarnessSelection.isEverything(nil, options: options))
        XCTAssertFalse(HarnessSelection.isNothing(nil))

        XCTAssertFalse(HarnessSelection.isEverything([], options: options))
        XCTAssertTrue(HarnessSelection.isNothing([]))

        XCTAssertTrue(HarnessSelection.isEverything(Set(options), options: options))
        XCTAssertFalse(HarnessSelection.isNothing(Set(options)))

        XCTAssertFalse(HarnessSelection.isEverything([.codex], options: options))
        XCTAssertFalse(HarnessSelection.isNothing([.codex]))
    }

    // MARK: - The All chip

    /// The whole point of the change: clicking All while everything is lit
    /// has to be able to say "none", which an empty-means-unfiltered model
    /// could not express.
    func testAllChipTogglesBetweenEverythingAndNothing() {
        XCTAssertEqual(HarnessSelection.toggleAll(nil, options: options), [])
        XCTAssertEqual(HarnessSelection.toggleAll([], options: options), nil)
    }

    /// A set that happens to hold every option is the same statement as
    /// `nil`, so All has to clear it rather than "select all" again.
    func testAllChipClearsAnExplicitlyCompleteSelection() {
        XCTAssertEqual(HarnessSelection.toggleAll(Set(options), options: options), [])
    }

    func testAllChipRestoresEverythingFromAPartialSelection() {
        XCTAssertEqual(
            HarnessSelection.toggleAll([.codex, .claudeCode], options: options),
            nil
        )
    }

    /// Two clicks land back where they started, in both directions.
    func testAllChipRoundTrips() {
        let cleared = HarnessSelection.toggleAll(nil, options: options)
        XCTAssertEqual(HarnessSelection.toggleAll(cleared, options: options), nil)

        let restored = HarnessSelection.toggleAll([.cursor], options: options)
        XCTAssertEqual(HarnessSelection.toggleAll(restored, options: options), [])
    }

    // MARK: - Solo

    func testSoloKeepsOnlyTheClickedHarness() {
        XCTAssertEqual(HarnessSelection.solo(.cursor, options: options), [.cursor])
        XCTAssertEqual(HarnessSelection.solo(.codex, options: options), [.codex])
    }

    /// On a page that only knows one harness, soloing it *is* "everything",
    /// and everything is spelled `nil`.
    func testSoloOnTheOnlyOptionCollapsesToUnfiltered() {
        XCTAssertEqual(HarnessSelection.solo(.codex, options: [.codex]), nil)
    }

    // MARK: - Plain toggling

    func testToggleTurnsOneHarnessOffFromEverything() {
        let next = HarnessSelection.toggle([.cursor], in: nil, options: options)
        XCTAssertEqual(next, Set(options).subtracting([.cursor]))
    }

    func testToggleTurnsOneHarnessBackOn() {
        let next = HarnessSelection.toggle([.cursor], in: [.codex], options: options)
        XCTAssertEqual(next, [.codex, .cursor])
    }

    /// Turning the last lit chip off lands in the explicit empty state rather
    /// than silently re-selecting everything.
    func testTurningOffTheLastHarnessSelectsNothing() {
        XCTAssertEqual(HarnessSelection.toggle([.codex], in: [.codex], options: options), [])
    }

    /// …and turning the last dark chip on collapses back to unfiltered, so
    /// the All chip lights up again.
    func testTurningOnTheLastHarnessCollapsesToUnfiltered() {
        let missingOne = Set(options).subtracting([.grokBot])
        XCTAssertEqual(
            HarnessSelection.toggle([.grokBot], in: missingOne, options: options),
            nil
        )
    }

    /// The company section head keeps its toggle-group behaviour: it moves
    /// its whole group, and only its whole group.
    func testCompanyGroupTogglesAsOneUnit() {
        let anthropic: Set<Harness> = [.claudeCode, .claudeCowork]

        let off = HarnessSelection.toggle(anthropic, in: nil, options: options)
        XCTAssertEqual(off, Set(options).subtracting(anthropic))

        let backOn = HarnessSelection.toggle(anthropic, in: off, options: options)
        XCTAssertEqual(backOn, nil)
    }

    /// A partially lit group turns fully on, not off — otherwise clicking the
    /// section head of a group with one chip lit would appear to do nothing.
    func testPartiallySelectedCompanyGroupTurnsFullyOn() {
        let openAI: Set<Harness> = [.codex, .chatgptWork]
        let next = HarnessSelection.toggle(openAI, in: [.codex], options: options)
        XCTAssertEqual(next, openAI)
    }

    func testTogglingNothingIsANoOp() {
        XCTAssertEqual(HarnessSelection.toggle([], in: [.codex], options: options), [.codex])
        XCTAssertEqual(HarnessSelection.toggle([], in: nil, options: options), nil)
    }

    // MARK: - Normalization

    func testNormalizationFoldsACompleteSetButKeepsAnEmptyOne() {
        XCTAssertEqual(HarnessSelection.normalized(Set(options), options: options), nil)
        XCTAssertEqual(HarnessSelection.normalized([], options: options), [])
        XCTAssertEqual(HarnessSelection.normalized(nil, options: options), nil)
        XCTAssertEqual(HarnessSelection.normalized([.codex], options: options), [.codex])
    }

    /// Usage Stats narrows the options to the harnesses its ledger has
    /// actually seen, so "everything" is relative to that list.
    func testCompletenessIsRelativeToTheOfferedOptions() {
        let offered: [Harness] = [.codex, .claudeCode]
        XCTAssertTrue(HarnessSelection.isEverything([.codex, .claudeCode], options: offered))
        XCTAssertEqual(
            HarnessSelection.toggle([.codex], in: [.claudeCode], options: offered),
            nil
        )
        XCTAssertEqual(HarnessSelection.toggleAll(nil, options: offered), [])
    }
}
