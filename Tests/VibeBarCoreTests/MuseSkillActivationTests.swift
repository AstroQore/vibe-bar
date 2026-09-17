import XCTest
@testable import VibeBarCore

/// Muse Code discovers `~/.agents/skills` itself and keeps each skill's
/// switch in `~/.config/muse/settings.json` under `skills.activation.user`,
/// keyed by the path Muse found it at. Vibe Bar flips that switch and never
/// writes Muse's own `~/.config/muse/skills`.
final class MuseSkillActivationTests: XCTestCase {
    private func settingsURL(_ home: SkillTestHome) -> URL {
        home.url.appendingPathComponent(".config/muse/settings.json")
    }

    private func museDirectory(_ home: SkillTestHome) throws -> URL {
        try home.makeDirectory(home.url.appendingPathComponent(".config/muse", isDirectory: true))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func userActivations(_ home: SkillTestHome) throws -> [String: String]? {
        let root = try json(settingsURL(home))
        let skills = root["skills"] as? [String: Any]
        let activation = skills?["activation"] as? [String: Any]
        return activation?["user"] as? [String: String]
    }

    private func skill(_ directory: String) -> Skill {
        Skill(id: .local(directory: directory), name: directory, directory: directory, installedAt: .distantPast)
    }

    func testMuseIsAManagedSharedRootHarnessWithoutAProjection() throws {
        let home = try SkillTestHome()
        XCTAssertTrue(SkillAppTarget.managedHarnesses.contains(.muse))
        XCTAssertEqual(SkillAppTarget.muse.displayName, "Muse Code")
        XCTAssertTrue(SkillAppTarget.muse.discoversSharedSkillRoot)
        XCTAssertTrue(SkillAppTarget.muse.supportsNativeSkillActivation)
        XCTAssertFalse(SkillAppTarget.muse.supportsProjection)
        XCTAssertFalse(SkillAppCatalog.isWriteAllowed(
            home.appDirectory(.muse).appendingPathComponent("alpha"),
            homeDirectory: home.path
        ))
        XCTAssertEqual(skill("alpha").activationState(for: .muse), .enabled)
    }

    func testTheEngineRefusesToProjectIntoMusesOwnFolder() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let engine = SkillSyncEngine(homeDirectory: home.path)

        XCTAssertThrowsError(try engine.materialize(skillDirectoryName: "alpha", into: .muse, method: .symlink)) {
            XCTAssertEqual($0 as? SkillError, .projectionUnsupported(.muse))
        }
        XCTAssertTrue(try engine.unmaterialize(skillDirectoryName: "alpha", from: .muse, recorded: nil))
        XCTAssertFalse(home.exists(home.url.appendingPathComponent(".config")))
    }

    func testDisableWritesMusesOwnKeyAndKeepsEverythingElse() throws {
        let home = try SkillTestHome()
        try home.write("""
        {
          "schema_version": 1,
          "reasoning_effort": "high",
          "tui": {"theme": "dark", "compact": true},
          "skills": {"activation": {"user": {"$HOME/.agents/skills/beta/SKILL.md": "user-invocable-only"}}}
        }
        """, to: settingsURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .muse)

        let root = try json(settingsURL(home))
        XCTAssertEqual(root["schema_version"] as? Int, 1)
        XCTAssertEqual(root["reasoning_effort"] as? String, "high")
        XCTAssertEqual((root["tui"] as? [String: Any])?["compact"] as? Bool, true)
        XCTAssertEqual(try userActivations(home), [
            "$HOME/.agents/skills/alpha/SKILL.md": "off",
            "$HOME/.agents/skills/beta/SKILL.md": "user-invocable-only",
        ])
        let raw = try XCTUnwrap(home.contents(of: settingsURL(home)))
        XCTAssertTrue(raw.contains("$HOME/.agents/skills/alpha/SKILL.md"), "slashes stay unescaped")

        let states = manager.museStates(for: [skill("alpha"), skill("beta"), skill("gamma")])
        XCTAssertEqual(states["alpha"], .disabled)
        XCTAssertEqual(states["beta"], .enabled, "user-invocable-only is still usable")
        XCTAssertEqual(states["gamma"], .enabled, "no entry is Muse's default: on")
    }

