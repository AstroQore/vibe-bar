import XCTest
@testable import VibeBarCore

/// `SkillHarnessWiring` is pure derivation over `Skill` + the catalog tables,
/// so these tests pin the three shapes the popover distinguishes: shared-root
/// with no switch (Cursor), projection plus native switch (Claude), and the
/// AntiGravity-through-Gemini compatibility read.
final class SkillWiringTests: XCTestCase {
    private func makeSkill(apps: [SkillAppTarget: SkillMaterialization] = [:]) -> Skill {
        Skill(
            id: .local(directory: "pdf"),
            name: "PDF Tools",
            directory: "pdf",
            installedAt: Date(timeIntervalSince1970: 0),
            apps: apps
        )
    }

    func testCursorWiringIsSharedRootWithNoSwitch() {
        let wiring = makeSkill().wiring(for: .cursor)
        XCTAssertEqual(wiring.state, .coupled)
        XCTAssertTrue(wiring.discoversSharedRoot)
        XCTAssertNil(wiring.projection)
        XCTAssertNil(wiring.nativeConfigPath)
        XCTAssertNil(wiring.nativeConfigKey)
        XCTAssertEqual(wiring.projectionPath, "~/.cursor/skills/pdf")
        XCTAssertEqual(wiring.sourcePath, "~/.agents/skills/pdf")
        XCTAssertFalse(wiring.viaGeminiCompatibility)
    }

    func testClaudeWiringNamesTheProjectionAndSwitch() {
        let skill = makeSkill(apps: [.claude: SkillMaterialization(method: .symlink)])
        let wiring = skill.wiring(for: .claude)
        XCTAssertEqual(wiring.state, .enabled)
        XCTAssertFalse(wiring.discoversSharedRoot)
        XCTAssertEqual(wiring.projection?.method, .symlink)
        XCTAssertEqual(wiring.projectionPath, "~/.claude/skills/pdf")
        XCTAssertEqual(wiring.nativeConfigPath, "~/.claude/settings.json")
        XCTAssertEqual(wiring.nativeConfigKey, "skillOverrides")
    }

    func testAntigravityReportsGeminiCompatibility() {
        let skill = makeSkill(apps: [.gemini: SkillMaterialization(method: .symlink)])
        let wiring = skill.wiring(for: .antigravity)
        XCTAssertEqual(wiring.state, .coupled)
        XCTAssertTrue(wiring.viaGeminiCompatibility)
        XCTAssertNil(wiring.nativeConfigPath)
        // A direct AntiGravity projection would land in its own root, not
        // Gemini's — the path stays the direct one even while the skill is
        // only visible through compatibility.
        XCTAssertEqual(wiring.projectionPath, "~/.gemini/config/skills/pdf")
    }
}
