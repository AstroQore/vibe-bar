import XCTest
@testable import VibeBarCore

/// Edits made to a shared copy outside Vibe Bar: detected on the reload path
/// at stat cost, back-filled for rows that never had a baseline, cleared by
/// accepting them or by an update.
final class SkillsDriftTests: XCTestCase {
    func testEditingTheSharedCopyReportsItModifiedAndLeavesOthersAlone() async throws {
        let home = try SkillTestHome()
        let service = SkillsService(homeDirectory: home.path)
        for name in ["alpha", "beta"] {
            let staging = try home.makeSkillDirectory(
                at: home.url.appendingPathComponent("Downloads/\(name)"),
                extraFiles: ["ref.md": "v1"]
            )
            _ = try await service.installLocal(from: staging, name: name)
        }

        let before = await service.installedSkills()
        for skill in before {
            XCTAssertFalse(skill.isLocallyModified, skill.directory)
            XCTAssertEqual(skill.localContentHash, skill.contentHash, skill.directory)
        }

        try home.write("v2", to: home.ssot.appendingPathComponent("alpha/ref.md"))
        let after = await service.installedSkills()

        let alpha = try XCTUnwrap(after.first { $0.directory == "alpha" })
        XCTAssertTrue(alpha.isLocallyModified)
        XCTAssertEqual(
            alpha.localContentHash,
            try SkillDirectoryHasher.hash(directory: home.ssot.appendingPathComponent("alpha"))
        )
        XCTAssertNotEqual(alpha.localContentHash, alpha.contentHash)
        let beta = try XCTUnwrap(after.first { $0.directory == "beta" })
        XCTAssertFalse(beta.isLocallyModified)

        // Detection is read-only: the recorded baseline is not moved.
        let stored = await SkillsStore(homeDirectory: home.path).skill(directory: "alpha")
        XCTAssertEqual(stored?.contentHash, before.first { $0.directory == "alpha" }?.contentHash)
        XCTAssertNil(stored?.localContentHash, "The live hash is transient")
    }

    func testARowWithoutARecordedHashIsBackfilledAndNotReportedModified() async throws {
        let home = try SkillTestHome()
        let directory = try home.makeSSOTSkill("legacy", extraFiles: ["ref.md": "as found"])
        // Written the way an older build left it: no contentHash at all.
        try await SkillsStore(homeDirectory: home.path).upsert(
            Skill(
                id: .local(directory: "legacy"),
                name: "legacy",
                directory: "legacy",
                installedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let expected = try SkillDirectoryHasher.hash(directory: directory)
        let service = SkillsService(homeDirectory: home.path)

        let rows = await service.installedSkills()

        let legacy = try XCTUnwrap(rows.first)
        XCTAssertFalse(legacy.isLocallyModified)
        XCTAssertEqual(legacy.contentHash, expected)
        XCTAssertEqual(legacy.localContentHash, expected)
        let persisted = await SkillsStore(homeDirectory: home.path).skill(directory: "legacy")
        XCTAssertEqual(persisted?.contentHash, expected, "The baseline is written back once")

        // From here on it is an ordinary baseline: an edit now counts.
        try home.write("edited", to: directory.appendingPathComponent("ref.md"))
        let edited = await service.installedSkills()
        XCTAssertEqual(edited.first?.isLocallyModified, true)
    }

    func testBackfillNeverOverwritesARecordedHashAndHonorsTheRevision() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)
        let id = SkillID.local(directory: "alpha")
        try await store.upsert(
            Skill(id: id, name: "alpha", directory: "alpha", installedAt: Date(), contentHash: "recorded")
        )

        let snapshot = await store.snapshot()
        let rows = try await store.applyReconciliation(
            expectedRevision: snapshot.revision,
            appsBySkill: [:],
            contentHashBackfills: [id: "proposed"]
        )
        XCTAssertEqual(rows.first?.contentHash, "recorded")

        var cleared = try XCTUnwrap(rows.first)
        cleared.contentHash = nil
        try await store.upsert(cleared)
        let stale = await store.snapshot()
        try await store.upsert(cleared)  // ABA: an equal write still moves the revision
        let refused = try await store.applyReconciliation(
            expectedRevision: stale.revision,
            appsBySkill: [:],
            contentHashBackfills: [id: "proposed"]
        )
        XCTAssertNil(refused.first?.contentHash, "A stale poll must not write")
    }

