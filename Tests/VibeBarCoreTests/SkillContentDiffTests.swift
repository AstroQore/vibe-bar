import XCTest
@testable import VibeBarCore

/// The copies detail: which versions of a skill exist, and what differs
/// between two of them — file list and line diff. Every tree is synthetic,
/// under a disposable home.
final class SkillContentDiffTests: XCTestCase {
    private func scope(_ home: SkillTestHome) -> SkillReadScope {
        SkillReadScope.standard(homeDirectory: home.path)
    }

    private func claudeCopy(_ home: SkillTestHome, _ name: String = "alpha") -> URL {
        home.appDirectory(.claude).appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Tree comparison

    func testIdenticalTreesCompareUnchanged() throws {
        let home = try SkillTestHome()
        let shared = try home.makeSSOTSkill("alpha", extraFiles: ["ref/notes.md": "same"])
        try home.makeDirectory(home.appDirectory(.claude))
        try FileManager.default.copyItem(at: shared, to: claudeCopy(home))

        let comparison = try SkillContentDiff.compare(left: shared, right: claudeCopy(home), scope: scope(home))

        XCTAssertTrue(comparison.isIdentical)
        XCTAssertEqual(comparison.files.map(\.path), ["SKILL.md", "ref/notes.md"])
        XCTAssertEqual(comparison.defaultSelection, "SKILL.md")
        let diff = SkillContentDiff.diffFile(path: "SKILL.md", left: shared, right: claudeCopy(home), scope: scope(home))
        guard case let .text(lines) = diff else { return XCTFail("expected text, got \(diff)") }
        XCTAssertTrue(lines.isIdentical)
    }

    func testSingleFileModificationProducesLineDiff() throws {
        let home = try SkillTestHome()
        let body = (1 ... 20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let shared = try home.makeSSOTSkill("alpha", extraFiles: ["guide.md": body])
        let edited = body.replacingOccurrences(of: "line 10\n", with: "line ten\nline 10b\n")
        try home.makeSkillDirectory(at: claudeCopy(home), name: "alpha", extraFiles: ["guide.md": edited])

        let comparison = try SkillContentDiff.compare(left: shared, right: claudeCopy(home), scope: scope(home))
        XCTAssertEqual(comparison.files.first { $0.path == "guide.md" }?.change, .modified)
        XCTAssertEqual(comparison.files.first { $0.path == "SKILL.md" }?.change, .unchanged)
        XCTAssertEqual(comparison.count(.modified), 1)

        let diff = SkillContentDiff.diffFile(path: "guide.md", left: shared, right: claudeCopy(home), scope: scope(home))
        guard case let .text(lines) = diff else { return XCTFail("expected text, got \(diff)") }
        XCTAssertEqual(lines.removedCount, 1)
        XCTAssertEqual(lines.addedCount, 2)
        XCTAssertEqual(lines.hunks.count, 1)
        let hunk = lines.hunks[0]
        XCTAssertEqual(hunk.header, "@@ -7,7 +7,8 @@")
        XCTAssertEqual(hunk.lines.filter { $0.kind == .removed }.map(\.text), ["line 10"])
        XCTAssertEqual(hunk.lines.filter { $0.kind == .added }.map(\.text), ["line ten", "line 10b"])
        XCTAssertEqual(hunk.lines.first { $0.kind == .removed }?.oldNumber, 10)
        XCTAssertEqual(hunk.lines.first { $0.kind == .added }?.newNumber, 10)

        let rows = SkillLineDiff.sideBySideRows(hunk)
        XCTAssertEqual(rows.count, 3 + 2 + 3)
        XCTAssertEqual(rows[3].left?.text, "line 10")
        XCTAssertEqual(rows[3].right?.text, "line ten")
        XCTAssertNil(rows[4].left)
        XCTAssertEqual(rows[4].right?.text, "line 10b")
    }

    func testAddedAndRemovedFiles() throws {
        let home = try SkillTestHome()
        let shared = try home.makeSSOTSkill("alpha", extraFiles: ["old.md": "gone\n"])
        try home.makeSkillDirectory(at: claudeCopy(home), name: "alpha", extraFiles: ["scripts/new.sh": "echo hi\n"])

        let comparison = try SkillContentDiff.compare(left: shared, right: claudeCopy(home), scope: scope(home))

        XCTAssertEqual(comparison.files.first { $0.path == "old.md" }?.change, .removed)
        XCTAssertEqual(comparison.files.first { $0.path == "scripts/new.sh" }?.change, .added)
        XCTAssertFalse(comparison.isIdentical)

        let added = SkillContentDiff.diffFile(path: "scripts/new.sh", left: shared, right: claudeCopy(home), scope: scope(home))
        guard case let .text(addedLines) = added else { return XCTFail("expected text") }
        XCTAssertEqual(addedLines.addedCount, 1)
        XCTAssertEqual(addedLines.removedCount, 0)
        XCTAssertEqual(addedLines.hunks.first?.header, "@@ -0,0 +1,1 @@")

        let removed = SkillContentDiff.diffFile(path: "old.md", left: shared, right: claudeCopy(home), scope: scope(home))
        guard case let .text(removedLines) = removed else { return XCTFail("expected text") }
        XCTAssertEqual(removedLines.removedCount, 1)
        XCTAssertEqual(removedLines.addedCount, 0)
    }

    func testBinaryAndOversizedFilesShowOnlyFacts() throws {
        let home = try SkillTestHome()
        let shared = try home.makeSSOTSkill("alpha")
        try home.makeSkillDirectory(at: claudeCopy(home), name: "alpha")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: shared.appendingPathComponent("icon.png"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02]).write(to: claudeCopy(home).appendingPathComponent("icon.png"))
        let big = String(repeating: "x", count: 64) + "\n"
        try home.write(String(repeating: big, count: 100), to: shared.appendingPathComponent("big.txt"))
        try home.write(String(repeating: big, count: 101), to: claudeCopy(home).appendingPathComponent("big.txt"))

        let limits = SkillDiffLimits(maxTextBytes: 4_096)
        let comparison = try SkillContentDiff.compare(left: shared, right: claudeCopy(home), scope: scope(home), limits: limits)
        XCTAssertEqual(comparison.files.first { $0.path == "icon.png" }?.change, .modified)

        let binary = SkillContentDiff.diffFile(path: "icon.png", left: shared, right: claudeCopy(home), scope: scope(home), limits: limits)
        guard case let .binary(left, right) = binary else { return XCTFail("expected binary, got \(binary)") }
        XCTAssertEqual(left?.size, 6)
        XCTAssertEqual(right?.size, 6)
        XCTAssertNotEqual(left?.sha256, right?.sha256)

        let large = SkillContentDiff.diffFile(path: "big.txt", left: shared, right: claudeCopy(home), scope: scope(home), limits: limits)
        guard case let .tooLarge(bigLeft, bigRight) = large else { return XCTFail("expected tooLarge, got \(large)") }
        XCTAssertEqual(bigLeft?.size, 6_500)
        XCTAssertEqual(bigRight?.size, 6_565)

        let manyLines = SkillContentDiff.diffFile(
            path: "big.txt", left: shared, right: claudeCopy(home), scope: scope(home),
            limits: SkillDiffLimits(maxLines: 50)
        )
        guard case .tooLarge = manyLines else { return XCTFail("expected tooLarge by line count") }
    }

    func testDirectoryOutsideScopeIsRefused() throws {
        let home = try SkillTestHome()
        let shared = try home.makeSSOTSkill("alpha")
        let elsewhere = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Documents/alpha"), name: "alpha")

        XCTAssertThrowsError(try SkillContentDiff.compare(left: shared, right: elsewhere, scope: scope(home)))
        XCTAssertEqual(
            SkillContentDiff.diffFile(path: "SKILL.md", left: shared, right: elsewhere, scope: scope(home)),
            .unreadable
        )
        // A skills root itself is never a skill directory.
        XCTAssertNil(scope(home).resolvedSkillDirectory(home.ssot))
    }

    func testInnerSymlinksAreComparedAsTargetsAndNeverFollowed() throws {
        let home = try SkillTestHome()
        let secret = home.url.appendingPathComponent("Documents/secret.txt")
        try home.write("do not read\n", to: secret)
        let shared = try home.makeSSOTSkill("alpha")
        try home.makeSkillDirectory(at: claudeCopy(home), name: "alpha")
        try FileManager.default.createSymbolicLink(
            atPath: claudeCopy(home).appendingPathComponent("leak.txt").path,
            withDestinationPath: secret.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: claudeCopy(home).appendingPathComponent("docs").path,
            withDestinationPath: home.url.appendingPathComponent("Documents").path
        )

        let comparison = try SkillContentDiff.compare(left: shared, right: claudeCopy(home), scope: scope(home))
        let leak = try XCTUnwrap(comparison.files.first { $0.path == "leak.txt" })
        XCTAssertEqual(leak.right?.kind, .symlink(target: secret.path))
        XCTAssertNil(comparison.files.first { $0.path.hasPrefix("docs/") }, "a linked directory is not walked")

        let diff = SkillContentDiff.diffFile(path: "leak.txt", left: shared, right: claudeCopy(home), scope: scope(home))
        XCTAssertEqual(diff, .symlink(left: nil, right: secret.path))
        // Through a linked parent, nothing is read either.
        XCTAssertEqual(
            SkillContentDiff.diffFile(path: "docs/secret.txt", left: shared, right: claudeCopy(home), scope: scope(home)),
            .unreadable
        )
        XCTAssertEqual(
            SkillContentDiff.diffFile(path: "../alpha/SKILL.md", left: shared, right: claudeCopy(home), scope: scope(home)),
            .unreadable
        )
    }

    func testFileLimitTruncates() throws {
        let home = try SkillTestHome()
        var files: [String: String] = [:]
        for index in 0 ..< 10 { files["f\(index).md"] = "\(index)" }
        let shared = try home.makeSSOTSkill("alpha", extraFiles: files)
        let comparison = try SkillContentDiff.compare(
            left: shared, right: nil, scope: scope(home), limits: SkillDiffLimits(maxFiles: 4)
        )
        XCTAssertTrue(comparison.truncated)
        XCTAssertEqual(comparison.files.count, 4)
        XCTAssertTrue(comparison.files.allSatisfy { $0.change == .removed })
    }

    func testLineDiffEdgeCases() {
        XCTAssertTrue(SkillLineDiff.compute(old: [], new: []).isIdentical)
        let separate = SkillLineDiff.compute(
            old: (1 ... 30).map(String.init),
            new: (1 ... 30).map { $0 == 2 || $0 == 28 ? "x\($0)" : String($0) }
        )
        XCTAssertEqual(separate.hunks.count, 2, "changes far apart get separate hunks")
        XCTAssertEqual(SkillContentDiff.textLines(Data("a\r\nb\n".utf8)), ["a", "b"])
        XCTAssertNil(SkillContentDiff.textLines(Data([0x61, 0x00, 0x62])))
        XCTAssertNil(SkillContentDiff.textLines(Data([0xFF, 0xFE, 0xFD])))
    }

    // MARK: - Version inventory

    private func installAlpha(_ home: SkillTestHome, extra: [String: String] = ["ref.md": "shared\n"]) async throws -> SkillsService {
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/alpha"), extraFiles: extra)
        let service = SkillsService(homeDirectory: home.path)
        _ = try await service.installLocal(from: staging, name: "alpha")
        return service
    }

    func testInventoryListsEveryKindOfVersion() async throws {
        let home = try SkillTestHome()
        let service = try await installAlpha(home)
        // Symlink projection to the shared copy, an independent copy that
        // differs, a link that escapes every skill folder, and a built-in.
        try home.makeAbsoluteSymlink("alpha", in: .codex, toSSOT: "alpha")
        try home.makeSkillDirectory(at: claudeCopy(home), name: "alpha", extraFiles: ["ref.md": "edited\n"])
        let outside = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Documents/alpha"), name: "alpha")
        try home.makeSymlink("alpha", in: .grok, rawTarget: outside.path)
        try home.makeSymlink("alpha", in: .gemini, rawTarget: home.url.appendingPathComponent("nowhere").path)
        try home.makeSkillDirectory(
            at: home.appDirectory(.codex).appendingPathComponent(".system/alpha"),
            name: "alpha"
        )
        let before = home.lstatSnapshot()

        let all = await service.installedSkills()
        let skill = try XCTUnwrap(all.first { $0.directory == "alpha" })
        let inventory = SkillVersionScanner.inventory(for: skill, homeDirectory: home.path)
        XCTAssertEqual(home.lstatSnapshot(), before, "building the inventory writes nothing")

        let byKind = Dictionary(inventory.versions.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let shared = try XCTUnwrap(inventory.shared)
        XCTAssertEqual(inventory.versions.first?.kind, .shared)
        XCTAssertEqual(shared.comparison, .source)
        XCTAssertTrue(shared.isReadable)

        let codexLink = try XCTUnwrap(byKind[.symlink(.codex)])
        XCTAssertEqual(codexLink.linkState, .shared)
        XCTAssertEqual(codexLink.comparison, .source)
        XCTAssertEqual(codexLink.linkTarget, home.ssot.appendingPathComponent("alpha").path)

        let claude = try XCTUnwrap(byKind[.independentCopy(.claude)])
        XCTAssertEqual(claude.comparison, .differs)
        XCTAssertNotNil(claude.copy, "the replace action needs the scanned copy")

        let grok = try XCTUnwrap(byKind[.symlink(.grok)])
        XCTAssertEqual(grok.linkState, .outside)
        XCTAssertFalse(grok.isReadable)
        XCTAssertEqual(grok.comparison, .unknown)

        XCTAssertEqual(byKind[.symlink(.gemini)]?.linkState, .broken)
        XCTAssertEqual(byKind[.builtIn(.codex)]?.comparison, .differs, "the built-in has no ref.md")
        XCTAssertEqual(inventory.baseline, .notModified)

        // The comparison a detail opens on: shared vs the differing copy.
        let comparison = try SkillContentDiff.compare(
            left: shared.readableURL, right: claude.readableURL, scope: scope(home)
        )
        XCTAssertEqual(comparison.files.first { $0.path == "ref.md" }?.change, .modified)
    }

    func testManagedCopyProjectionIsListed() async throws {
        let home = try SkillTestHome()
        let service = try await installAlpha(home)
        let first = await service.installedSkills()
        let installed = try XCTUnwrap(first.first)
        _ = try await service.setActivation(installed.id, app: .claude, action: .enable, method: .copy)

        let latest = await service.installedSkills()
        let skill = try XCTUnwrap(latest.first)
        let inventory = SkillVersionScanner.inventory(for: skill, homeDirectory: home.path)
        let managed = try XCTUnwrap(inventory.versions.first { $0.kind == .managedCopy(.claude) })
        XCTAssertEqual(managed.comparison, .identical)
    }

    func testBaselineRecoveredFromMatchingBackup() async throws {
        let home = try SkillTestHome()
        let service = try await installAlpha(home)
        let first = await service.installedSkills()
        let recorded = try XCTUnwrap(first.first)
        try SkillBackupManager(homeDirectory: home.path).createBackup(of: "alpha", skill: recorded)
        try home.write("hand edit\n", to: home.ssot.appendingPathComponent("alpha/ref.md"))

        let latest = await service.installedSkills()
        let skill = try XCTUnwrap(latest.first)
        XCTAssertTrue(skill.isLocallyModified)
        let inventory = SkillVersionScanner.inventory(for: skill, homeDirectory: home.path)
        XCTAssertEqual(inventory.baseline, .recovered)
        let baseline = try XCTUnwrap(inventory.recordedBaseline)
        XCTAssertEqual(baseline.contentHash, skill.contentHash)

        let diff = SkillContentDiff.diffFile(
            path: "ref.md", left: baseline.readableURL, right: inventory.shared?.readableURL, scope: scope(home)
        )
        guard case let .text(lines) = diff else { return XCTFail("expected text") }
        XCTAssertEqual(lines.hunks.first?.lines.map(\.text), ["shared", "hand edit"])
    }

    func testBaselineUnavailableWithoutSnapshot() async throws {
        let home = try SkillTestHome()
        let service = try await installAlpha(home)
        try home.write("hand edit\n", to: home.ssot.appendingPathComponent("alpha/ref.md"))

        let latest = await service.installedSkills()
        let skill = try XCTUnwrap(latest.first)
        let inventory = SkillVersionScanner.inventory(for: skill, homeDirectory: home.path)
        XCTAssertEqual(inventory.baseline, .unavailable)
        XCTAssertNil(inventory.recordedBaseline)
    }
}
