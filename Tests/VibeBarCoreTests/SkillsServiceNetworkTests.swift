import XCTest
@testable import VibeBarCore

/// The repository half of `SkillsService`, driven through the `SkillRepoFetching`
/// seam so nothing here needs a network — the fake writes the tree a download
/// would have produced and then defers to the *real* scanner, so discovery,
/// matching, and hashing are the production code paths.
final class SkillsServiceNetworkTests: XCTestCase {
    // MARK: - Install

    func testInstallsADiscoveredSkillAndEnablesTheChosenApps() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("staging/pdf"),
            name: "PDF Tools",
            description: "Reads PDFs",
            extraFiles: ["reference/notes.md": "deep"]
        )
        let service = SkillsService(homeDirectory: home.path)

        let skill = try await service.install(
            Self.discovered(directory: "pdf", sourceRoot: staging, name: "PDF Tools", description: "Reads PDFs"),
            enableFor: [.claude, .codex]
        )

        XCTAssertEqual(skill.id, .repo(owner: "acme", repo: "myskills", directory: "pdf"))
        XCTAssertEqual(skill.name, "PDF Tools")
        XCTAssertEqual(skill.description, "Reads PDFs")
        XCTAssertEqual(skill.repoBranch, "master")
        XCTAssertEqual(Set(skill.enabledApps), [.claude, .codex])
        XCTAssertEqual(
            home.contents(of: home.ssot.appendingPathComponent("pdf/reference/notes.md")),
            "deep"
        )
        XCTAssertEqual(
            skill.contentHash,
            try SkillDirectoryHasher.hash(directory: home.ssot.appendingPathComponent("pdf"))
        )
        for app in [SkillAppTarget.claude, .codex] {
            XCTAssertEqual(
                SkillFileSystem.kind(of: home.appDirectory(app).appendingPathComponent("pdf")),
                .symlink
            )
        }
        let installed = await service.installedSkills()
        XCTAssertEqual(installed.map(\.directory), ["pdf"])
    }

    func testInstallRefusesADirectoryHeldByADifferentSkill() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/pdf"))
        let service = SkillsService(homeDirectory: home.path)
        _ = try await service.installLocal(from: staging, name: "pdf")

        do {
            _ = try await service.install(
                Self.discovered(directory: "pdf", sourceRoot: staging),
                enableFor: [.claude]
            )
            XCTFail("Expected directoryConflict")
        } catch {
            XCTAssertEqual(error as? SkillError, .directoryConflict("pdf"))
        }
        let installed = await service.installedSkills()
        XCTAssertEqual(installed.map(\.id), [.local(directory: "pdf")])
    }

    func testReinstallingTheSameSkillOnlyEnablesMoreApps() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/pdf"))
        let service = SkillsService(homeDirectory: home.path)
        let discovered = Self.discovered(directory: "pdf", sourceRoot: staging)
        _ = try await service.install(discovered, enableFor: [.claude])
        // Local edits to the SSOT copy must survive a repeat install.
        try home.write("edited", to: home.ssot.appendingPathComponent("pdf/local.md"))

        let again = try await service.install(discovered, enableFor: [.gemini])

        XCTAssertEqual(Set(again.enabledApps), [.claude, .gemini])
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("pdf/local.md")), "edited")
    }

    func testInstallRejectsASourceWithoutSkillMD() async throws {
        let home = try SkillTestHome()
        let empty = try home.makeDirectory(home.url.appendingPathComponent("staging/blank"))
        let service = SkillsService(homeDirectory: home.path)

        do {
            _ = try await service.install(
                Self.discovered(directory: "blank", sourceRoot: empty),
                enableFor: []
            )
            XCTFail("Expected missingSkillMD")
        } catch {
            XCTAssertEqual(error as? SkillError, .missingSkillMD("blank"))
        }
    }

    // MARK: - Zip import

    func testInstallsEverySkillInAZipAndSkipsDuplicates() async throws {
        let home = try SkillTestHome()
        let bundle = home.url.appendingPathComponent("bundle", isDirectory: true)
        try home.makeSkillDirectory(at: bundle.appendingPathComponent("alpha"), name: "Alpha")
        try home.makeSkillDirectory(
            at: bundle.appendingPathComponent("nested/beta"),
            name: "Beta",
            extraFiles: ["ref.md": "beta reference"]
        )
        let archive = try SkillZipFixtures.zipDirectory(named: "bundle", in: home.url)

        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installFromZip(at: archive, enableFor: [.claude])

        XCTAssertEqual(installed.map(\.directory).sorted(), ["alpha", "beta"])
        XCTAssertEqual(installed.map(\.id).sorted { $0.rawValue < $1.rawValue }, [
            .local(directory: "alpha"),
            .local(directory: "beta")
        ])
        XCTAssertEqual(installed.first { $0.directory == "beta" }?.name, "Beta")
        XCTAssertEqual(
            home.contents(of: home.ssot.appendingPathComponent("beta/ref.md")),
            "beta reference"
        )
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("alpha")),
            .symlink
        )

        // Second pass: both are already installed, so nothing new lands and the
        // existing SSOT copies are untouched.
        let again = try await service.installFromZip(at: archive, enableFor: [.claude])
        XCTAssertTrue(again.isEmpty)
        let all = await service.installedSkills()
        XCTAssertEqual(all.map(\.directory), ["alpha", "beta"])
    }

    func testInstallFromZipRejectsAnArchiveWithoutASkill() async throws {
        let home = try SkillTestHome()
        let junk = home.url.appendingPathComponent("junk", isDirectory: true)
        try home.write("nothing to see", to: junk.appendingPathComponent("notes.txt"))
        let archive = try SkillZipFixtures.zipDirectory(named: "junk", in: home.url)

        let service = SkillsService(homeDirectory: home.path)
        do {
            _ = try await service.installFromZip(at: archive, enableFor: [])
            XCTFail("Expected missingSkillMD")
        } catch {
            XCTAssertEqual(error as? SkillError, .missingSkillMD("junk"))
        }
    }

    func testInstallFromZipAcceptsAnArchiveOfASingleSkillFolder() async throws {
        let home = try SkillTestHome()
        try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("solo"),
            name: "Solo Skill"
        )
        let archive = try SkillZipFixtures.zipDirectory(named: "solo", in: home.url)

        let service = SkillsService(homeDirectory: home.path)
        let installed = try await service.installFromZip(at: archive, enableFor: [])

        XCTAssertEqual(installed.map(\.directory), ["solo"])
        XCTAssertEqual(installed[0].name, "Solo Skill")
    }

    // MARK: - Discovery

    func testDiscoverySkipsARepositoryThatFailsAndKeepsTheRest() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/good"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["skills/alpha": ["SKILL.md": Self.frontmatter(name: "Alpha")]]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)

        let discovered = await service.discoverSkills(from: [
            SkillRepoRef("acme/good")!,
            SkillRepoRef("acme/missing")!
        ])

        XCTAssertEqual(discovered.map(\.directory), ["alpha"])
        XCTAssertEqual(discovered[0].id, .repo(owner: "acme", repo: "good", directory: "alpha"))
        // The staging tree is still on disk, which is what makes install work.
        let installed = try await service.install(discovered[0], enableFor: [.claude])
        XCTAssertEqual(installed.directory, "alpha")

        await service.clearDiscoveryStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: discovered[0].sourceRoot.path))
    }

    /// The bug this exists for: a repository that never answers used to leave
    /// the sheet spinning with nothing to say and no way out.
    func testDiscoveryReportsWhichRepositoryFailedInsteadOfReturningNothing() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/good"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["skills/alpha": ["SKILL.md": Self.frontmatter(name: "Alpha")]]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)

        let result = await service.discover(from: [
            SkillRepoRef("acme/good")!,
            SkillRepoRef("acme/missing")!
        ])

        XCTAssertEqual(result.skills.map(\.directory), ["alpha"])
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.failures.map(\.slug), ["acme/missing"])
        XCTAssertFalse(result.failures[0].wasCancelled)
        XCTAssertTrue(
            result.failures[0].displayText.hasPrefix("acme/missing: Could not download acme/missing"),
            result.failures[0].displayText
        )
    }

    func testDiscoveryReportsPhasesForEveryRepository() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/one"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["skills/alpha": ["SKILL.md": Self.frontmatter(name: "Alpha")]]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        let recorder = PhaseRecorder()

        _ = await service.discover(from: [SkillRepoRef("acme/one")!]) { recorder.record($0) }

        XCTAssertEqual(recorder.phases, [
            .downloading(slug: "acme/one"),
            .scanning(slug: "acme/one"),
            .repositoryFinished(slug: "acme/one", completed: 1, total: 1)
        ])
    }

    /// Cancelling has to resolve the call — the point of the Cancel button is
    /// that the caller stops waiting, not that the download is asked nicely.
    func testDiscoveryCancellationResolvesWithACancelledFailure() async throws {
        let home = try SkillTestHome()
        let fetcher = HangingRepoFetcher()
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)

        let discovery = Task { await service.discover(from: [SkillRepoRef("acme/slow")!]) }
        try await fetcher.waitUntilStarted()
        discovery.cancel()

        let result = await discovery.value
        XCTAssertTrue(result.skills.isEmpty)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.failures.map(\.displayText), ["acme/slow: cancelled"])
        XCTAssertTrue(result.failures[0].wasCancelled)
    }

    func testDiscoveryDedupesAndSortsByName() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/one"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: [
                "skills/zeta": ["SKILL.md": Self.frontmatter(name: "Zeta")],
                "skills/alpha": ["SKILL.md": Self.frontmatter(name: "Alpha")]
            ]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)

        let discovered = await service.discoverSkills(from: [
            SkillRepoRef("acme/one")!,
            SkillRepoRef("acme/one")!
        ])

        XCTAssertEqual(discovered.map(\.name), ["Alpha", "Zeta"])
    }

    // MARK: - Update checks

    func testCheckForUpdatesComparesHashesAndBackfillsAMissingLocalOne() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/one"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: [
                "skills/alpha": ["SKILL.md": Self.frontmatter(name: "Alpha"), "ref.md": "v1"],
                "skills/beta": ["SKILL.md": Self.frontmatter(name: "Beta")]
            ]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        let discovered = await service.discoverSkills(from: [SkillRepoRef("acme/one")!])
        for skill in discovered { _ = try await service.install(skill, enableFor: []) }
        await service.clearDiscoveryStaging()

        // Alpha moves on upstream; beta does not. Beta also loses its recorded
        // hash, standing in for a skill adopted by an older build.
        fetcher.repos["acme/one"]?.skills["skills/alpha"]?["ref.md"] = "v2"
        let store = SkillsStore(homeDirectory: home.path)
        let stored = await store.skill(directory: "beta")
        var beta = try XCTUnwrap(stored)
        beta.contentHash = nil
        try await store.upsert(beta)

        let states = await service.checkForUpdates()

        XCTAssertEqual(states.map(\.name), ["Alpha", "Beta"])
        let alpha = try XCTUnwrap(states.first { $0.name == "Alpha" })
        XCTAssertTrue(alpha.updateAvailable)
        XCTAssertNotEqual(alpha.localHash, alpha.remoteHash)
        let betaState = try XCTUnwrap(states.first { $0.name == "Beta" })
        XCTAssertFalse(betaState.updateAvailable)
        XCTAssertEqual(betaState.localHash, betaState.remoteHash)
        XCTAssertNotNil(betaState.localHash)
        XCTAssertEqual(fetcher.downloadCount, 2, "One download for discovery, one for the check")
    }

    func testCheckForUpdatesIgnoresLocalSkillsAndUnreachableRepositories() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/solo"))
        let fetcher = FakeRepoFetcher()
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        _ = try await service.installLocal(from: staging, name: "solo")
        _ = try await service.install(
            Self.discovered(directory: "ghost", sourceRoot: staging),
            enableFor: []
        )

        let states = await service.checkForUpdates()

        XCTAssertEqual(states.map(\.name), ["ghost"], "Local skills are not update candidates")
        XCTAssertNil(states[0].remoteHash)
        XCTAssertFalse(states[0].updateAvailable)
    }

    // MARK: - Update

    func testUpdateBacksUpReplacesAndRematerializes() async throws {
        let home = try SkillTestHome()
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/one"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["skills/alpha": [
                "SKILL.md": Self.frontmatter(name: "Alpha"),
                "ref.md": "v1",
                "gone.md": "removed upstream later"
            ]]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        let discovered = await service.discoverSkills(from: [SkillRepoRef("acme/one")!])
        let installed = try await service.install(discovered[0], enableFor: [.claude], method: .copy)
        await service.clearDiscoveryStaging()
        XCTAssertEqual(installed.apps[.claude]?.method, .copy)

        fetcher.repos["acme/one"]?.skills["skills/alpha"] = [
            "SKILL.md": Self.frontmatter(name: "Alpha 2", description: "now with more"),
            "ref.md": "v2"
        ]

        let updated = try await service.update(installed.id)

        XCTAssertEqual(updated.name, "Alpha 2")
        XCTAssertEqual(updated.description, "now with more")
        XCTAssertNotNil(updated.updatedAt)
        XCTAssertNotEqual(updated.contentHash, installed.contentHash)
        XCTAssertEqual(home.contents(of: home.ssot.appendingPathComponent("alpha/ref.md")), "v2")
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("alpha/gone.md")))

        // The app-side managed copy is refreshed, not left on the old content.
        let appCopy = home.appDirectory(.claude).appendingPathComponent("alpha")
        XCTAssertEqual(SkillFileSystem.kind(of: appCopy), .directory)
        XCTAssertEqual(home.contents(of: appCopy.appendingPathComponent("ref.md")), "v2")
        XCTAssertEqual(
            updated.apps[.claude]?.contentHashAtCopy,
            try SkillDirectoryHasher.hash(directory: appCopy)
        )

        // The pre-update content is recoverable.
        let backups = service.listBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            home.contents(of: backups[0].url.appendingPathComponent("skill/ref.md")),
            "v1"
        )
    }

    func testUpdateRefusesALocalSkillAndAVanishedOne() async throws {
        let home = try SkillTestHome()
        let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("staging/solo"))
        let fetcher = FakeRepoFetcher()
        fetcher.repos["acme/one"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["skills/other": ["SKILL.md": Self.frontmatter(name: "Other")]]
        )
        let service = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        _ = try await service.installLocal(from: staging, name: "solo")
        let ghost = try await service.install(
            Self.discovered(
                directory: "ghost",
                sourceRoot: staging,
                owner: "acme",
                repo: "one",
                branch: "main"
            ),
            enableFor: []
        )

        do {
            _ = try await service.update(.local(directory: "solo"))
            XCTFail("Expected notRepositoryBacked")
        } catch {
            XCTAssertEqual(error as? SkillError, .notRepositoryBacked(.local(directory: "solo")))
        }
        do {
            _ = try await service.update(ghost.id)
            XCTFail("Expected updateSourceMissing")
        } catch {
            XCTAssertEqual(error as? SkillError, .updateSourceMissing("ghost"))
        }
        XCTAssertTrue(service.listBackups().isEmpty, "A failed update takes no backup")
        do {
            _ = try await service.update(.repo(owner: "acme", repo: "one", directory: "nope"))
            XCTFail("Expected notInstalled")
        } catch {
            XCTAssertEqual(error as? SkillError, .notInstalled(.repo(owner: "acme", repo: "one", directory: "nope")))
        }
    }

    // MARK: - Helpers

    private static func discovered(
        directory: String,
        sourceRoot: URL,
        name: String? = nil,
        description: String? = nil,
        owner: String = "acme",
        repo: String = "myskills",
        branch: String = "master"
    ) -> DiscoveredSkill {
        DiscoveredSkill(
            id: .repo(owner: owner, repo: repo, directory: directory),
            name: name ?? directory,
            description: description,
            directory: directory,
            repoRelativePath: "skills/\(directory)",
            branch: branch,
            readmeURL: nil,
            sourceRoot: sourceRoot
        )
    }

    private static func frontmatter(name: String, description: String? = nil) -> String {
        var text = "---\nname: \(name)\n"
        if let description { text += "description: \(description)\n" }
        text += "---\n\n# \(name)\n"
        return text
    }
}

