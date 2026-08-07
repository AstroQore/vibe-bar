import XCTest
@testable import VibeBarCore

final class SkillBackupManagerTests: XCTestCase {
    private func makeSkill(_ directory: String) -> Skill {
        Skill(
            id: .local(directory: directory),
            name: directory,
            description: "a synthetic skill",
            directory: directory,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentHash: "stale-hash"
        )
    }

    func testCreateBackupCopiesPayloadAndMetadata() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "payload", "nested/deep.md": "deep"])
        let manager = SkillBackupManager(homeDirectory: home.path)

        let backupURL = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))

        XCTAssertTrue(SkillAppCatalog.isPath(backupURL, under: manager.rootDirectory))
        XCTAssertTrue(backupURL.lastPathComponent.hasSuffix("_alpha"))
        XCTAssertEqual(home.contents(of: backupURL.appendingPathComponent("skill/ref.md")), "payload")
        XCTAssertEqual(home.contents(of: backupURL.appendingPathComponent("skill/nested/deep.md")), "deep")

        let data = try Data(contentsOf: backupURL.appendingPathComponent("meta.json"))
        let metadata = try JSONDecoder().decode(SkillBackupManager.Metadata.self, from: data)
        XCTAssertEqual(metadata.skill.directory, "alpha")
        XCTAssertEqual(metadata.sourcePath, home.ssot.appendingPathComponent("alpha").path)
        XCTAssertLessThan(abs(metadata.backupCreatedAt.timeIntervalSinceNow), 30)
        // The SSOT is untouched by taking a backup.
        XCTAssertTrue(home.exists(home.ssot.appendingPathComponent("alpha/SKILL.md")))
    }

    func testCreateBackupRefusesAMissingSkill() throws {
        let home = try SkillTestHome()
        let manager = SkillBackupManager(homeDirectory: home.path)
        XCTAssertThrowsError(try manager.createBackup(of: "ghost", skill: makeSkill("ghost"))) { error in
            XCTAssertEqual(error as? SkillError, .sourceDirectoryMissing("ghost"))
        }
        XCTAssertThrowsError(try manager.createBackup(of: "../evil", skill: makeSkill("../evil"))) { error in
            XCTAssertEqual(error as? SkillError, .invalidDirectoryName("../evil"))
        }
    }

    func testListBackupsIsNewestFirst() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let manager = SkillBackupManager(homeDirectory: home.path)
        let first = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))
        let second = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))

        let listed = manager.listBackups()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first?.url.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(listed.last?.url.lastPathComponent, first.lastPathComponent)
        XCTAssertEqual(listed.first?.skill?.directory, "alpha")
        // Same-second backups get a numeric suffix rather than colliding.
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
    }

    func testRestoreRefusesWhenTheSSOTDirectoryStillExists() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let manager = SkillBackupManager(homeDirectory: home.path)
        let backupURL = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))

        XCTAssertThrowsError(try manager.restore(backupURL: backupURL)) { error in
            XCTAssertEqual(error as? SkillError, .destinationExists("alpha"))
        }
    }

    func testRestoreCopiesBackAndRecomputesTheHash() throws {
        let home = try SkillTestHome()
        let source = try home.makeSSOTSkill("alpha", extraFiles: ["ref.md": "payload"])
        let manager = SkillBackupManager(homeDirectory: home.path)
        let expectedHash = try SkillDirectoryHasher.hash(directory: source)
        let backupURL = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))
        try FileManager.default.removeItem(at: source)

        let restored = try manager.restore(backupURL: backupURL)

        XCTAssertEqual(restored.directory, "alpha")
        XCTAssertEqual(restored.contentHash, expectedHash)
        XCTAssertEqual(home.contents(of: source.appendingPathComponent("ref.md")), "payload")
        XCTAssertEqual(SkillFileSystem.kind(of: source), .directory)
    }

    func testRestoreAndDeleteRefusePathsOutsideTheBackupRoot() throws {
        let home = try SkillTestHome()
        let manager = SkillBackupManager(homeDirectory: home.path)
        let outside = home.url.appendingPathComponent("elsewhere", isDirectory: true)
        try home.makeDirectory(outside)

        XCTAssertThrowsError(try manager.restore(backupURL: outside)) { error in
            XCTAssertEqual(error as? SkillError, .writeOutsideAllowedRoots(outside.path))
        }
        XCTAssertThrowsError(try manager.deleteBackup(outside)) { error in
            XCTAssertEqual(error as? SkillError, .writeOutsideAllowedRoots(outside.path))
        }
        XCTAssertThrowsError(try manager.deleteBackup(manager.rootDirectory)) { error in
            XCTAssertEqual(error as? SkillError, .writeOutsideAllowedRoots(manager.rootDirectory.path))
        }
        XCTAssertTrue(home.exists(outside))
    }

    func testRestoreRejectsABackupWithoutMetadata() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let manager = SkillBackupManager(homeDirectory: home.path)
        let backupURL = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))
        try FileManager.default.removeItem(at: backupURL.appendingPathComponent("meta.json"))

        XCTAssertThrowsError(try manager.restore(backupURL: backupURL)) { error in
            XCTAssertEqual(error as? SkillError, .backupCorrupted(backupURL.lastPathComponent))
        }
    }

    func testPruneKeepsTheNewestTwenty() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let manager = SkillBackupManager(homeDirectory: home.path)

        var created: [URL] = []
        for _ in 0..<23 {
            created.append(try manager.createBackup(of: "alpha", skill: makeSkill("alpha")))
        }

        let listed = manager.listBackups()
        XCTAssertEqual(listed.count, SkillBackupManager.defaultRetainedBackups)
        XCTAssertEqual(listed.first?.url.path, created.last?.path)
        XCTAssertTrue(home.exists(created[22]))

        manager.prune(keeping: 5)
        XCTAssertEqual(manager.listBackups().count, 5)
        XCTAssertEqual(manager.listBackups().first?.url.path, created.last?.path)
    }

    func testDeleteBackupRemovesOneBackup() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha")
        let manager = SkillBackupManager(homeDirectory: home.path)
        let backupURL = try manager.createBackup(of: "alpha", skill: makeSkill("alpha"))

        try manager.deleteBackup(backupURL)
        XCTAssertFalse(home.exists(backupURL))
        XCTAssertTrue(manager.listBackups().isEmpty)
        XCTAssertThrowsError(try manager.deleteBackup(backupURL)) { error in
            XCTAssertEqual(error as? SkillError, .backupNotFound(backupURL.lastPathComponent))
        }
    }
}