    func testEnableRemovesTheEntryAndPrunesTheEmptySection() throws {
        let home = try SkillTestHome()
        try home.write(#"{"schema_version":1,"skills":{"activation":{"user":{"$HOME/.agents/skills/alpha/SKILL.md":"off"}}}}"#,
                       to: settingsURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(true, directoryName: "alpha", skillName: "Alpha", app: .muse)

        let root = try json(settingsURL(home))
        XCTAssertNil(root["skills"])
        XCTAssertEqual(root["schema_version"] as? Int, 1)
        XCTAssertEqual(manager.museStates(for: [skill("alpha")])["alpha"], .enabled)
    }

    func testAnAbsolutePathSpellingIsReadAndReplaced() throws {
        let home = try SkillTestHome()
        let absolute = home.ssot.appendingPathComponent("alpha/SKILL.md").path
        try home.write(
            String(data: try JSONSerialization.data(withJSONObject: [
                "schema_version": 1,
                "skills": ["activation": ["user": [absolute: "off"]]]
            ]), encoding: .utf8)!,
            to: settingsURL(home)
        )
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        XCTAssertEqual(manager.museStates(for: [skill("alpha")])["alpha"], .disabled)

        try manager.setNativeEnabled(true, directoryName: "alpha", skillName: "Alpha", app: .muse)
        XCTAssertNil(try json(settingsURL(home))["skills"])
    }

    func testAnUnknownSchemaIsNeitherReadNorRewritten() throws {
        let home = try SkillTestHome()
        let original = #"{"schema_version":2,"skills":{"activation":{"user":{}}}}"#
        try home.write(original, to: settingsURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        XCTAssertEqual(manager.museStates(for: [skill("alpha")])["alpha"], .unknown)
        XCTAssertThrowsError(
            try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .muse)
        ) { XCTAssertEqual($0 as? SkillError, .nativeConfigUnreadable(.muse)) }
        XCTAssertThrowsError(try manager.validateCanEnable(.muse))
        XCTAssertEqual(home.contents(of: settingsURL(home)), original)
    }

    /// A container of the wrong type is a file the setter refuses, so it is
    /// not read as "every skill on" either.
    func testAMalformedActivationTreeReadsAsUnknown() throws {
        let home = try SkillTestHome()
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        for body in [#"{"schema_version":1,"skills":[]}"#,
                     #"{"schema_version":1,"skills":{"activation":"on"}}"#,
                     #"{"schema_version":1,"skills":{"activation":{"user":[]}}}"#] {
            try home.write(body, to: settingsURL(home))
            XCTAssertEqual(manager.museStates(for: [skill("alpha")])["alpha"], .unknown, body)
            XCTAssertThrowsError(try manager.validateCanDisable(.muse), body)
        }
    }

    /// A symlinked settings file is followed only inside the home directory;
    /// neither the lock nor the rewrite may land outside it.
    func testASettingsLinkLeavingTheHomeIsNotWritten() throws {
        let home = try SkillTestHome()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarMuseOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let external = outside.appendingPathComponent("settings.json")
        try Data(#"{"schema_version":1}"#.utf8).write(to: external)
        try museDirectory(home)
        try FileManager.default.createSymbolicLink(at: settingsURL(home), withDestinationURL: external)
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        XCTAssertThrowsError(
            try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .muse)
        ) { XCTAssertEqual($0 as? SkillError, .writeOutsideAllowedRoots(external.resolvingSymlinksInPath().path)) }
        XCTAssertThrowsError(try manager.validateCanDisable(.muse), "the preflight enforces the same boundary")
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), #"{"schema_version":1}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(".settings.json.lock").path))
    }

