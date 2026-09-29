import XCTest
@testable import VibeBarCore

final class SkillAdoptionSelectionTests: XCTestCase {
    func testSeedAlwaysKeepsTheHarnessTheFolderWasFoundIn() {
        // Codex as the only default must not drop Claude for a folder found
        // under Claude: Claude would keep loading its own copy while the
        // registry recorded it as unselected.
        XCTAssertEqual(
            SkillAdoptionSelection.seed(foundIn: [.claude], defaults: [.codex]),
            [.claude, .codex]
        )
        XCTAssertEqual(
            SkillAdoptionSelection.seed(foundIn: [.claude, .gemini], defaults: []),
            [.claude, .gemini]
        )
    }

    func testCopyingASelectionKeepsEachRowsOwnSources() {
        XCTAssertEqual(
            SkillAdoptionSelection.copy([.codex], onto: [.grok]),
            [.codex, .grok]
        )
        XCTAssertEqual(
            SkillAdoptionSelection.copy([.codex, .claude], onto: [.claude]),
            [.codex, .claude]
        )
    }
}