/// Stands in for `SkillRepoFetcher`: materializes a declared tree into the
/// directory the service hands it, then defers to the real scanner so only the
/// network is faked.
final class FakeRepoFetcher: SkillRepoFetching, @unchecked Sendable {
    struct Repo {
        var branch: String
        /// Repository-relative skill directory → file name → contents.
        var skills: [String: [String: String]]
    }

    private let lock = NSLock()
    private var storage: [String: Repo] = [:]
    private var downloads = 0

    var repos: [String: Repo] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var downloadCount: Int { lock.withLock { downloads } }

    func downloadRepo(_ ref: SkillRepoRef, into tempDir: URL) async throws -> (root: URL, resolvedBranch: String) {
        guard let repo = repos[ref.slug] else {
            throw SkillRepoError.branchNotFound(
                slug: ref.slug,
                tried: SkillRepoFetcher.branchCandidates(for: ref)
            )
        }
        lock.withLock { downloads += 1 }
        let root = tempDir.appendingPathComponent("\(ref.repo)-\(repo.branch)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, files) in repo.skills {
            let directory = path
                .split(separator: "/")
                .reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in files {
                try contents.write(
                    to: directory.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        return (root, repo.branch)
    }

    func scanSkills(
        inRepoRoot root: URL,
        ref: SkillRepoRef,
        resolvedBranch: String
    ) throws -> [DiscoveredSkill] {
        try SkillRepoFetcher().scanSkills(inRepoRoot: root, ref: ref, resolvedBranch: resolvedBranch)
    }
}

/// A fetcher whose download never lands, standing in for the slow network the
/// Cancel button exists for. `Task.sleep` is the cooperative check: it throws
/// `CancellationError` the moment the surrounding task is cancelled.
final class HangingRepoFetcher: SkillRepoFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func downloadRepo(_ ref: SkillRepoRef, into tempDir: URL) async throws -> (root: URL, resolvedBranch: String) {
        lock.withLock { started = true }
        try await Task.sleep(for: .seconds(600))
        throw SkillRepoError.branchNotFound(slug: ref.slug, tried: ["main"])
    }

    func scanSkills(
        inRepoRoot root: URL,
        ref: SkillRepoRef,
        resolvedBranch: String
    ) throws -> [DiscoveredSkill] {
        []
    }

    func waitUntilStarted(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ started }) {
            guard Date() < deadline else { throw MCPTestError("The download never started") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Collects discovery phases from whatever thread emits them.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SkillDiscoveryPhase] = []

    var phases: [SkillDiscoveryPhase] { lock.withLock { recorded } }

    func record(_ phase: SkillDiscoveryPhase) {
        lock.withLock { recorded.append(phase) }
    }
}
