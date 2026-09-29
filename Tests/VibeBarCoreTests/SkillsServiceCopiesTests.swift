import XCTest
@testable import VibeBarCore

/// `SkillsService`'s view of every other copy of a skill: attaching them to
/// installed rows, listing unmatched built-ins, and the two actions that move
/// a copy's content into the shared library.
final class SkillsServiceCopiesTests: XCTestCase {
    private func codexSystem(_ home: SkillTestHome) -> URL {
        home.appDirectory(.codex).appendingPathComponent(".system", isDirectory: true)
    }

    /// Installs `alpha` from a staging folder and returns the service.
    private func installAlpha(
        in home: SkillTestHome,
        extraFiles: [String: String] = ["ref.md": "shared"]
    ) async throws -> (SkillsService, Skill) {
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            extraFiles: extraFiles
        )
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: staging, name: "alpha")
        return (service, skill)
    }

    func testInstalledSkillsAttachOtherCopiesWithComparison() async throws {
        let home = try SkillTestHome()
        let (service, _) = try await installAlpha(in: home)
        // Same content in Claude's folder (shadows the shared copy), different
        // content as a Codex built-in, and an unrelated built-in.
        try FileManager.default.createDirectory(at: home.appDirectory(.claude), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: home.ssot.appendingPathComponent("alpha"),
            to: home.appDirectory(.claude).appendingPathComponent("alpha")
        )
        try home.makeSkillDirectory(
            at: codexSystem(home).appendingPathComponent("alpha"),
            extraFiles: ["ref.md": "bundled"]
        )
        try home.makeSkillDirectory(
            at: codexSystem(home).appendingPathComponent("imagegen"),
            description: "Codex only"
        )

        let installed = await service.installedSkills()

        let alpha = try XCTUnwrap(installed.first { $0.directory == "alpha" })
        XCTAssertEqual(alpha.otherCopies.map(\.location), [.appFolder(.claude), .builtIn(.codex)])
        let claude = alpha.otherCopies[0]
        XCTAssertTrue(claude.sameAsShared)
        XCTAssertTrue(claude.shadowsShared)
        let codex = alpha.otherCopies[1]
        XCTAssertFalse(codex.sameAsShared)
        XCTAssertFalse(codex.shadowsShared)
        XCTAssertNotNil(codex.contentHash)
        XCTAssertEqual(alpha.sharedCopy?.location, .shared)
        XCTAssertEqual(alpha.sharedCopy?.contentHash, alpha.contentHash)

        let builtIns = await service.builtInSkills()
        XCTAssertEqual(builtIns.map(\.directoryName), ["imagegen"])
        XCTAssertEqual(builtIns.first?.location, .builtIn(.codex))
        XCTAssertEqual(builtIns.first?.description, "Codex only")

        // Transient: nothing about copies reaches skills.json.
        let persisted = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(persisted.first?.otherCopies, [])
        let json = try String(
            contentsOf: VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path),
            encoding: .utf8
        )
        XCTAssertFalse(json.contains("otherCopies"))
        XCTAssertFalse(json.contains(".system"))
    }

    func testRepeatedReloadsDoNotRehashUnchangedCopies() async throws {
        let home = try SkillTestHome()
        let (service, _) = try await installAlpha(in: home)
        let builtIn = try home.makeSkillDirectory(
            at: codexSystem(home).appendingPathComponent("alpha"),
            extraFiles: ["ref.md": "bundled"]
        )
        // Built-ins nobody compares against are never hashed.
        try home.makeSkillDirectory(at: codexSystem(home).appendingPathComponent("imagegen"))

        _ = await service.installedSkills()
        let afterFirst = await service.copyHashComputations
        XCTAssertEqual(afterFirst, 2) // the built-in and the shared copy
        for _ in 0..<3 { _ = await service.installedSkills() }
        let afterRepeats = await service.copyHashComputations
        XCTAssertEqual(afterRepeats, afterFirst)

        try home.write("bundled, edited", to: builtIn.appendingPathComponent("ref.md"))
        _ = await service.installedSkills()
        let afterEdit = await service.copyHashComputations
        XCTAssertEqual(afterEdit, afterFirst + 1)
    }

    func testMatchingIsByFrontmatterNameOrDirectoryCaseInsensitively() async throws {
        let home = try SkillTestHome()
        let (service, _) = try await installAlpha(in: home)
        try home.makeSkillDirectory(
            at: home.appDirectory(.grok).appendingPathComponent("renamed"),
            name: "ALPHA"
        )

        let installed = await service.installedSkills()
        let alpha = try XCTUnwrap(installed.first)

        XCTAssertEqual(alpha.otherCopies.map(\.directoryName), ["renamed"])
        // Different directory name: Grok loads both, neither hides the other.
        XCTAssertFalse(alpha.otherCopies[0].shadowsShared)
        let groups = await service.skillCopies()
        XCTAssertEqual(groups["alpha"]?.map(\.location), [.shared, .appFolder(.grok)])
    }

    func testVibeBarsOwnManagedCopyIsNotListedAsAnotherCopy() async throws {
        let home = try SkillTestHome()
        let (service, skill) = try await installAlpha(in: home)
        try await service.setEnabled(skill.id, app: .claude, enabled: true, method: .copy)
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("alpha")),
            .directory
        )

        let installed = await service.installedSkills()
        let alpha = try XCTUnwrap(installed.first)

        XCTAssertEqual(alpha.otherCopies, [])
        XCTAssertNil(alpha.sharedCopy)
        let builtIns = await service.builtInSkills()
        XCTAssertEqual(builtIns, [])
    }

    func testReplaceSharedCopyBacksUpReplacesAndRecopiesManagedProjections() async throws {
        let home = try SkillTestHome()
        let (service, skill) = try await installAlpha(in: home)
        try await service.setEnabled(skill.id, app: .claude, enabled: true, method: .copy)
        let builtIn = try home.makeSkillDirectory(
            at: codexSystem(home).appendingPathComponent("alpha"),
            description: "bundled wording",
            extraFiles: ["ref.md": "bundled"]
        )
        let builtInBefore = try SkillDirectoryHasher.hash(directory: builtIn)
        let before = await service.installedSkills()
        let copy = try XCTUnwrap(before.first?.otherCopies.first)
        XCTAssertFalse(copy.sameAsShared)

        let replaced = try await service.replaceSharedCopy(skill.id, with: copy)

        let shared = home.ssot.appendingPathComponent("alpha")
        XCTAssertEqual(home.contents(of: shared.appendingPathComponent("ref.md")), "bundled")
        XCTAssertEqual(replaced.contentHash, try SkillDirectoryHasher.hash(directory: shared))
        XCTAssertEqual(replaced.description, "bundled wording")
        XCTAssertNotNil(replaced.updatedAt)
        // The backup holds the previous shared content.
        let backups = service.listBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            home.contents(of: try XCTUnwrap(backups.first).url.appendingPathComponent("skill/ref.md")),
            "shared"
        )
        // The managed `.copy` projection follows the new content.
        XCTAssertEqual(
            home.contents(of: home.appDirectory(.claude).appendingPathComponent("alpha/ref.md")),
            "bundled"
        )
        // The built-in itself is untouched.
        XCTAssertEqual(try SkillDirectoryHasher.hash(directory: builtIn), builtInBefore)

        let reloaded = await service.installedSkills()
        let after = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(after.otherCopies.map(\.sameAsShared), [true])
        XCTAssertEqual(after.contentHash, replaced.contentHash)
    }

    func testReplaceSharedCopyRefusesACopyOutsideTheScannedRoots() async throws {
        let home = try SkillTestHome()
        let (service, skill) = try await installAlpha(in: home)
        let elsewhere = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Elsewhere/alpha"),
            extraFiles: ["ref.md": "elsewhere"]
        )
        let forged = [
            // Right name, wrong place.
            SkillCopy(
                directoryName: "alpha", name: "alpha", description: nil,
                location: .appFolder(.claude), url: elsewhere
            ),
            // The shared library is never a source for itself.
            SkillCopy(
                directoryName: "alpha", name: "alpha", description: nil,
                location: .shared, url: home.ssot.appendingPathComponent("alpha")
            ),
            // A symlink where a real folder is expected.
            SkillCopy(
                directoryName: "alpha", name: "alpha", description: nil,
                location: .appFolder(.cursor),
                url: home.appDirectory(.cursor).appendingPathComponent("alpha")
            ),
        ]
        try home.makeSymlink("alpha", in: .cursor, rawTarget: elsewhere.path)

        for copy in forged {
            do {
                try await service.replaceSharedCopy(skill.id, with: copy)
                XCTFail("expected a refusal for \(copy.location)")
            } catch let error as SkillError {
                XCTAssertTrue(
                    [.copyOutsideScannedRoots("alpha"), .sourceNotADirectory("alpha")].contains(error),
                    "\(error)"
                )
            }
        }
        XCTAssertEqual(
            home.contents(of: home.ssot.appendingPathComponent("alpha/ref.md")),
            "shared"
        )
        XCTAssertEqual(service.listBackups().count, 0)
    }

    func testCopyToSharedInstallsABuiltInWithNoAppsEnabled() async throws {
        let home = try SkillTestHome()
        let service = SkillsService(homeDirectory: home.path)
        let builtIn = try home.makeSkillDirectory(
            at: codexSystem(home).appendingPathComponent("imagegen"),
            description: "bundled",
            extraFiles: ["ref.md": "bundled"]
        )
        let builtInBefore = home.lstatSnapshot().filter { $0.key.contains("/.system") }
        let builtIns = await service.builtInSkills()
        let copy = try XCTUnwrap(builtIns.first)

        let installed = try await service.copyToShared(copy)

        XCTAssertEqual(installed.id, .local(directory: "imagegen"))
        XCTAssertTrue(installed.apps.isEmpty)
        XCTAssertEqual(installed.contentHash, try SkillDirectoryHasher.hash(directory: builtIn))
        XCTAssertEqual(home.lstatSnapshot().filter { $0.key.contains("/.system") }, builtInBefore)
        // Now installed, the built-in becomes one of its copies rather than a
        // standalone row.
        let inventory = await service.inventory()
        XCTAssertEqual(inventory.builtIns, [])
        XCTAssertEqual(inventory.installed.first?.otherCopies.map(\.sameAsShared), [true])
    }
}