    /// A linked `~/.config/muse` leaving the home is refused even before a
    /// settings file exists there.
    func testALinkedMuseDirectoryLeavingTheHomeIsNotWritten() throws {
        let home = try SkillTestHome()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarMuseDir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try home.makeDirectory(home.url.appendingPathComponent(".config", isDirectory: true))
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent(".config/muse"), withDestinationURL: outside
        )
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        XCTAssertThrowsError(try manager.validateCanDisable(.muse))
        XCTAssertThrowsError(
            try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .muse)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testAnUnrecognisedActivationValueReadsAsUnknown() throws {
        let home = try SkillTestHome()
        try home.write(#"{"schema_version":1,"skills":{"activation":{"user":{"$HOME/.agents/skills/alpha/SKILL.md":"sometimes"}}}}"#,
                       to: settingsURL(home))
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)
        XCTAssertEqual(manager.museStates(for: [skill("alpha")])["alpha"], .unknown)
    }

    func testWithoutMuseNothingIsCreated() throws {
        let home = try SkillTestHome()
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .muse)

        XCTAssertFalse(home.exists(home.url.appendingPathComponent(".config")))
    }

    func testAFreshSettingsFileCarriesTheSchemaVersion() throws {
        let home = try SkillTestHome()
        try museDirectory(home)
        let manager = SkillHarnessConfigManager(homeDirectory: home.path)

        try manager.setNativeEnabled(false, directoryName: "alpha", skillName: "Alpha", app: .muse)

        XCTAssertEqual(try json(settingsURL(home))["schema_version"] as? Int, 1)
        XCTAssertEqual(try userActivations(home), ["$HOME/.agents/skills/alpha/SKILL.md": "off"])
    }

    /// A fresh install with Muse Code unticked switches it off there, like
    /// every other harness that reads the shared root — and Muse's own skills
    /// folder is never created, ticked or not.
    func testInstallingSwitchesMuseByTheSelectionAndNeverProjects() async throws {
        let home = try SkillTestHome()
        try museDirectory(home)
        let service = SkillsService(homeDirectory: home.path)

        let unticked = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/alpha"))
        _ = try await service.install(from: .localDirectory(unticked), enableFor: [.claude])
        let ticked = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/beta"))
        _ = try await service.install(from: .localDirectory(ticked), enableFor: [.muse])

        XCTAssertEqual(try userActivations(home), ["$HOME/.agents/skills/alpha/SKILL.md": "off"])
        XCTAssertFalse(home.exists(home.appDirectory(.muse)))

        let installed = await service.installedSkills()
        let byDirectory = Dictionary(uniqueKeysWithValues: installed.map { ($0.directory, $0) })
        XCTAssertEqual(byDirectory["alpha"]?.activationState(for: .muse), .disabledInHarness)
        XCTAssertEqual(byDirectory["beta"]?.activationState(for: .muse), .enabled)
        XCTAssertNil(byDirectory["beta"]?.apps[.muse])

        let alpha = try XCTUnwrap(byDirectory["alpha"])
        let changed = try await service.setActivation(alpha.id, app: .muse, action: .enable)
        XCTAssertTrue(changed)
        XCTAssertNil(try userActivations(home))

        _ = try await service.uninstall(alpha.id)
        XCTAssertFalse(home.exists(home.appDirectory(.muse)))
    }

    /// Muse sees a copy in the shared root at once, so an install that could
    /// not switch it off there fails before copying anything.
    func testAnInstallMuseCannotRecordFailsBeforeTheCopy() async throws {
        let home = try SkillTestHome()
        let original = #"{"schema_version":2}"#
        try home.write(original, to: settingsURL(home))
        let service = SkillsService(homeDirectory: home.path)

        let source = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/alpha"))
        do {
            _ = try await service.install(from: .localDirectory(source), enableFor: [.claude])
            XCTFail("the install should have been refused")
        } catch {
            XCTAssertEqual(error as? SkillError, .nativeConfigUnreadable(.muse))
        }
        XCTAssertFalse(home.exists(home.url.appendingPathComponent(".agents/skills/alpha")))
        XCTAssertEqual(home.contents(of: settingsURL(home)), original)
        let installed = await service.installedSkills()
        XCTAssertTrue(installed.isEmpty)

        do {
            _ = try await service.installLocal(from: source, name: "alpha")
            XCTFail("the local install should have been refused")
        } catch {
            XCTAssertEqual(error as? SkillError, .nativeConfigUnreadable(.muse))
        }
        XCTAssertFalse(home.exists(home.url.appendingPathComponent(".agents/skills/alpha")))
    }
}