    func testAcceptingLocalChangesRecordsTheNewBaseline() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            extraFiles: ["ref.md": "v1"]
        )
        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installLocal(from: staging, name: "alpha")
        try home.write("hand edit", to: home.ssot.appendingPathComponent("alpha/ref.md"))
        let modified = await service.installedSkills()
        XCTAssertEqual(modified.first?.isLocallyModified, true)

        let accepted = try await service.acceptLocalChanges(installed.id)

        let edited = try SkillDirectoryHasher.hash(directory: home.ssot.appendingPathComponent("alpha"))
        XCTAssertEqual(accepted.contentHash, edited)
        XCTAssertNotEqual(accepted.contentHash, installed.contentHash)
        XCTAssertNotNil(accepted.updatedAt)
        XCTAssertFalse(accepted.isLocallyModified)
        let rows = await service.installedSkills()
        XCTAssertEqual(rows.first?.isLocallyModified, false)
        let persisted = await SkillsStore(homeDirectory: home.path).skill(with: installed.id)
        XCTAssertEqual(persisted?.contentHash, edited)
    }

    func testAcceptingRefusesAMissingSkillOrDirectory() async throws {
        let home = try SkillTestHome()
        let service = SkillsService(homeDirectory: home.path)
        do {
            _ = try await service.acceptLocalChanges(.local(directory: "nope"))
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? SkillError, .notInstalled(.local(directory: "nope")))
        }

        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/gone"))
        let installed = try await service.installLocal(from: staging, name: "gone")
        try FileManager.default.removeItem(at: home.ssot.appendingPathComponent("gone"))
        do {
            _ = try await service.acceptLocalChanges(installed.id)
            XCTFail("expected sourceDirectoryMissing")
        } catch {
            XCTAssertEqual(error as? SkillError, .sourceDirectoryMissing("gone"))
        }
        let persisted = await SkillsStore(homeDirectory: home.path).skill(with: installed.id)
        XCTAssertEqual(persisted?.contentHash, installed.contentHash)

        // A vanished directory is not an edit either.
        let rows = await service.installedSkills()
        XCTAssertEqual(rows.first?.isLocallyModified, false)
        XCTAssertNil(rows.first?.localContentHash)
    }

    func testAnUnchangedTreeIsNotRehashedOnTheNextReload() async throws {
        let home = try SkillTestHome()
        let service = SkillsService(homeDirectory: home.path)
        for name in ["alpha", "beta", "gamma"] {
            let staging = try home.makeSkillDirectory(
                at: home.url.appendingPathComponent("Downloads/\(name)"),
                extraFiles: ["ref.md": "v1"]
            )
            _ = try await service.installLocal(from: staging, name: name)
        }

        _ = await service.installedSkills()
        let afterFirst = await service.reloadRehashCount
        XCTAssertEqual(afterFirst, 3, "Each shared copy is read once to establish its hash")

        _ = await service.installedSkills()
        _ = await service.installedSkills()
        let afterIdle = await service.reloadRehashCount
        XCTAssertEqual(afterIdle, afterFirst, "An unchanged stamp reuses the cached hash")

        try home.write("v2", to: home.ssot.appendingPathComponent("beta/ref.md"))
        _ = await service.installedSkills()
        let afterEdit = await service.reloadRehashCount
        XCTAssertEqual(afterEdit, afterFirst + 1, "Only the edited tree is read again")
    }

    func testAcceptSeedsTheCacheSoTheNextReloadDoesNotRehash() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            extraFiles: ["ref.md": "v1"]
        )
        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installLocal(from: staging, name: "alpha")
        try home.write("v2", to: home.ssot.appendingPathComponent("alpha/ref.md"))
        _ = await service.installedSkills()
        _ = try await service.acceptLocalChanges(installed.id)
        let before = await service.reloadRehashCount

        _ = await service.installedSkills()

        let after = await service.reloadRehashCount
        XCTAssertEqual(after, before)
    }

    func testUpdatingFromTheRepositoryClearsTheModifiedBadge() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/one"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["skills/alpha": ["SKILL.md": "---\nname: Alpha\n---\n", "ref.md": "v1"]]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        let discovered = await service.discoverSkills(from: [SkillRepoRef("acme/one")!])
        let installed = try await service.install(discovered[0], enableFor: [])
        await service.clearDiscoveryStaging()

        try home.write("local tweak", to: home.ssot.appendingPathComponent("alpha/ref.md"))
        let modified = await service.installedSkills()
        XCTAssertEqual(modified.first?.isLocallyModified, true)

        fetcher.repos["acme/one"]?.skills["skills/alpha"]?["ref.md"] = "v2"
        _ = try await service.update(installed.id)

        let rows = await service.installedSkills()
        let alpha = try XCTUnwrap(rows.first)
        XCTAssertFalse(alpha.isLocallyModified)
        XCTAssertEqual(alpha.localContentHash, alpha.contentHash)
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("alpha/ref.md")), "v2")
    }

    func testReconciliationKeepsTheLiveHashOnThePollThatPersists() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("Downloads/alpha"),
            extraFiles: ["ref.md": "v1"]
        )
        let service = SkillsService(homeDirectory: home.path)
        _ = try await service.installLocal(from: staging, name: "alpha")
        _ = try await service.setEnabled(.local(directory: "alpha"), app: .claude, enabled: true, method: .symlink)
        try home.write("v2", to: home.ssot.appendingPathComponent("alpha/ref.md"))
        // Removing the link makes this poll persist a reconciliation.
        try FileManager.default.removeItem(at: home.appDirectory(.claude).appendingPathComponent("alpha"))

        let rows = await service.installedSkills()

        let alpha = try XCTUnwrap(rows.first)
        XCTAssertNil(alpha.apps[.claude], "The reconciliation landed")
        XCTAssertTrue(alpha.isLocallyModified, "The badge does not blink off on a persisting poll")
    }

    func testASymlinkedSharedCopyIsNeverHashedOrAccepted() async throws {
        let home = try SkillTestHome()
        let outside = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("elsewhere/alpha"),
            name: "alpha"
        )
        let service = SkillsService(homeDirectory: home.path)
        let skill = try await service.installLocal(from: outside, name: "alpha")
        let shared = home.ssot.appendingPathComponent("alpha")
        try FileManager.default.removeItem(at: shared)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: outside)

        let before = await service.reloadRehashCount
        let listed = await service.installedSkills()
        let after = await service.reloadRehashCount
        XCTAssertEqual(after, before)
        XCTAssertNil(listed.first?.localContentHash)
        XCTAssertEqual(listed.first?.isLocallyModified, false)
        do {
            _ = try await service.acceptLocalChanges(skill.id)
            XCTFail("a link where the shared copy should be must not be accepted")
        } catch {}
    }

    func testAcceptingLocalChangesRecopiesManagedCopies() async throws {
        let home = try SkillTestHome()
        let outside = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("elsewhere/beta"),
            name: "beta"
        )
        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installLocal(from: outside, name: "beta")
        _ = try await service.setEnabled(installed.id, app: .grok, enabled: true, method: .copy)
        let projected = home.appDirectory(.grok).appendingPathComponent("beta")
        try home.write("# edited in the shared copy", to: home.ssot.appendingPathComponent("beta/SKILL.md"))

        let modified = await service.installedSkills().first { $0.id == installed.id }
        XCTAssertEqual(modified?.isLocallyModified, true)
        let accepted = try await service.acceptLocalChanges(installed.id)

        XCTAssertEqual(
            home.contents(of: projected.appendingPathComponent("SKILL.md")),
            "# edited in the shared copy"
        )
        XCTAssertEqual(accepted.apps[.grok]?.contentHashAtCopy, accepted.contentHash)
        let reloaded = await service.installedSkills().first { $0.id == installed.id }
        XCTAssertEqual(reloaded?.isLocallyModified, false)
        XCTAssertEqual(reloaded?.apps[.grok]?.method, .copy)
    }

    func testAcceptingRefusesATreeWithoutSkillMD() async throws {
        let home = try SkillTestHome()
        let outside = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("elsewhere/gamma"),
            name: "gamma"
        )
        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installLocal(from: outside, name: "gamma")
        try FileManager.default.removeItem(at: home.ssot.appendingPathComponent("gamma/SKILL.md"))

        let modified = await service.installedSkills().first { $0.id == installed.id }
        XCTAssertEqual(modified?.isLocallyModified, true)
        do {
            _ = try await service.acceptLocalChanges(installed.id)
            XCTFail("a tree without SKILL.md must not become the baseline")
        } catch {}
        let still = await service.installedSkills().first { $0.id == installed.id }
        XCTAssertEqual(still?.contentHash, installed.contentHash)
        XCTAssertEqual(still?.isLocallyModified, true)
    }

    func testAcceptingFollowsTheDescriptionButRefusesARename() async throws {
        let home = try SkillTestHome()
        let outside = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("elsewhere/delta"),
            name: "delta",
            description: "first"
        )
        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installLocal(from: outside, name: "delta")
        let skillMD = home.ssot.appendingPathComponent("delta/SKILL.md")

        try home.write("---\nname: delta\ndescription: second\n---\n# delta\n", to: skillMD)
        let accepted = try await service.acceptLocalChanges(installed.id)
        XCTAssertEqual(accepted.description, "second")

        for renamed in ["renamed", "Delta"] {
            try home.write("---\nname: \(renamed)\ndescription: third\n---\n# delta\n", to: skillMD)
            do {
                _ = try await service.acceptLocalChanges(installed.id)
                XCTFail("a renamed frontmatter must not be accepted over name-keyed native state")
            } catch {}
        }
        let still = await service.installedSkills().first { $0.id == installed.id }
        XCTAssertEqual(still?.name, "delta")
        XCTAssertEqual(still?.isLocallyModified, true)
    }
}
