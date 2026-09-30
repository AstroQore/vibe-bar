import XCTest
@testable import VibeBarCore

final class SharedSkillDiscoveryTests: XCTestCase {
    func testExistingRegistryDoesNotHideNewSharedEntriesOrDuplicateManagedRows() async throws {
        let home = try SkillTestHome()
        try home.makeSSOTSkill("managed")
        let service = SkillsService(homeDirectory: home.path)
        try await service.store.upsert(Skill(id: .local(directory: "managed"), name: "managed",
            directory: "managed", installedAt: .distantPast))
        let first = await service.inventory()
        XCTAssertEqual(first.installed.map(\.directory), ["managed"])
        XCTAssertTrue(first.discoveredShared.isEmpty)

        try home.makeSSOTSkill("new-shared")
        let second = await service.inventory()
        XCTAssertEqual(second.installed.map(\.directory), ["managed"])
        XCTAssertEqual(second.discoveredShared.map(\.directoryName), ["new-shared"])
        let registry = await service.store.snapshot()
        XCTAssertEqual(registry.skills.map(\.directory), ["managed"], "discovery never adopts new entries")
    }

    func testExternalSharedLinkIsVisiblePreviewableAndDoesNotChangeAnyFile() async throws {
        let home = try SkillTestHome()
        let external = home.url.appendingPathComponent("external-repository/a1-video-agent")
        try home.makeSkillDirectory(at: external, name: "a1-video-agent", description: "Synthetic linked source",
                                    extraFiles: ["scripts/run.py": "synthetic payload"])
        try home.makeDirectory(home.ssot)
        let link = home.ssot.appendingPathComponent("a1-video-agent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let before = home.lstatSnapshot()
        let service = SkillsService(homeDirectory: home.path)
        let inventory = await service.inventory()
        let entry = try XCTUnwrap(inventory.discoveredShared.first)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertTrue(entry.isSymlink)
        XCTAssertEqual(entry.logicalURL.standardizedFileURL, link.standardizedFileURL)
        XCTAssertEqual(entry.resolvedURL, external.resolvingSymlinksInPath())
        XCTAssertEqual(entry.name, "a1-video-agent")
        XCTAssertEqual(entry.agents[.codex], .available)
        XCTAssertNil(entry.agents[.claude], "no Claude projection was invented")
        XCTAssertEqual(inventory.counts(for: .codex).visible, 1)
        XCTAssertEqual(inventory.counts(for: .codex).coupled, 1)
        XCTAssertEqual(inventory.counts(for: .claude).visible, 0)
        let preview = try await service.previewSharedSkill(entry)
        XCTAssertTrue(preview.contains("Synthetic linked source"))
        XCTAssertEqual(home.lstatSnapshot(), before)
        XCTAssertFalse(home.exists(VibeBarLocalStore.baseDirectory(homeDirectory: home.path)))

        // The existing mutation boundary continues to reject an external
        // source. Showing it has not turned it into a managed skill.
        XCTAssertThrowsError(try SkillSyncEngine(homeDirectory: home.path).materialize(
            skillDirectoryName: entry.directoryName, into: .claude, method: .symlink))
        XCTAssertEqual(home.lstatSnapshot(), before)
    }

    func testARegisteredDirectoryReplacedByAnExternalLinkHasOneReadOnlyRow() async throws {
        let home = try SkillTestHome()
        let external = try home.makeSkillDirectory(at: home.url.appendingPathComponent("external/source"))
        try home.makeDirectory(home.ssot)
        try FileManager.default.createSymbolicLink(at: home.ssot.appendingPathComponent("registered"), withDestinationURL: external)
        let service = SkillsService(homeDirectory: home.path)
        try await service.store.upsert(Skill(id: .local(directory: "registered"), name: "registered",
                                             directory: "registered", installedAt: .distantPast))
        let inventory = await service.inventory()
        XCTAssertTrue(inventory.installed.isEmpty, "an old record does not grant write ownership over the new target")
        XCTAssertEqual(inventory.discoveredShared.map(\.directoryName), ["registered"])
        let registry = await service.store.snapshot()
        XCTAssertEqual(registry.skills.count, 1, "inventory leaves the registry record intact")
    }

    func testRelativeLinksAndNativeDisableAreReadFromCurrentDisk() async throws {
        let home = try SkillTestHome()
        let external = home.url.appendingPathComponent("repo/helper")
        try home.makeSkillDirectory(at: external, name: "linked-helper")
        try home.makeDirectory(home.ssot)
        try FileManager.default.createSymbolicLink(atPath: home.ssot.appendingPathComponent("helper").path,
                                                   withDestinationPath: "../../repo/helper")
        try home.makeAbsoluteSymlink("helper", in: .claude, toSSOT: "helper")
        try home.write("[[skills.config]]\npath = \"\(external.appendingPathComponent("SKILL.md").path)\"\nenabled = false\n",
                       to: home.url.appendingPathComponent(".codex/config.toml"))
        let inventory = await SkillsService(homeDirectory: home.path).inventory()
        let entry = try XCTUnwrap(inventory.discoveredShared.first)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertEqual(entry.agents[.codex], .disabled)
        XCTAssertEqual(entry.agents[.cursor], .available)
        XCTAssertEqual(inventory.counts(for: .codex).visible, 0)
        XCTAssertEqual(inventory.counts(for: .codex).nativeDisabled, 1)
        XCTAssertEqual(inventory.counts(for: .cursor).visible, 1)
        XCTAssertEqual(inventory.counts(for: .claude).enabled, 1)
        XCTAssertEqual(inventory.counts(for: .claude).coupled, 0)
    }

    func testBrokenAndCyclicLinksStayVisibleAndCannotBePreviewed() async throws {
        let home = try SkillTestHome()
        try home.makeDirectory(home.ssot)
        try FileManager.default.createSymbolicLink(atPath: home.ssot.appendingPathComponent("broken").path,
                                                   withDestinationPath: "missing-source")
        try FileManager.default.createSymbolicLink(atPath: home.ssot.appendingPathComponent("cycle-a").path,
                                                   withDestinationPath: "cycle-b")
        try FileManager.default.createSymbolicLink(atPath: home.ssot.appendingPathComponent("cycle-b").path,
                                                   withDestinationPath: "cycle-a")
        let service = SkillsService(homeDirectory: home.path)
        let entries = await service.inventory().discoveredShared
        XCTAssertEqual(entries.map(\.directoryName), ["broken", "cycle-a", "cycle-b"])
        XCTAssertEqual(entries.map(\.state), [.brokenLink, .cyclicLink, .cyclicLink])
        for entry in entries {
            do {
                _ = try await service.previewSharedSkill(entry)
                XCTFail("an unavailable linked source was previewed")
            } catch {}
        }
    }

    func testPreviewRefusesARepointedSourceAndEscapingSkillFile() async throws {
        let home = try SkillTestHome()
        let first = try home.makeSkillDirectory(at: home.url.appendingPathComponent("first"))
        let second = try home.makeSkillDirectory(at: home.url.appendingPathComponent("second"))
        try home.makeDirectory(home.ssot)
        let link = home.ssot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let service = SkillsService(homeDirectory: home.path)
        let initial = await service.inventory()
        let old = try XCTUnwrap(initial.discoveredShared.first)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        do {
            _ = try await service.previewSharedSkill(old)
            XCTFail("a changed source was previewed using stale inventory")
        } catch SharedSkillReadError.changedSource {}
        let current = await service.inventory()
        XCTAssertEqual(current.discoveredShared.first?.resolvedURL, second.resolvingSymlinksInPath())

        let directory = try home.makeDirectory(home.ssot.appendingPathComponent("escaping-file"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("SKILL.md"),
                                                   withDestinationURL: first.appendingPathComponent("SKILL.md"))
        let after = await service.inventory()
        XCTAssertEqual(after.discoveredShared.first { $0.directoryName == "escaping-file" }?.state, .unreadable)
    }
}
