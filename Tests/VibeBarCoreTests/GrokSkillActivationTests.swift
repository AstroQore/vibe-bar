import XCTest
@testable import VibeBarCore

/// Grok Build filters the shared skills root by name with a `disabled`
/// array inside its `[skills]` table in `~/.grok/config.toml`. The CLI
/// writes that array one name per line, so the reader must accept the
/// multi-line form and the writer must replace all of it.
final class GrokSkillActivationTests: XCTestCase {
    private func configURL(_ home: SkillTestHome) -> URL {
        home.url.appendingPathComponent(".grok/config.toml")
    }

    private func skill(_ name: String) -> Skill {
        Skill(id: .local(directory: name), name: name, directory: name, installedAt: .distantPast)
    }

    private let multiLine = """
    [skills]
    disabled = [
        "alpha", # hand-picked
        "beta",
    ]
    paths = []

    [privacy]
    privacy_banner_acked = "2026-01-01T00:00:00Z"
    """

    func testMultiLineDisabledArraysAreRead() throws {
        let home = try SkillTestHome()
        try home.write(multiLine, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        let states = manager.grokStates(for: [skill("alpha"), skill("beta"), skill("gamma")])
        XCTAssertEqual(states["alpha"], .disabled)
        XCTAssertEqual(states["beta"], .disabled)
        XCTAssertEqual(states["gamma"], .enabled)
    }

    func testEnablingRewritesTheWholeMultiLineArray() throws {
        let home = try SkillTestHome()
        try home.write(multiLine, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(true, directoryName: "alpha", skillName: "alpha", app: .grok)

        let rewritten = try XCTUnwrap(home.contents(of: configURL(home)))
        XCTAssertEqual(rewritten, """
        [skills]
        disabled = ["beta"]
        paths = []

        [privacy]
        privacy_banner_acked = "2026-01-01T00:00:00Z"
        """)
        let states = manager.grokStates(for: [skill("alpha"), skill("beta")])
        XCTAssertEqual(states["alpha"], .enabled)
        XCTAssertEqual(states["beta"], .disabled)
    }

    func testAValueThatIsNotAStringArrayIsUnknownAndUntouched() throws {
        let home = try SkillTestHome()
        let original = "[skills]\ndisabled = \"alpha\"\n"
        try home.write(original, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        XCTAssertEqual(manager.grokStates(for: [skill("alpha")])["alpha"], .unknown)
        XCTAssertThrowsError(
            try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "alpha", app: .grok)
        )
        XCTAssertEqual(home.contents(of: configURL(home)), original)
    }

    func testDuplicateDirectoriesNeverTrapTheStateLookup() throws {
        let home = try SkillTestHome()
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        let twins = [skill("alpha"), skill("alpha")]
        XCTAssertEqual(manager.grokStates(for: twins).count, 1)
        XCTAssertEqual(manager.codexStates(for: twins).count, 1)
        XCTAssertEqual(manager.claudeStates(for: twins).count, 1)
        XCTAssertEqual(manager.geminiStates(for: twins).count, 1)
        XCTAssertEqual(manager.museStates(for: twins).count, 1)
        XCTAssertEqual(manager.mistralVibeStates(for: twins).count, 1)
    }
}
