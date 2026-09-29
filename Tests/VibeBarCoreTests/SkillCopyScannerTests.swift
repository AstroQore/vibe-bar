import XCTest
@testable import VibeBarCore

final class SkillCopyScannerTests: XCTestCase {
    private func builtInRoot(_ app: SkillAppTarget, in home: SkillTestHome) throws -> URL {
        try XCTUnwrap(SkillAppCatalog.builtInSkillRoots(for: app, homeDirectory: home.path).first)
    }

    func testFindsBuiltInsAndAppFolderDirectoriesOnly() throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("linked")
        try home.makeSkillDirectory(
            at: builtInRoot(.codex, in: home).appendingPathComponent("imagegen"),
            description: "codex bundled"
        )
        try home.makeSkillDirectory(at: builtInRoot(.grok, in: home).appendingPathComponent("review"))
        try home.makeSkillDirectory(at: builtInRoot(.cursor, in: home).appendingPathComponent("create-rule"))
        try home.makeSkillDirectory(
            at: home.appDirectory(.claude).appendingPathComponent("handmade"),
            name: "Hand Made"
        )
        // A projection of the shared copy, a folder that is not a skill, and
        // a hidden folder are none of them copies.
        try home.makeAbsoluteSymlink("linked", in: .claude, toSSOT: "linked")
        try home.makeDirectory(home.appDirectory(.claude).appendingPathComponent("notes"))
        try home.makeSkillDirectory(at: home.appDirectory(.gemini).appendingPathComponent(".hidden"))

        let copies = SkillCopyScanner(homeDirectory: home.path).scan()

        XCTAssertEqual(copies.map(\.directoryName), ["handmade", "imagegen", "review", "create-rule"])
        XCTAssertEqual(copies.map(\.location), [
            .appFolder(.claude), .builtIn(.codex), .builtIn(.grok), .builtIn(.cursor),
        ])
        XCTAssertEqual(copies[0].name, "Hand Made")
        XCTAssertEqual(copies[1].description, "codex bundled")
        // The tree walk and the hash are on request only.
        XCTAssertTrue(copies.allSatisfy { $0.contentHash == nil && $0.modifiedAt == nil })
        // Codex's `.system` lives inside `~/.codex/skills` but is reported
        // once, as the built-in root — never as an app-folder entry.
        XCTAssertFalse(copies.contains { $0.location == .appFolder(.codex) })
    }

    func testEmptyHomeHasNoCopies() throws {
        let home = try SkillTestHome()
        XCTAssertEqual(SkillCopyScanner(homeDirectory: home.path).scan(), [])
    }

    func testScanChangesNothingOnDisk() throws {
        let home = try SkillTestHome()
        try home.makeSkillDirectory(at: builtInRoot(.codex, in: home).appendingPathComponent("imagegen"))
        try home.makeSkillDirectory(at: home.appDirectory(.claude).appendingPathComponent("handmade"))
        let before = home.lstatSnapshot()

        let scanner = SkillCopyScanner(homeDirectory: home.path)
        for copy in scanner.scan() { _ = scanner.withContentHash(copy) }

        XCTAssertEqual(home.lstatSnapshot(), before)
    }

    func testBuiltInRootsAreNeverWritable() throws {
        let home = try SkillTestHome()
        let roots = SkillAppTarget.allCases.flatMap {
            SkillAppCatalog.builtInSkillRoots(for: $0, homeDirectory: home.path)
        }
        XCTAssertFalse(roots.isEmpty)
        for root in roots {
            XCTAssertFalse(SkillAppCatalog.isWriteAllowed(root, homeDirectory: home.path), root.path)
            XCTAssertFalse(
                SkillAppCatalog.isWriteAllowed(
                    root.appendingPathComponent("imagegen/SKILL.md"),
                    homeDirectory: home.path
                ),
                root.path
            )
        }
        // The app root that contains Codex's `.system` stays writable.
        XCTAssertTrue(
            SkillAppCatalog.isWriteAllowed(
                home.appDirectory(.codex).appendingPathComponent("imagegen"),
                homeDirectory: home.path
            )
        )
        // A sibling whose name merely starts with the built-in folder's name
        // is not inside it.
        XCTAssertTrue(
            SkillAppCatalog.isWriteAllowed(
                home.appDirectory(.codex).appendingPathComponent(".system-other"),
                homeDirectory: home.path
            )
        )
    }

    func testUnchangedTreeIsNotRehashed() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSkillDirectory(
            at: builtInRoot(.codex, in: home).appendingPathComponent("imagegen"),
            extraFiles: ["ref.md": "one"]
        )
        let scanner = SkillCopyScanner(homeDirectory: home.path)

        let first = try XCTUnwrap(scanner.scan().first)
        let hashed = scanner.withContentHash(first)
        XCTAssertEqual(hashed.contentHash, try SkillDirectoryHasher.hash(directory: directory))
        XCTAssertNotNil(hashed.modifiedAt)
        XCTAssertEqual(scanner.hashComputations, 1)

        // Unchanged tree: the next poll reuses the cached hash.
        let second = try XCTUnwrap(scanner.scan().first)
        XCTAssertEqual(scanner.withContentHash(second).contentHash, hashed.contentHash)
        XCTAssertEqual(scanner.hashComputations, 1)

        // A content change outside SKILL.md moves the tree stamp and forces
        // exactly one fresh hash.
        try home.write("two, and longer", to: directory.appendingPathComponent("ref.md"))
        let third = try XCTUnwrap(scanner.scan().first)
        let rehashed = scanner.withContentHash(third)
        XCTAssertEqual(scanner.hashComputations, 2)
        XCTAssertNotEqual(rehashed.contentHash, hashed.contentHash)
        XCTAssertEqual(rehashed.contentHash, try SkillDirectoryHasher.hash(directory: directory))
    }

    func testTreeMetadataStampMatchesMetadataStampAndReportsNewestMTime() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("tree"),
            extraFiles: ["nested/ref.md": "payload"]
        )
        let newest = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: newest],
            ofItemAtPath: directory.appendingPathComponent("nested/ref.md").path
        )

        let metadata = try SkillDirectoryHasher.treeMetadata(directory: directory)

        XCTAssertEqual(metadata.stamp, try SkillDirectoryHasher.metadataStamp(directory: directory))
        XCTAssertEqual(metadata.newestModification, newest)
    }
}
