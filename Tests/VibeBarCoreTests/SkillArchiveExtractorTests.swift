import XCTest
@testable import VibeBarCore

/// The archive reader is the only place Vibe Bar parses attacker-shaped bytes,
/// so these tests are split evenly between "does it read a real zip correctly"
/// (fixtures from `/usr/bin/zip`) and "does it refuse the classic zip attacks"
/// (hand-built archives — see `SkillZipFixtures`).
final class SkillArchiveExtractorTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Real archives

    func testExtractsANestedSkillTreeByteIdentically() throws {
        let source = workspace.appendingPathComponent("payload", isDirectory: true)
        let nested = source.appendingPathComponent("skills/pdf/reference", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "---\nname: pdf\n---\n# PDF\n".write(
            to: source.appendingPathComponent("skills/pdf/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        // Big enough that `zip` reaches for deflate rather than storing it.
        let bulky = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 2_000)
        try bulky.write(to: nested.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try Data((0..<256).map { UInt8($0) }).write(to: nested.appendingPathComponent("bytes.bin"))
        try "top".write(
            to: source.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let archive = try SkillZipFixtures.zipDirectory(named: "payload", in: workspace)
        let destination = workspace.appendingPathComponent("out", isDirectory: true)
        let written = try SkillArchiveExtractor.extract(zipFileURL: archive, into: destination)

        XCTAssertEqual(written, 4)
        let extracted = destination.appendingPathComponent("payload", isDirectory: true)
        XCTAssertEqual(
            try SkillDirectoryHasher.hash(directory: extracted),
            try SkillDirectoryHasher.hash(directory: source),
            "The extracted tree must hash identically to the one that was zipped"
        )
        XCTAssertEqual(
            try Data(contentsOf: extracted.appendingPathComponent("skills/pdf/reference/bytes.bin")),
            Data((0..<256).map { UInt8($0) })
        )
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("skills/pdf/reference/notes.md"), encoding: .utf8),
            bulky
        )
    }

    func testRejectsASymlinkEntryWrittenByRealZip() throws {
        let source = workspace.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "real".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("escape").path,
            withDestinationPath: "/etc/passwd"
        )

        let archive = try SkillZipFixtures.zipDirectory(
            named: "linked",
            in: workspace,
            extraArguments: ["--symlinks"]
        )
        let destination = workspace.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(try SkillArchiveExtractor.extract(zipFileURL: archive, into: destination)) { error in
            guard case .symlinkEntry = error as? SkillArchiveError ?? .notAZipArchive else {
                return XCTFail("Expected symlinkEntry, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("linked/escape").path))
    }

    func testEnforcesTheExtractedByteBudgetOnADeclaredSize() throws {
        let source = workspace.appendingPathComponent("bulk", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // 8 MiB of zeros deflates to a handful of kilobytes: the archive is
        // tiny, the expansion is not.
        try Data(count: 8 * 1024 * 1024).write(to: source.appendingPathComponent("zeros.bin"))
        let archive = try SkillZipFixtures.zipDirectory(named: "bulk", in: workspace)
        XCTAssertLessThan(
            try Data(contentsOf: archive).count,
            256 * 1024,
            "Fixture assumption: the archive itself stays small"
        )

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true),
                maxExtractedBytes: 1024 * 1024
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .archiveTooLarge(limit: 1024 * 1024))
        }
    }

    func testEnforcesTheEntryCountBudgetOnARealArchive() throws {
        let source = workspace.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<6 {
            try "\(index)".write(
                to: source.appendingPathComponent("file\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let archive = try SkillZipFixtures.zipDirectory(named: "many", in: workspace)

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true),
                maxEntries: 3
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .tooManyEntries(limit: 3))
        }
    }

    // MARK: - Hand-built archives

    func testRejectsZipSlipEntries() throws {
        for name in ["../escape.txt", "skills/../../escape.txt", "/etc/escape.txt", "a/./b.txt"] {
            var builder = RawZipBuilder()
            builder.entries = [.file(name, "owned")]
            let archive = try builder.write(to: workspace.appendingPathComponent("slip.zip"))
            let destination = workspace.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)

            XCTAssertThrowsError(
                try SkillArchiveExtractor.extract(zipFileURL: archive, into: destination),
                "\(name) must be refused"
            ) { error in
                XCTAssertEqual(error as? SkillArchiveError, .unsafeEntryPath(name))
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape.txt").path)
            )
        }
    }

    func testRejectsAHandBuiltSymlinkEntry() throws {
        var builder = RawZipBuilder()
        builder.entries = [
            .file("skill/SKILL.md", "---\nname: x\n---\n"),
            .symlink("skill/link", target: "../../../../etc/passwd")
        ]
        let archive = try builder.write(to: workspace.appendingPathComponent("link.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .symlinkEntry("skill/link"))
        }
    }

    func testRejectsAnInflatedEntryOnTheRunningBudget() throws {
        // The central directory lies about the uncompressed size, so the
        // up-front check waves it through; the inflater's own accounting is
        // what must stop it.
        let payload = Data(count: 4 * 1024 * 1024)
        var builder = RawZipBuilder()
        builder.entries = [.deflated("zeros.bin", payload: payload, declaredSize: 64)]
        let archive = try builder.write(to: workspace.appendingPathComponent("bomb.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true),
                maxExtractedBytes: 512 * 1024
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .archiveTooLarge(limit: 512 * 1024))
        }
    }

    func testRejectsAnEndOfCentralDirectoryClaimingTooManyEntries() throws {
        var builder = RawZipBuilder()
        builder.entries = [.file("a.txt", "a")]
        builder.entryCountOverride = 20_000
        let archive = try builder.write(to: workspace.appendingPathComponent("count.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? SkillArchiveError,
                .tooManyEntries(limit: SkillArchiveExtractor.maxEntries)
            )
        }
    }

    func testReportsAnUnsupportedCompressionMethodByID() throws {
        var builder = RawZipBuilder()
        var entry = RawZipBuilder.Entry.file("a.txt", "a")
        entry.method = 12  // bzip2 — legal ZIP, not something we decode.
        builder.entries = [entry]
        let archive = try builder.write(to: workspace.appendingPathComponent("bzip.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .unsupportedCompressionMethod(12))
        }
    }

    func testRejectsDuplicateNormalizedEntries() throws {
        var builder = RawZipBuilder()
        builder.entries = [.file("skill/notes.md", "first"), .file("skill/Notes.md", "second")]
        let archive = try builder.write(to: workspace.appendingPathComponent("dupe.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .duplicateEntry("skill/Notes.md"))
        }
    }

    func testRejectsAnEntryNameThatIsNotUTF8() throws {
        var entry = RawZipBuilder.Entry.file("bad", "x")
        entry.rawName = Data([0x66, 0xFF, 0xFE, 0x2E, 0x6D, 0x64])
        var builder = RawZipBuilder()
        builder.entries = [entry]
        let archive = try builder.write(to: workspace.appendingPathComponent("utf8.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .invalidEntryName)
        }
    }

    func testRejectsAnEncryptedEntry() throws {
        var entry = RawZipBuilder.Entry.file("secret.md", "x")
        entry.flags = 0x0801
        var builder = RawZipBuilder()
        builder.entries = [entry]
        let archive = try builder.write(to: workspace.appendingPathComponent("crypt.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .encryptedEntry("secret.md"))
        }
    }

    func testRejectsAChecksumMismatch() throws {
        var entry = RawZipBuilder.Entry.file("a.txt", "hello")
        entry.crc = 0xDEAD_BEEF
        var builder = RawZipBuilder()
        builder.entries = [entry]
        let archive = try builder.write(to: workspace.appendingPathComponent("crc.zip"))

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: archive,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .checksumMismatch("a.txt"))
        }
    }

    func testRejectsSomethingThatIsNotAZipAtAll() throws {
        let file = workspace.appendingPathComponent("not.zip")
        try Data("this is plainly not a zip archive".utf8).write(to: file)

        XCTAssertThrowsError(
            try SkillArchiveExtractor.extract(
                zipFileURL: file,
                into: workspace.appendingPathComponent("out", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? SkillArchiveError, .notAZipArchive)
        }
    }

    func testExtractsStoredEntriesAndDirectoryMarkers() throws {
        var builder = RawZipBuilder()
        builder.entries = [
            .directory("skill"),
            .file("skill/SKILL.md", "---\nname: demo\n---\n"),
            .file("skill/reference/notes.md", "deep")
        ]
        let archive = try builder.write(to: workspace.appendingPathComponent("plain.zip"))
        let destination = workspace.appendingPathComponent("out", isDirectory: true)

        let written = try SkillArchiveExtractor.extract(zipFileURL: archive, into: destination)

        XCTAssertEqual(written, 2)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("skill/reference/notes.md"), encoding: .utf8),
            "deep"
        )
    }
}
