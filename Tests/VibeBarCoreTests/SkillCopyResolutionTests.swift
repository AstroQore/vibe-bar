import XCTest
@testable import VibeBarCore

final class SkillCopyResolutionTests: XCTestCase {
    private func fixture() async throws -> (SkillTestHome, SkillsService, Skill, SkillCopy) {
        let home = try SkillTestHome()
        let staged = try home.makeSkillDirectory(at: home.url.appendingPathComponent("source/alpha"),
                                                extraFiles: ["changed.txt": "base", "removed.txt": "keep or remove"])
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staged, name: "alpha")
        let copyURL = try home.makeSkillDirectory(at: home.appDirectory(.codex).appendingPathComponent("alpha"),
                                                 extraFiles: ["changed.txt": "compared", "added.txt": "new"])
        let copy = SkillCopy(directoryName: "alpha", name: "alpha", description: nil,
                             location: .appFolder(.codex), url: copyURL)
        return (home, service, skill, copy)
    }

    func testOverwriteBacksUpIndependentCopyWithoutAdoptingOrEditingConfig() async throws {
        let (home, service, skill, copy) = try await fixture()
        let config = home.url.appendingPathComponent(".codex/config.toml")
        try home.write("# leave this alone\n", to: config)
        let updated = try await service.overwriteCopyWithShared(skill.id, copy: copy)
        XCTAssertEqual(home.contents(of: copy.url.appendingPathComponent("changed.txt")), "base")
        XCTAssertNil(updated.apps[.codex])
        let listed = await service.inventory()
        XCTAssertTrue(try XCTUnwrap(listed.installed.first).otherCopies.contains { $0.location == .appFolder(.codex) })
        let backup = try XCTUnwrap(service.listBackups().first)
        XCTAssertTrue(backup.directoryName.contains("codex_alpha"))
        XCTAssertEqual(home.contents(of: backup.url.appendingPathComponent("skill/changed.txt")), "compared")
        XCTAssertEqual(home.contents(of: config), "# leave this alone\n")
    }

    func testOverwriteRepairsDriftedManagedCopyAndUpdatesReceipt() async throws {
        let (home, service, skill, copy) = try await fixture()
        try FileManager.default.removeItem(at: copy.url)
        try await service.setEnabled(skill.id, app: .codex, enabled: true, method: .copy)
        try home.write("local edits", to: copy.url.appendingPathComponent("changed.txt"))
        let updated = try await service.overwriteCopyWithShared(skill.id, copy: copy)
        XCTAssertEqual(updated.apps[.codex]?.method, .copy)
        XCTAssertEqual(updated.apps[.codex]?.contentHashAtCopy, updated.contentHash)
        XCTAssertEqual(home.contents(of: copy.url.appendingPathComponent("changed.txt")), "base")
        let backup = try XCTUnwrap(service.listBackups().first)
        XCTAssertEqual(home.contents(of: backup.url.appendingPathComponent("skill/changed.txt")), "local edits")
    }

    func testAdoptWithEitherContentChoiceBecomesManaged() async throws {
        for replace in [false, true] {
            let (home, service, skill, copy) = try await fixture()
            let updated = try await service.adoptCopy(skill.id, copy: copy, replaceShared: replace)
            XCTAssertNotNil(updated.apps[.codex])
            XCTAssertEqual(home.contents(of: copy.url.appendingPathComponent("changed.txt")), replace ? "compared" : "base")
            let inventory = await service.inventory()
            let listed = try XCTUnwrap(inventory.installed.first)
            XCTAssertTrue(listed.otherCopies.isEmpty)
            let versions = service.versionInventory(for: listed)
            XCTAssertFalse(versions.versions.contains { $0.kind == .independentCopy(.codex) })
            XCTAssertTrue(versions.versions.contains { $0.kind == .managedCopy(.codex) || $0.kind == .symlink(.codex) })
            XCTAssertEqual(service.listBackups().count, replace ? 2 : 1)
        }
    }

    func testMergeChoicesCoverAdditionRemovalModificationAndReproject() async throws {
        for useCompared in [false, true] {
            let (home, service, skill, copy) = try await fixture()
            try await service.setEnabled(skill.id, app: .claude, enabled: true, method: .copy)
            let updated = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [
                "changed.txt": useCompared ? .compared : .base,
                "added.txt": useCompared ? .compared : .base,
                "removed.txt": useCompared ? .compared : .base
            ])
            let shared = home.ssot.appendingPathComponent("alpha")
            XCTAssertEqual(home.contents(of: shared.appendingPathComponent("changed.txt")), useCompared ? "compared" : "base")
            XCTAssertEqual(home.exists(shared.appendingPathComponent("added.txt")), useCompared)
            XCTAssertEqual(home.exists(shared.appendingPathComponent("removed.txt")), !useCompared)
            XCTAssertEqual(try SkillDirectoryHasher.hash(directory: shared), updated.contentHash)
            XCTAssertEqual(try SkillDirectoryHasher.hash(directory: home.appDirectory(.claude).appendingPathComponent("alpha")), updated.contentHash)
            XCTAssertEqual(home.contents(of: try XCTUnwrap(service.listBackups().first).url.appendingPathComponent("skill/changed.txt")), "base")
            XCTAssertEqual(home.contents(of: copy.url.appendingPathComponent("changed.txt")), "compared")
        }
    }

    func testMergeMixesChoicesFromBothTrees() async throws {
        let (home, service, skill, copy) = try await fixture()
        _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [
            "changed.txt": .compared, "added.txt": .base, "removed.txt": .compared
        ])
        let shared = home.ssot.appendingPathComponent("alpha")
        XCTAssertEqual(home.contents(of: shared.appendingPathComponent("changed.txt")), "compared")
        XCTAssertFalse(home.exists(shared.appendingPathComponent("added.txt")))
        XCTAssertFalse(home.exists(shared.appendingPathComponent("removed.txt")))
    }

    func testRestoreRejectsArbitraryFolder() async throws {
        let (home, service, skill, _) = try await fixture()
        do {
            _ = try await service.restoreBackupToShared(skill.id, backupURL: home.url)
            XCTFail("Only an inventoried backup may be restored")
        } catch { XCTAssertEqual(error as? SkillError, .backupNotFound(home.url.lastPathComponent)) }
        XCTAssertEqual(service.listBackups().count, 0)
    }

    func testMergeRejectsUnresolvedPathsAndRenamingBeforeBackup() async throws {
        let (home, service, skill, copy) = try await fixture()
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: ["changed.txt": .compared])
            XCTFail("Missing choices must fail")
        } catch { XCTAssertEqual(error as? SkillResolutionError, .unresolvedFiles) }
        try home.write("---\nname: renamed\n---\n", to: copy.url.appendingPathComponent("SKILL.md"))
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [
                "SKILL.md": .compared, "changed.txt": .base, "added.txt": .base, "removed.txt": .base
            ])
            XCTFail("Name changes must fail")
        } catch { XCTAssertEqual(error as? SkillError, .directoryConflict("renamed")) }
        XCTAssertEqual(service.listBackups().count, 0)
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("alpha/changed.txt")), "base")
    }

    func testRestoreBackupToSharedPreservesCurrentContentInAnotherBackup() async throws {
        let (home, service, skill, copy) = try await fixture()
        _ = try await service.overwriteCopyWithShared(skill.id, copy: copy)
        let saved = try XCTUnwrap(service.listBackups().first)
        _ = try await service.restoreBackupToShared(skill.id, backupURL: saved.url)
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("alpha/changed.txt")), "compared")
        XCTAssertEqual(service.listBackups().count, 2)
    }

    func testRestoringTheOldestBackupSurvivesThePruneTheCommitTriggers() async throws {
        let (home, service, skill, copy) = try await fixture()
        _ = try await service.overwriteCopyWithShared(skill.id, copy: copy)
        let oldest = try XCTUnwrap(service.listBackups().last)
        // Fill the retained set so the commit's own backup pushes the
        // oldest one out — the one being restored.
        for _ in 1..<SkillBackupManager.defaultRetainedBackups {
            _ = try await service.overwriteCopyWithShared(skill.id, copy: copy)
        }
        XCTAssertEqual(service.listBackups().count, SkillBackupManager.defaultRetainedBackups)
        _ = try await service.restoreBackupToShared(skill.id, backupURL: oldest.url)
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("alpha/changed.txt")), "compared")
        XCTAssertEqual(service.listBackups().count, SkillBackupManager.defaultRetainedBackups)
    }

    func testNestedSymlinksAreCopiedAsLinksAndNeverWrittenThrough() async throws {
        let (home, service, skill, copy) = try await fixture()
        let outside = try home.makeDirectory(home.url.appendingPathComponent("unowned"))
        try home.write("untouched", to: outside.appendingPathComponent("secret.txt"))
        let shared = home.ssot.appendingPathComponent("alpha")
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("references"), withDestinationURL: outside)
        try home.write("new reference", to: copy.url.appendingPathComponent("references/new.txt"))
        // Dropping the old link and adding a directory is a valid explicit choice.
        _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [
            "changed.txt": .base, "added.txt": .base, "removed.txt": .base,
            "references": .compared, "references/new.txt": .compared
        ])
        XCTAssertEqual(home.contents(of: shared.appendingPathComponent("references/new.txt")), "new reference")
        XCTAssertEqual(home.contents(of: outside.appendingPathComponent("secret.txt")), "untouched")
        XCTAssertFalse(home.exists(outside.appendingPathComponent("new.txt")))
    }

    func testInconsistentLinkAndChildChoicesFailWithoutChangingShared() async throws {
        let (home, service, skill, copy) = try await fixture()
        let outside = try home.makeDirectory(home.url.appendingPathComponent("unowned"))
        let shared = home.ssot.appendingPathComponent("alpha")
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("references"), withDestinationURL: outside)
        try home.write("new reference", to: copy.url.appendingPathComponent("references/new.txt"))
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [
                "changed.txt": .base, "added.txt": .base, "removed.txt": .base,
                "references": .base, "references/new.txt": .compared
            ])
            XCTFail("Must not follow a kept link")
        } catch { XCTAssertEqual(error as? SkillResolutionError, .conflictingStructure) }
        XCTAssertFalse(home.exists(outside.appendingPathComponent("new.txt")))
        XCTAssertEqual(service.listBackups().count, 0)
    }

    func testOverwriteRefusesSymlinkedHarnessRoot() async throws {
        let (home, service, skill, copy) = try await fixture()
        let moved = home.url.appendingPathComponent("unowned")
        try FileManager.default.moveItem(at: home.appDirectory(.codex), to: moved)
        try FileManager.default.createSymbolicLink(at: home.appDirectory(.codex), withDestinationURL: moved)
        do {
            _ = try await service.overwriteCopyWithShared(skill.id, copy: copy)
            XCTFail("Must not write through a symlinked ancestor")
        } catch { XCTAssertEqual(error as? SkillError, .writeOutsideAllowedRoots(copy.url.path)) }
        XCTAssertEqual(home.contents(of: moved.appendingPathComponent("alpha/changed.txt")), "compared")
    }

    func testTruncatedComparisonIsRefusedBeforeBackup() async throws {
        let (home, service, skill, copy) = try await fixture()
        for index in 0...SkillDiffLimits.standard.maxFiles {
            try home.write("payload", to: copy.url.appendingPathComponent("file-\(index).txt"))
        }
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [:])
            XCTFail("A partial comparison cannot authorize a merge")
        } catch { XCTAssertEqual(error as? SkillResolutionError, .incompleteComparison) }
        XCTAssertEqual(service.listBackups().count, 0)
    }

    func testAllResolutionWritesRefuseLinkedSharedDirectory() async throws {
        let (home, service, skill, copy) = try await fixture()
        let shared = home.ssot.appendingPathComponent("alpha")
        let external = home.url.appendingPathComponent("external")
        try FileManager.default.moveItem(at: shared, to: external)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: external)
        let before = home.fileContents(under: external)
        do {
            _ = try await service.overwriteCopyWithShared(skill.id, copy: copy)
            XCTFail("Cannot overwrite from a linked shared directory")
        } catch { XCTAssertEqual(error as? SkillError, .sourceNotADirectory("alpha")) }
        do {
            _ = try await service.adoptCopy(skill.id, copy: copy, replaceShared: false)
            XCTFail("Cannot adopt a linked shared directory")
        } catch { XCTAssertEqual(error as? SkillError, .sourceNotADirectory("alpha")) }
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: [:])
            XCTFail("Cannot merge into a linked shared directory")
        } catch { XCTAssertEqual(error as? SkillError, .sourceNotADirectory("alpha")) }
        XCTAssertEqual(home.fileContents(under: external), before)
        XCTAssertEqual(service.listBackups().count, 0)
    }

    func testMergeRejectsStaleHashAndExtraResolutionPaths() async throws {
        let (home, service, skill, copy) = try await fixture()
        let choices: [String: SkillMergeSide] = ["changed.txt": .base, "added.txt": .base, "removed.txt": .base]
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: choices, expectedSharedHash: "stale")
            XCTFail("Stale comparison must fail")
        } catch { XCTAssertEqual(error as? SkillResolutionError, .contentChanged) }
        do {
            _ = try await service.mergeIntoShared(skill.id, from: copy, resolutions: choices.merging(["../escape": .compared]) { a, _ in a })
            XCTFail("Extraneous paths must fail")
        } catch { XCTAssertEqual(error as? SkillResolutionError, .unresolvedFiles) }
        XCTAssertEqual(service.listBackups().count, 0)
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("alpha/changed.txt")), "base")
    }
}
