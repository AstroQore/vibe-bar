import XCTest
@testable import VibeBarCore

/// Mistral Vibe discovers `~/.agents/skills` itself and filters skills by name
/// with top-level `enabled_skills` / `disabled_skills` lists in
/// `~/.vibe/config.toml`. Vibe Bar only ever edits `disabled_skills`.
final class MistralVibeSkillActivationTests: XCTestCase {
    private func configURL(_ home: SkillTestHome) -> URL {
        home.url.appendingPathComponent(".vibe/config.toml")
    }

    private func skill(_ name: String) -> Skill {
        Skill(id: .local(directory: name), name: name, directory: name, installedAt: .distantPast)
    }

    func testMistralVibeIsASharedRootHarnessWithoutAProjection() throws {
        let home = try SkillTestHome()
        XCTAssertTrue(SkillAppTarget.managedHarnesses.contains(.mistralVibe))
        XCTAssertEqual(SkillAppTarget.mistralVibe.displayName, "Mistral Vibe")
        XCTAssertTrue(SkillAppTarget.mistralVibe.discoversSharedSkillRoot)
        XCTAssertFalse(SkillAppTarget.mistralVibe.supportsProjection)
        XCTAssertFalse(SkillAppCatalog.isWriteAllowed(
            home.appDirectory(.mistralVibe).appendingPathComponent("alpha"),
            homeDirectory: home.path
        ))
    }

    func testDisableAddsTheNameAboveTheFirstTableAndKeepsTheRest() throws {
        let home = try SkillTestHome()
        let original = """
        theme = "dark"
        disabled_skills = ["beta"] # keep this one

        [[models]]
        name = "mistral-vibe-cli-latest"
        """
        try home.write(original, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .mistralVibe)

        let rewritten = try XCTUnwrap(home.contents(of: configURL(home)))
        XCTAssertEqual(rewritten, """
        theme = "dark"
        disabled_skills = ["beta", "Alpha"]

        [[models]]
        name = "mistral-vibe-cli-latest"
        """)
        let states = manager.mistralVibeStates(for: [skill("alpha"), skill("beta"), skill("gamma")])
        XCTAssertEqual(states["alpha"], .disabled, "names match case-insensitively")
        XCTAssertEqual(states["beta"], .disabled)
        XCTAssertEqual(states["gamma"], .enabled)

        try manager.setNativeEnabled(true, directoryName: "alpha", skillName: "Alpha", app: .mistralVibe)
        XCTAssertEqual(manager.mistralVibeStates(for: [skill("alpha")])["alpha"], .enabled)
    }

    func testAFileWithoutTheKeyGainsItBeforeTheFirstTable() throws {
        let home = try SkillTestHome()
        try home.write("theme = \"light\"\n\n[tools.bash]\npermission = \"ask\"\n", to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(false, directoryName: "pdf", skillName: "pdf", app: .mistralVibe)

        XCTAssertEqual(home.contents(of: configURL(home)),
                       "theme = \"light\"\n\ndisabled_skills = [\"pdf\"]\n\n[tools.bash]\npermission = \"ask\"\n")
    }

    func testGlobsRegexesAndMultiLineArraysAreRead() throws {
        let home = try SkillTestHome()
        try home.write("""
        disabled_skills = [
          "cloudflare-*",
          "re:doc[sx]",
        ]
        """, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        let states = manager.mistralVibeStates(for: [skill("cloudflare-email"), skill("docx"), skill("pdf")])
        XCTAssertEqual(states["cloudflare-email"], .disabled)
        XCTAssertEqual(states["docx"], .disabled)
        XCTAssertEqual(states["pdf"], .enabled)

        try manager.setNativeEnabled(false, directoryName: "pdf", skillName: "pdf", app: .mistralVibe)
        XCTAssertEqual(home.contents(of: configURL(home)),
                       #"disabled_skills = ["cloudflare-*", "re:doc[sx]", "pdf"]"#)
    }

    /// `enabled_skills` is an allow-list that decides for every skill; Vibe
    /// Bar reports it and refuses to edit around it.
    func testAnAllowListIsReportedAndNeverEdited() throws {
        let home = try SkillTestHome()
        let original = "enabled_skills = [\"pdf\"]\n"
        try home.write(original, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        let states = manager.mistralVibeStates(for: [skill("pdf"), skill("docx")])
        XCTAssertEqual(states["pdf"], .enabled)
        XCTAssertEqual(states["docx"], .disabled)
        XCTAssertThrowsError(
            try manager.setNativeEnabled(false, directoryName: "pdf", skillName: "pdf", app: .mistralVibe)
        ) { XCTAssertEqual($0 as? SkillError, .nativeSkillsGloballyDisabled(.mistralVibe)) }
        XCTAssertThrowsError(try manager.validateCanEnable(.mistralVibe))
        XCTAssertEqual(home.contents(of: configURL(home)), original)
    }

    /// Removing the exact name is not enough when a pattern still matches:
    /// the enable is refused instead of reporting a no-op as success.
    func testAnEnableStillBlockedByAPatternIsRefused() throws {
        let home = try SkillTestHome()
        let original = "disabled_skills = [\"cloudflare-*\", \"cloudflare-email\"]\n"
        try home.write(original, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        XCTAssertThrowsError(
            try manager.setNativeEnabled(true, directoryName: "cloudflare-email", skillName: "cloudflare-email", app: .mistralVibe)
        ) { XCTAssertEqual($0 as? SkillError, .nativeSkillDisabledByPattern(.mistralVibe)) }
        XCTAssertEqual(home.contents(of: configURL(home)), original)
    }

    /// Under an allow-list a skill it does not name is already off, so an
    /// install that switches it off there succeeds without editing anything.
    func testDisablingASkillTheAllowListOmitsIsDone() throws {
        let home = try SkillTestHome()
        let original = "enabled_skills = [\"pdf\"]\n"
        try home.write(original, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        XCTAssertNoThrow(
            try manager.setNativeEnabled(false, directoryName: "docx", skillName: "docx", app: .mistralVibe)
        )
        XCTAssertNoThrow(try manager.validateCanDisable(.mistralVibe))
        XCTAssertEqual(home.contents(of: configURL(home)), original)
    }

    func testAnUnreadableConfigFailsTheDisablePreflight() throws {
        let home = try SkillTestHome()
        try home.write("disabled_skills = 'pdf'\n", to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        XCTAssertThrowsError(try manager.validateCanDisable(.mistralVibe)) {
            XCTAssertEqual($0 as? SkillError, .nativeConfigUnreadable(.mistralVibe))
        }
    }

    func testAValueThatIsNotAStringArrayIsUnknownAndUntouched() throws {
        let home = try SkillTestHome()
        let original = "disabled_skills = 'pdf'\n"
        try home.write(original, to: configURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        XCTAssertEqual(manager.mistralVibeStates(for: [skill("pdf")])["pdf"], .unknown)
        XCTAssertThrowsError(
            try manager.setNativeEnabled(false, directoryName: "pdf", skillName: "pdf", app: .mistralVibe)
        )
        XCTAssertEqual(home.contents(of: configURL(home)), original)
    }

    func testWithoutVibeNothingIsCreated() throws {
        let home = try SkillTestHome()
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        try manager.setNativeEnabled(false, directoryName: "pdf", skillName: "pdf", app: .mistralVibe)
        XCTAssertFalse(home.exists(home.url.appendingPathComponent(".vibe")))
    }
}
