import XCTest
@testable import VibeBarCore

final class SkillsStoreTests: XCTestCase {
    private func makeSkill(
        _ id: SkillID,
        apps: [SkillAppTarget: SkillMaterialization] = [:]
    ) -> Skill {
        Skill(
            id: id,
            name: id.directory,
            description: "a synthetic skill",
            directory: id.directory,
            repoBranch: id.isRepositoryBacked ? "main" : nil,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentHash: "deadbeef",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            apps: apps
        )
    }

    func testRoundTripsThroughDisk() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)
        let alpha = makeSkill(
            .repo(owner: "acme", repo: "skills", directory: "alpha"),
            apps: [
                .claude: SkillMaterialization(method: .symlink, adopted: true),
                .grok: SkillMaterialization(method: .copy, contentHashAtCopy: "abc123")
            ]
        )
        let beta = makeSkill(.local(directory: "beta"))
        try await store.upsert(alpha)
        try await store.upsert(beta)

        let reloaded = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(reloaded.map(\.directory), ["alpha", "beta"])
        XCTAssertEqual(reloaded.first, alpha)
        XCTAssertEqual(reloaded.first?.apps[.claude]?.adopted, true)
        XCTAssertEqual(reloaded.first?.apps[.grok]?.contentHashAtCopy, "abc123")
        XCTAssertEqual(reloaded.last?.id, .local(directory: "beta"))
    }

    func testFileIsWrittenPrivatelyUnderVibeBar() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)
        try await store.upsert(makeSkill(.local(directory: "alpha")))

        let url = VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path)
        XCTAssertEqual(url.path, home.url.appendingPathComponent(".vibebar/skills.json").path)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testUpsertReplacesAndRemoveDeletes() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)
        let id = SkillID.local(directory: "alpha")
        try await store.upsert(makeSkill(id))

        var updated = makeSkill(id)
        updated.name = "renamed"
        try await store.upsert(updated)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "renamed")
        let found = await store.skill(with: id)
        XCTAssertEqual(found?.name, "renamed")
        let missing = await store.skill(with: .local(directory: "nope"))
        XCTAssertNil(missing)

        let firstRemoval = try await store.remove(id: id)
        XCTAssertTrue(firstRemoval)
        let secondRemoval = try await store.remove(id: id)
        XCTAssertFalse(secondRemoval)
        let empty = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertTrue(empty.isEmpty)
    }

    func testUnknownAppKeysAndUndecodableEntriesAreDropped() async throws {
        let home = try SkillTestHome()
        let json = """
        {
          "schemaVersion": 1,
          "skills": [
            {
              "id": "acme/skills:alpha",
              "name": "alpha",
              "directory": "alpha",
              "installedAt": 0,
              "apps": {
                "claude": { "method": "symlink", "adopted": true },
                "borgcli": { "method": "symlink", "adopted": true }
              }
            },
            { "id": "not a valid id", "name": "broken", "directory": "broken", "installedAt": 0 },
            { "id": "local:beta", "name": "beta", "directory": "beta", "installedAt": 0, "apps": {} }
          ]
        }
        """
        try home.write(json, to: VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path))

        let skills = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(skills.map(\.directory), ["alpha", "beta"])
        XCTAssertEqual(skills.first?.projectedApps, [.claude])
        XCTAssertEqual(skills.first?.id, .repo(owner: "acme", repo: "skills", directory: "alpha"))
    }

    func testMissingOrCorruptFileLoadsEmpty() async throws {
        let home = try SkillTestHome()
        let empty = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertTrue(empty.isEmpty)

        try home.write("{ not json", to: VibeBarLocalStore.skillsStoreURL(homeDirectory: home.path))
        let corrupt = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertTrue(corrupt.isEmpty)
    }

    func testDiscoverReposSeedTheDefaultsAndRoundTrip() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)

        // Never configured → the shipped seed list.
        let seeded = await store.discoverRepos()
        XCTAssertEqual(seeded, SkillsStore.defaultDiscoverRepos)
        let refs = await store.discoverRepoRefs()
        XCTAssertEqual(refs.map(\.slug).first, "anthropics/skills")
        XCTAssertEqual(refs.first { $0.repo == "myclaude" }?.branch, "master")

        // Writing a skill must persist the list alongside it.
        try await store.upsert(makeSkill(.local(directory: "alpha")))
        let reloaded = await SkillsStore(homeDirectory: home.path).discoverRepos()
        XCTAssertEqual(reloaded, SkillsStore.defaultDiscoverRepos)

        let added = try await store.addDiscoverRepo("acme/extra@dev")
        XCTAssertTrue(added)
        let addedAgain = try await store.addDiscoverRepo("ACME/EXTRA@dev")
        XCTAssertFalse(addedAgain, "Duplicates are case-insensitive")
        let addedJunk = try await store.addDiscoverRepo("not a repo")
        XCTAssertFalse(addedJunk)
        let removed = try await store.removeDiscoverRepo("anthropics/skills")
        XCTAssertTrue(removed)
        let removedAgain = try await store.removeDiscoverRepo("anthropics/skills")
        XCTAssertFalse(removedAgain)

        let afterEdits = await SkillsStore(homeDirectory: home.path).discoverRepos()
        XCTAssertFalse(afterEdits.contains("anthropics/skills"))
        XCTAssertTrue(afterEdits.contains("acme/extra@dev"))
        let survivors = await SkillsStore(homeDirectory: home.path).all()
        XCTAssertEqual(survivors.map(\.directory), ["alpha"])
    }

    func testSetDiscoverReposNormalizesAndAnEmptyListStaysEmpty() async throws {
        let home = try SkillTestHome()
        let store = SkillsStore(homeDirectory: home.path)

        try await store.setDiscoverRepos(["  acme/one  ", "acme/one", "junk", "acme/two@dev", "a/b/c"])
        let normalized = await store.discoverRepos()
        XCTAssertEqual(normalized, ["acme/one", "acme/two@dev"])

        // An explicitly cleared list is a decision, not an absent key: it must
        // not re-seed on the next load.
        try await store.setDiscoverRepos([])
        let cleared = await SkillsStore(homeDirectory: home.path).discoverRepos()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testSkillIDSerializationRoundTrip() {
        XCTAssertEqual(
            SkillID(rawValue: "acme/skills:alpha"),
            .repo(owner: "acme", repo: "skills", directory: "alpha")
        )
        XCTAssertEqual(SkillID(rawValue: "local:alpha"), .local(directory: "alpha"))
        XCTAssertEqual(SkillID.local(directory: "alpha").rawValue, "local:alpha")
        XCTAssertEqual(
            SkillID.repo(owner: "acme", repo: "skills", directory: "alpha").rawValue,
            "acme/skills:alpha"
        )
        XCTAssertEqual(SkillID.repo(owner: "acme", repo: "skills", directory: "alpha").repositorySlug, "acme/skills")
        XCTAssertNil(SkillID.local(directory: "alpha").repositorySlug)
        XCTAssertNil(SkillID(rawValue: "alpha"))
        XCTAssertNil(SkillID(rawValue: "acme/skills:"))
        XCTAssertNil(SkillID(rawValue: "acme:alpha"))
    }
}
