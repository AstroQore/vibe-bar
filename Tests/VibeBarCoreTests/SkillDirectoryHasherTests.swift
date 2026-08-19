import XCTest
@testable import VibeBarCore

final class SkillDirectoryHasherTests: XCTestCase {
    func testHashIsIndependentOfFileCreationOrder() throws {
        let home = try SkillTestHome()
        let first = home.url.appendingPathComponent("first", isDirectory: true)
        try home.write("alpha", to: first.appendingPathComponent("a.md"))
        try home.write("beta", to: first.appendingPathComponent("nested/b.md"))
        try home.write("gamma", to: first.appendingPathComponent("c.md"))

        let second = home.url.appendingPathComponent("second", isDirectory: true)
        try home.write("gamma", to: second.appendingPathComponent("c.md"))
        try home.write("beta", to: second.appendingPathComponent("nested/b.md"))
        try home.write("alpha", to: second.appendingPathComponent("a.md"))

        XCTAssertEqual(
            try SkillDirectoryHasher.hash(directory: first),
            try SkillDirectoryHasher.hash(directory: second)
        )
    }

    func testHiddenEntriesAreExcluded() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSSOTSkill("hidden-skill")
        let before = try SkillDirectoryHasher.hash(directory: directory)

        try home.write("junk", to: directory.appendingPathComponent(".DS_Store"))
        try home.write("ref: refs/heads/main", to: directory.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(try SkillDirectoryHasher.hash(directory: directory), before)

        try home.write("visible", to: directory.appendingPathComponent("visible.md"))
        XCTAssertNotEqual(try SkillDirectoryHasher.hash(directory: directory), before)
    }

    func testSymlinksHashAsTargetPathNotTargetContents() throws {
        let home = try SkillTestHome()
        let outside = home.url.appendingPathComponent("outside", isDirectory: true)
        try home.write("original", to: outside.appendingPathComponent("payload.txt"))
        let other = home.url.appendingPathComponent("other", isDirectory: true)
        try home.write("different", to: other.appendingPathComponent("payload.txt"))

        let directory = try home.makeSSOTSkill("linky")
        let link = directory.appendingPathComponent("payload.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outside.appendingPathComponent("payload.txt").path
        )
        let before = try SkillDirectoryHasher.hash(directory: directory)

        // Rewriting what the link points at must not move the hash...
        try home.write("rewritten", to: outside.appendingPathComponent("payload.txt"))
        XCTAssertEqual(try SkillDirectoryHasher.hash(directory: directory), before)

        // ...but re-pointing the link itself must.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: other.appendingPathComponent("payload.txt").path
        )
        XCTAssertNotEqual(try SkillDirectoryHasher.hash(directory: directory), before)
    }

    func testSeparatorsPreventPathContentCollisions() throws {
        let home = try SkillTestHome()
        let first = home.url.appendingPathComponent("collide-a", isDirectory: true)
        try home.write("c", to: first.appendingPathComponent("ab"))

        let second = home.url.appendingPathComponent("collide-b", isDirectory: true)
        try home.write("bc", to: second.appendingPathComponent("a"))

        XCTAssertNotEqual(
            try SkillDirectoryHasher.hash(directory: first),
            try SkillDirectoryHasher.hash(directory: second)
        )
    }

    func testContentChangeMovesTheHash() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSSOTSkill("mutable", extraFiles: ["notes.md": "one"])
        let before = try SkillDirectoryHasher.hash(directory: directory)
        try home.write("two", to: directory.appendingPathComponent("notes.md"))
        XCTAssertNotEqual(try SkillDirectoryHasher.hash(directory: directory), before)
    }

    func testHashIsStableAcrossRepeatedRuns() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSSOTSkill("stable", extraFiles: ["a/b/c.md": "deep"])
        XCTAssertEqual(
            try SkillDirectoryHasher.hash(directory: directory),
            try SkillDirectoryHasher.hash(directory: directory)
        )
    }

    func testMetadataStampIsStableAndMovesWhenTheTreeChanges() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSSOTSkill("stamped", extraFiles: ["a.md": "one"])
        let before = try SkillDirectoryHasher.metadataStamp(directory: directory)
        XCTAssertEqual(before, try SkillDirectoryHasher.metadataStamp(directory: directory))

        try home.write("second", to: directory.appendingPathComponent("nested/b.md"))
        XCTAssertNotEqual(before, try SkillDirectoryHasher.metadataStamp(directory: directory))
    }
}
