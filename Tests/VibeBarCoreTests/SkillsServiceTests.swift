import XCTest
@testable import VibeBarCore

final class SkillsServiceTests: XCTestCase {
    func testInstallLocalCopiesIntoTheSSOTAndEnablesNothing() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            name: "alpha-skill",
            description: "from disk",
            extraFiles: ["ref.md": "payload"]
        )
        let service = SkillsService(homeDirectory: home.path)

        let skill = try await service.installLocal(from: staging, name: "alpha")

        XCTAssertEqual(skill.id, .local(directory: "alpha"))
        XCTAssertEqual(skill.name, "alpha-skill")
        XCTAssertEqual(skill.description, "from disk")
        XCTAssertTrue(skill.apps.isEmpty)
        XCTAssertEqual(
            home.contents(of: home.ssot.appendingPathComponent("alpha/ref.md")),
            "payload"
        )
        XCTAssertEqual(
            skill.contentHash,
            try SkillDirectoryHasher.hash(directory: home.ssot.appendingPathComponent("alpha"))
        )
        let installed = await service.installedSkills()
        XCTAssertEqual(installed.map(\.directory), ["alpha"])
        for app in SkillAppTarget.allCases {
            XCTAssertFalse(home.exists(home.appDirectory(app)))
        }
    }

    func testInstallLocalRefusesAnExistingDirectoryAndANonSkill() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"))
        let service = SkillsService(homeDirectory: home.path)
        _ = try await service.installLocal(from: staging, name: "alpha")

        do {
            _ = try await service.installLocal(from: staging, name: "alpha")
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? SkillError, .directoryConflict("alpha"))
        }

        let bare = try home.makeDirectory(home.url.appendingPathComponent("Downloads/bare"))
        do {
            _ = try await service.installLocal(from: bare, name: "bare")
            XCTFail("expected a missing SKILL.md")
        } catch {
            XCTAssertEqual(error as? SkillError, .missingSkillMD("bare"))
        }
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("bare")))
    }

    func testSetEnabledMaterializesThenPersists() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"))
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")

        let enabled = try await service.setEnabled(skill.id, app: .claude, enabled: true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("alpha")),
            .symlink
        )
        let afterEnable = await service.skill(with: skill.id)
        XCTAssertEqual(afterEnable?.apps[.claude]?.method, .symlink)
        let persisted = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(persisted.first?.enabledApps, [.claude])

        let disabled = try await service.setEnabled(skill.id, app: .claude, enabled: false)
        XCTAssertTrue(disabled)
        XCTAssertFalse(home.exists(home.appDirectory(.claude).appendingPathComponent("alpha")))
        let afterDisable = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(afterDisable.first?.enabledApps, [])
    }

    func testInstalledSkillsClearsARecordedSymlinkRemovedOutsideVibeBar() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"))
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")
        _ = try await service.setEnabled(skill.id, app: .claude, enabled: true, method: .symlink)

        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try FileManager.default.removeItem(at: destination)

        let live = await service.installedSkills()
        XCTAssertFalse(try XCTUnwrap(live.first).isEnabled(for: .claude))
        let persisted = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertFalse(try XCTUnwrap(persisted.first).isEnabled(for: .claude))
    }

    func testInstalledSkillsRejectsARecordedLinkReplacedByAForeignDirectory() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"))
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")
        _ = try await service.setEnabled(skill.id, app: .claude, enabled: true, method: .symlink)

        let destination = home.appDirectory(.claude).appendingPathComponent("alpha")
        try FileManager.default.removeItem(at: destination)
        try home.makeSkillDirectory(at: destination, extraFiles: ["owner.txt": "user"])

        let live = await service.installedSkills()
        XCTAssertFalse(try XCTUnwrap(live.first).isEnabled(for: .claude))
        XCTAssertEqual(home.contents(of: destination.appendingPathComponent("owner.txt")), "user")
    }

    func testStoreRevisionRejectsConcurrentAndSameValueABAReconciliation() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)
        let original = SkillMaterialization(method: .symlink)
        let replacement = SkillMaterialization(method: .copy, contentHashAtCopy: "new")
        let cursor = SkillMaterialization(method: .symlink)
        let snapshot = Skill(
            id: .local(directory: "alpha"),
            name: "Alpha",
            directory: "alpha",
            installedAt: Date(timeIntervalSince1970: 1),
            apps: [.claude: original]
        )
        var reconciled = snapshot
        reconciled.apps[.claude] = nil
        var current = snapshot
        current.apps[.cursor] = cursor
        try await store.upsert(snapshot)
        let stale = await store.snapshot()
        // Same-value write: semantically a reinstall even though the mapping
        // compares equal to the old snapshot.
        try await store.upsert(snapshot)
        let afterABA = try await store.applyReconciliation(
            expectedRevision: stale.revision,
            appsBySkill: [snapshot.id: reconciled.apps]
        )
        XCTAssertEqual(afterABA.first?.apps[.claude], original)

        let fresh = await store.snapshot()
        try await store.upsert(current)
        let afterConcurrent = try await store.applyReconciliation(
            expectedRevision: fresh.revision,
            appsBySkill: [snapshot.id: reconciled.apps]
        )
        XCTAssertEqual(afterConcurrent.first?.apps[.claude], original)
        XCTAssertEqual(afterConcurrent.first?.apps[.cursor], cursor)

        current.apps[.claude] = replacement
        try await store.upsert(current)
        let changed = await store.snapshot()
        var removeClaude = current.apps
        removeClaude[.claude] = nil
        let applied = try await store.applyReconciliation(
            expectedRevision: changed.revision,
            appsBySkill: [snapshot.id: removeClaude]
        )
        XCTAssertNil(applied.first?.apps[.claude])
        XCTAssertEqual(applied.first?.apps[.cursor], cursor)
    }

    func testFailedMaterializeLeavesTheStoreUntouched() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"))
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")

        // The engine refuses a source without SKILL.md; because the file
        // operation runs first, the enable bit must not be recorded.
        try FileManager.default.removeItem(at: home.ssot.appendingPathComponent("alpha/SKILL.md"))
        do {
            _ = try await service.setEnabled(skill.id, app: .claude, enabled: true)
            XCTFail("expected the materialize to fail")
        } catch {
            XCTAssertEqual(error as? SkillError, .missingSkillMD("alpha"))
        }

        let inMemory = await service.skill(with: skill.id)
        XCTAssertEqual(inMemory?.apps, [:])
        let onDisk = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(onDisk.first?.apps, [:])
        XCTAssertFalse(home.exists(home.appDirectory(.claude).appendingPathComponent("alpha")))
    }

    func testDisableClearsTheBitButKeepsAModifiedCopy() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            extraFiles: ["ref.md": "payload"]
        )
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")
        _ = try await service.setEnabled(skill.id, app: .grok, enabled: true, method: .copy)

        let destination = home.appDirectory(.grok).appendingPathComponent("alpha")
        try home.write("edited by the user", to: destination.appendingPathComponent("ref.md"))

        let removed = try await service.setEnabled(skill.id, app: .grok, enabled: false)
        XCTAssertFalse(removed)
        XCTAssertEqual(SkillFileSystem.kind(of: destination), .directory)
        XCTAssertEqual(home.contents(of: destination.appendingPathComponent("ref.md")), "edited by the user")
        let stored = await service.skill(with: skill.id)
        XCTAssertEqual(stored?.enabledApps, [])
    }

    func testSetEnabledRejectsAnUnknownSkill() async throws {
        let home = try SkillTestHome()
        let service = SkillsService(homeDirectory: home.path)
        do {
            _ = try await service.setEnabled(.local(directory: "ghost"), app: .claude, enabled: true)
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? SkillError, .notInstalled(.local(directory: "ghost")))
        }
    }

    func testUninstallBacksUpThenRemovesEverywhere() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            extraFiles: ["ref.md": "payload"]
        )
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")
        _ = try await service.setEnabled(skill.id, app: .claude, enabled: true, method: .symlink)
        _ = try await service.setEnabled(skill.id, app: .grok, enabled: true, method: .copy)

        let result = try await service.uninstall(skill.id)

        XCTAssertEqual(result.removedByApp[.claude], true)
        XCTAssertEqual(result.removedByApp[.grok], true)
        XCTAssertFalse(home.exists(home.appDirectory(.claude).appendingPathComponent("alpha")))
        XCTAssertFalse(home.exists(home.appDirectory(.grok).appendingPathComponent("alpha")))
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("alpha")))
        let remaining = await service.installedSkills()
        XCTAssertTrue(remaining.isEmpty)

        XCTAssertEqual(
            home.contents(of: result.backupURL.appendingPathComponent("skill/ref.md")),
            "payload"
        )
        XCTAssertEqual(service.listBackups().count, 1)

        let restored = try await service.restoreBackup(result.backupURL)
        XCTAssertEqual(restored.directory, "alpha")
        XCTAssertTrue(home.exists(home.ssot.appendingPathComponent("alpha/SKILL.md")))
        let afterRestore = await service.installedSkills()
        XCTAssertEqual(afterRestore.map(\.directory), ["alpha"])
    }

    func testUninstallLeavesAForeignDirectoryBehindAndReportsIt() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"))
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")
        let foreign = home.appDirectory(.hermes).appendingPathComponent("alpha")
        try home.makeSkillDirectory(at: foreign, extraFiles: ["ref.md": "hand written"])

        let result = try await service.uninstall(skill.id)

        XCTAssertEqual(result.removedByApp[.hermes], false)
        XCTAssertEqual(result.retainedApps, [.hermes])
        XCTAssertEqual(home.contents(of: foreign.appendingPathComponent("ref.md")), "hand written")
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("alpha")))
    }

    func testImportAdoptedPersistsTheScannedLayout() async throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("alpha", name: "alpha-skill")
        try home.makeSSOTSkill("beta")
        try home.makeAbsoluteSymlink("alpha", in: .claude, toSSOT: "alpha")
        try home.makeAbsoluteSymlink("alpha", in: .cursor, toSSOT: "alpha")
        let service = SkillsService(homeDirectory: home.path)

        let report = service.scanForImport()
        let imported = try await service.importAdopted(report, apps: [.claude])

        XCTAssertEqual(imported.map(\.directory), ["alpha", "beta"])
        let persisted = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(persisted.count, 2)
        // Only the requested app is recorded, and it is marked as adopted.
        XCTAssertEqual(persisted.first?.enabledApps, [.claude])
        XCTAssertEqual(persisted.first?.apps[.claude]?.adopted, true)
        // Import changed nothing on disk.
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.cursor).appendingPathComponent("alpha")),
            .symlink
        )

        // A second import with another app selected keeps what was known.
        _ = try await service.importAdopted(report, apps: [.cursor])
        let merged = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(merged.first?.enabledApps, [.claude, .cursor])
    }

    func testAdoptUnmanagedCopiesIntoTheSSOTThenMaterializes() async throws {
        let home = try SkillTestHome()
        let foreign = try home.makeSkillDirectory(
            at: home.appDirectory(.claude).appendingPathComponent("legacy-helper"),
            name: "Legacy Helper",
            description: "hand written",
            extraFiles: ["ref.md": "payload"]
        )
        let service = SkillsService(homeDirectory: home.path)

        let report = service.scanForImport()
        XCTAssertEqual(report.unmanagedDirectories.map(\.directoryName), ["legacy-helper"])

        let adopted = try await service.adoptUnmanaged(
            directoryName: "legacy-helper",
            from: .claude,
            apps: [.claude, .codex],
            method: .symlink
        )

        XCTAssertEqual(adopted.id, .local(directory: "legacy-helper"))
        XCTAssertEqual(adopted.name, "Legacy Helper")
        XCTAssertEqual(adopted.description, "hand written")
        XCTAssertEqual(
            home.contents(of: home.ssot.appendingPathComponent("legacy-helper/ref.md")),
            "payload"
        )
        XCTAssertEqual(adopted.enabledApps, [.claude, .codex])
        XCTAssertEqual(SkillFileSystem.kind(of: foreign), .symlink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path),
            home.ssot.appendingPathComponent("legacy-helper").path
        )
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.codex).appendingPathComponent("legacy-helper")),
            .symlink
        )
        let persisted = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(persisted.map(\.directory), ["legacy-helper"])
    }

    func testAdoptUnmanagedRefusesWhenTheSSOTAlreadyHasThatName() async throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("legacy-helper")
        try home.makeSkillDirectory(at: home.appDirectory(.claude).appendingPathComponent("legacy-helper"))
        let service = SkillsService(homeDirectory: home.path)

        do {
            _ = try await service.adoptUnmanaged(
                directoryName: "legacy-helper",
                from: .claude,
                apps: [.claude]
            )
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? SkillError, .directoryConflict("legacy-helper"))
        }
    }
}
