import XCTest
@testable import VibeBarCore

final class SkillSyncEngineTests: XCTestCase {
    func testAutoOverForeignDirectoryRefusesToReplaceIt() throws {
        let home = try SkillTestHome()
        let source = try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "fresh"])
        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try home.write("stale", to: destination.appendingPathComponent("ref.md"))
        try home.write("leftover", to: destination.appendingPathComponent("orphan.md"))

        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertThrowsError(try engine.materialize(
            skillDirectoryName: "alpha", into: .claude, method: .auto
        )) { error in
            XCTAssertEqual(error as? SkillError, .directoryConflict("alpha"))
        }
        XCTAssertEqual(SkillFileSystem.kind(of: destination), .directory)
        XCTAssertEqual(home.contents(of: destination.appendingPathComponent("ref.md")), "stale")
        XCTAssertEqual(home.contents(of: destination.appendingPathComponent("orphan.md")), "leftover")
        XCTAssertTrue(home.exists(source.appendingPathComponent("SKILL.md")))
    }

    func testAutoOverStaleSymlinkRelinksIntoTheSSOT() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let elsewhere = try home.makeSkillDirectory(at: home.url.appendingPathComponent("elsewhere/alpha"))
        try home.makeSymlink("alpha", in: .claude, rawTarget: elsewhere.path)

        let engine = SkillSyncEngine(homeDirectory: home.path)
        let materialization = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .claude,
            method: .auto
        )

        XCTAssertEqual(materialization.method, .symlink)
        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        XCTAssertEqual(SkillFileSystem.kind(of: destination), .symlink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            home.ssot.appendingPathComponent("alpha").path
        )
        // The old target is untouched — we unlinked, never followed.
        XCTAssertTrue(home.exists(elsewhere.appendingPathComponent("SKILL.md")))
    }

    func testSymlinkMethodCreatesAnAbsoluteLinkToTheSSOT() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")

        let engine = SkillSyncEngine(homeDirectory: home.path)
        let materialization = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .codex,
            method: .symlink
        )

        XCTAssertEqual(materialization.method, .symlink)
        XCTAssertNil(materialization.contentHashAtCopy)
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: home.appDirectory(.codex).appendingPathComponent("alpha").path
        )
        XCTAssertTrue(target.hasPrefix("/"))
        XCTAssertEqual(target, home.ssot.appendingPathComponent("alpha").path)
    }

    func testLiveMaterializationRejectsAnEditedOrReplacedCopy() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "original"])
        let engine = SkillSyncEngine(homeDirectory: home.path)
        let recorded = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .claude,
            method: .copy
        )

        XCTAssertEqual(
            engine.liveMaterialization(
                skillDirectoryName: "alpha",
                app: .claude,
                recorded: recorded
            ),
            recorded
        )

        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try home.write("edited", to: destination.appendingPathComponent("ref.md"))
        XCTAssertNil(engine.liveMaterialization(
            skillDirectoryName: "alpha",
            app: .claude,
            recorded: recorded
        ))

        try FileManager.default.removeItem(at: destination)
        try home.makeSkillDirectory(at: destination, extraFiles: ["ref.md": "replacement"])
        XCTAssertNil(engine.liveMaterialization(
            skillDirectoryName: "alpha",
            app: .claude,
            recorded: recorded
        ))
    }

    func testReenableRefusesAnEditedCopyAfterItsRecordWasCleared() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "original"])
        let engine = SkillSyncEngine(homeDirectory: home.path)
        _ = try engine.materialize(
            skillDirectoryName: "alpha", into: .claude, method: .copy
        )
        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try home.write("user edit", to: destination.appendingPathComponent("ref.md"))

        for method in [SkillSyncMethod.auto, .copy] {
            XCTAssertThrowsError(try engine.materialize(
                skillDirectoryName: "alpha", into: .claude, method: method, recorded: nil
            )) { error in
                XCTAssertEqual(error as? SkillError, .directoryConflict("alpha"))
            }
            XCTAssertEqual(home.contents(of: destination.appendingPathComponent("ref.md")), "user edit")
        }
    }

    func testLiveMaterializationRejectsADanglingSSOTLink() throws {
        let home = try SkillTestHome()
        let source = try home.makeSSOTSkill("alpha")
        let engine = SkillSyncEngine(homeDirectory: home.path)
        let recorded = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .claude,
            method: .symlink
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertNil(engine.liveMaterialization(
            skillDirectoryName: "alpha",
            app: .claude,
            recorded: recorded
        ))
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("alpha")),
            .symlink
        )
    }

    func testSymlinkMethodRefusesAForeignDirectoryButReplacesAFaithfulCopy() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "fresh"])
        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try home.makeSkillDirectory(at: destination, extraFiles: ["ref.md": "hand-edited"])

        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertThrowsError(
            try engine.materialize(skillDirectoryName: "alpha", into: .claude, method: .symlink)
        ) { error in
            XCTAssertEqual(error as? SkillError, .directoryConflict("alpha"))
        }
        XCTAssertEqual(SkillFileSystem.kind(of: destination), .directory)
        XCTAssertEqual(home.contents(of: destination.appendingPathComponent("ref.md")), "hand-edited")

        // Once the foreign directory is removed by its owner, Vibe Bar can
        // create and later replace its own verified copy.
        try FileManager.default.removeItem(at: destination)
        let copied = try engine.materialize(skillDirectoryName: "alpha", into: .claude, method: .copy)
        XCTAssertEqual(copied.method, .copy)
        let linked = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .claude,
            method: .symlink,
            recorded: copied
        )
        XCTAssertEqual(linked.method, .symlink)
        XCTAssertEqual(SkillFileSystem.kind(of: destination), .symlink)
    }

    func testMaterializeRefusesASourceWithoutSkillMarkdown() throws {
        let home = try SkillTestHome()
        try home.makeDirectory(home.ssot.appendingPathComponent("not-a-skill"))

        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertThrowsError(
            try engine.materialize(skillDirectoryName: "not-a-skill", into: .claude, method: .auto)
        ) { error in
            XCTAssertEqual(error as? SkillError, .missingSkillMD("not-a-skill"))
        }
        XCTAssertFalse(home.exists(home.appDirectory(.claude).appendingPathComponent("not-a-skill")))
    }

    func testMaterializeRefusesAMissingSource() throws {
        let home = try SkillTestHome()
        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertThrowsError(
            try engine.materialize(skillDirectoryName: "ghost", into: .claude, method: .auto)
        ) { error in
            XCTAssertEqual(error as? SkillError, .sourceDirectoryMissing("ghost"))
        }
    }

    func testAntigravityDirectoryIsCreatedLazilyAndOnlyAtTheLeaf() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let gemini = home.url.appendingPathComponent(".gemini", isDirectory: true)
        try home.write("{}", to: gemini.appendingPathComponent("settings.json"))

        XCTAssertFalse(home.exists(gemini.appendingPathComponent("config")))
        let engine = SkillSyncEngine(homeDirectory: home.path)
        try engine.materialize(skillDirectoryName: "alpha", into: .antigravity, method: .symlink)

        XCTAssertEqual(
            SkillFileSystem.kind(of: gemini.appendingPathComponent("config/skills")),
            .directory
        )
        // AntiGravity's root is ~/.gemini/config — the Gemini CLI's own
        // ~/.gemini/skills must not be conjured up alongside it, and the
        // pre-existing sibling file is untouched.
        XCTAssertFalse(home.exists(gemini.appendingPathComponent("skills")))
        XCTAssertEqual(home.contents(of: gemini.appendingPathComponent("settings.json")), "{}")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: gemini.path).sorted(),
            ["config", "settings.json"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: gemini.appendingPathComponent("config").path),
            ["skills"]
        )
    }

    func testTraversalNamesAreRejectedBeforeAnyFilesystemWrite() throws {
        let home = try SkillTestHome()
        let engine = SkillSyncEngine(homeDirectory: home.path)

        for name in ["../evil", "..", "a/b", ".hidden"] {
            XCTAssertThrowsError(
                try engine.materialize(skillDirectoryName: name, into: .claude, method: .auto)
            ) { error in
                XCTAssertEqual(error as? SkillError, .invalidDirectoryName(name))
            }
            XCTAssertThrowsError(
                try engine.unmaterialize(skillDirectoryName: name, from: .claude, recorded: nil)
            ) { error in
                XCTAssertEqual(error as? SkillError, .invalidDirectoryName(name))
            }
        }
        XCTAssertFalse(home.exists(home.appDirectory(.claude)))
    }

    func testWriteRootsCoverTheSSOTAndEveryAppDirectoryOnly() throws {
        let home = try SkillTestHome()
        XCTAssertEqual(SkillAppCatalog.allowedWriteRoots(homeDirectory: home.path).count, 9)
        XCTAssertTrue(SkillAppCatalog.isWriteAllowed(
            home.ssot.appendingPathComponent("alpha"),
            homeDirectory: home.path
        ))
        XCTAssertTrue(SkillAppCatalog.isWriteAllowed(
            home.appDirectory(.cursor).appendingPathComponent("alpha"),
            homeDirectory: home.path
        ))
        XCTAssertFalse(SkillAppCatalog.isWriteAllowed(
            home.appDirectory(.claude).appendingPathComponent("../../.ssh/authorized_keys"),
            homeDirectory: home.path
        ))
        XCTAssertFalse(SkillAppCatalog.isWriteAllowed(
            home.url.appendingPathComponent(".claude/settings.json"),
            homeDirectory: home.path
        ))
    }

    func testManagedHarnessTargetsExcludeUnmanageableAndLegacySurfaces() {
        XCTAssertEqual(
            SkillAppTarget.managedHarnesses,
            [.codex, .claude, .antigravity, .grok, .cursor]
        )
        XCTAssertEqual(SkillAppCatalog.relativePath(for: .cursor), ".cursor/skills")
        XCTAssertFalse(SkillAppTarget.managedHarnesses.contains(.gemini))
        XCTAssertFalse(SkillAppTarget.managedHarnesses.contains(.hermes))
        XCTAssertFalse(SkillAppTarget.managedHarnesses.contains(.opencode))
    }

    func testUnmaterializeRemovesAnSSOTSymlinkAndIsIdempotent() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let engine = SkillSyncEngine(homeDirectory: home.path)
        let materialization = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .claude,
            method: .symlink
        )

        XCTAssertTrue(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .claude,
            recorded: materialization
        ))
        XCTAssertFalse(home.exists(home.appDirectory(.claude).appendingPathComponent("alpha")))
        // The SSOT copy is never followed into.
        XCTAssertTrue(home.exists(home.ssot.appendingPathComponent("alpha/SKILL.md")))
        XCTAssertTrue(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .claude,
            recorded: materialization
        ))
    }

    func testUnmaterializeLeavesALinkPointingOutsideTheSSOT() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let elsewhere = try home.makeSkillDirectory(at: home.url.appendingPathComponent("elsewhere/alpha"))
        try home.makeSymlink("alpha", in: .claude, rawTarget: elsewhere.path)

        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertFalse(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .claude,
            recorded: SkillMaterialization(method: .symlink)
        ))
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("alpha")),
            .symlink
        )
    }

    func testUnmaterializeResolvesRelativeLinksIntoTheSSOT() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        try home.makeSymlink("alpha", in: .claude, rawTarget: "../../.agents/skills/alpha")

        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertTrue(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .claude,
            recorded: nil
        ))
        XCTAssertFalse(home.exists(home.appDirectory(.claude).appendingPathComponent("alpha")))
        XCTAssertTrue(home.exists(home.ssot.appendingPathComponent("alpha/SKILL.md")))
    }

    func testUnmaterializeLeavesAForeignDirectoryAlone() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try home.makeSkillDirectory(at: destination, extraFiles: ["ref.md": "hand-written"])

        let engine = SkillSyncEngine(homeDirectory: home.path)
        XCTAssertFalse(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .claude,
            recorded: nil
        ))
        XCTAssertEqual(home.contents(of: destination.appendingPathComponent("ref.md")), "hand-written")
    }

    func testUnmaterializeRemovesAnUnmodifiedCopyButKeepsAModifiedOne() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "fresh"])
        let engine = SkillSyncEngine(homeDirectory: home.path)
        let materialization = try engine.materialize(
            skillDirectoryName: "alpha",
            into: .grok,
            method: .copy
        )
        let destination = home.appDirectory(.grok).appendingPathComponent("alpha")

        try home.write("edited by the user", to: destination.appendingPathComponent("ref.md"))
        XCTAssertFalse(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .grok,
            recorded: materialization
        ))
        XCTAssertEqual(SkillFileSystem.kind(of: destination), .directory)

        try home.write("fresh", to: destination.appendingPathComponent("ref.md"))
        XCTAssertTrue(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .grok,
            recorded: materialization
        ))
        XCTAssertFalse(home.exists(destination))
    }

    func testUnmaterializeKeepsACopyItWasNeverToldAbout() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let engine = SkillSyncEngine(homeDirectory: home.path)
        try engine.materialize(skillDirectoryName: "alpha", into: .hermes, method: .copy)

        XCTAssertFalse(try engine.unmaterialize(
            skillDirectoryName: "alpha",
            from: .hermes,
            recorded: SkillMaterialization(method: .symlink)
        ))
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.hermes).appendingPathComponent("alpha")),
            .directory
        )
    }

    func testAdoptionStateRecognizesSSOTLinksOnly() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        try home.makeSSOTSkill("beta")
        try home.makeAbsoluteSymlink("alpha", in: .claude, toSSOT: "alpha")
        try home.makeSymlink("beta", in: .claude, rawTarget: "../../.agents/skills/beta")
        try home.makeSkillDirectory(at: home.appDirectory(.gemini).appendingPathComponent("alpha"))
        let elsewhere = try home.makeSkillDirectory(at: home.url.appendingPathComponent("elsewhere/gamma"))
        try home.makeSymlink("gamma", in: .grok, rawTarget: elsewhere.path)

        let engine = SkillSyncEngine(homeDirectory: home.path)
        let adopted = engine.adoptionState(skillDirectoryName: "alpha", app: .claude)
        XCTAssertEqual(adopted?.method, .symlink)
        XCTAssertEqual(adopted?.adopted, true)
        XCTAssertEqual(engine.adoptionState(skillDirectoryName: "beta", app: .claude)?.method, .symlink)
        XCTAssertNil(engine.adoptionState(skillDirectoryName: "alpha", app: .gemini))
        XCTAssertNil(engine.adoptionState(skillDirectoryName: "gamma", app: .grok))
        XCTAssertNil(engine.adoptionState(skillDirectoryName: "alpha", app: .codex))
    }
}
