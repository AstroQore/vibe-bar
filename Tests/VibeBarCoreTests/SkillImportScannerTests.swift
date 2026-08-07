import XCTest
@testable import VibeBarCore

/// These tests replicate the layout a real machine already has when Vibe Bar
/// first sees it: a populated `~/.agents/skills`, app directories full of
/// symlinks another tool created, and a `.skill-lock.json` Vibe Bar does not
/// own. Import must describe all of it and change none of it.
final class SkillImportScannerTests: XCTestCase {
    private func makeMachineLayout() throws -> SkillTestHome {
        let home = try SkillTestHome()

        try home.makeSSOTSkill("alpha", name: "alpha-skill", description: "Alpha does things")
        try home.makeSSOTSkill("beta")
        try home.makeSSOTSkill("gamma")
        try home.makeSSOTSkill("delta")
        try home.makeSSOTSkill("epsilon")
        try home.makeSSOTSkill("zeta")
        try home.makeSSOTSkill("eta")
        try home.makeSSOTSkill("theta")
        // An SSOT directory with no SKILL.md, and a stray file: neither is a skill.
        try home.makeDirectory(home.ssot.appendingPathComponent("notaskill"))
        try home.write("scratch", to: home.ssot.appendingPathComponent("notaskill/notes.md"))
        try home.write("# not a skill", to: home.ssot.appendingPathComponent("README.md"))

        try home.write(Self.lockFileJSON, to: SkillAppCatalog.lockFileURL(homeDirectory: home.path))

        for name in ["alpha", "beta", "eta"] {
            try home.makeAbsoluteSymlink(name, in: .claude, toSSOT: name)
        }
        try home.makeSymlink("gamma", in: .claude, rawTarget: "../../.agents/skills/gamma")
        try home.makeSymlink("notaskill", in: .claude, rawTarget: home.ssot.appendingPathComponent("notaskill").path)
        try home.makeSymlink("ghost", in: .claude, rawTarget: home.ssot.appendingPathComponent("ghost").path)
        try home.makeSkillDirectory(
            at: home.appDirectory(.claude).appendingPathComponent("legacy-helper"),
            name: "Legacy Helper",
            description: "hand written"
        )

        try home.makeAbsoluteSymlink("alpha", in: .gemini, toSSOT: "alpha")
        try home.makeSkillDirectory(at: home.appDirectory(.gemini).appendingPathComponent("beta"))

        try home.makeAbsoluteSymlink("alpha", in: .antigravity, toSSOT: "alpha")

        try home.makeSkillDirectory(
            at: home.appDirectory(.grok).appendingPathComponent("legacy-helper"),
            name: "Legacy Helper",
            description: "hand written"
        )

        return home
    }

    func testPartitionsTheExistingLayout() throws {
        let home = try makeMachineLayout()
        let report = SkillImportScanner.scan(homeDirectory: home.path)

        XCTAssertEqual(
            report.adopted.map(\.directory),
            ["alpha", "beta", "delta", "epsilon", "eta", "gamma", "theta", "zeta"]
        )
        XCTAssertEqual(report.unrecognized, ["notaskill"])
        XCTAssertEqual(report.conflicts, [SkillImportConflict(directoryName: "beta", app: .gemini)])
        XCTAssertEqual(report.unmanagedDirectories.count, 1)
        let unmanaged = try XCTUnwrap(report.unmanagedDirectories.first)
        XCTAssertEqual(unmanaged.directoryName, "legacy-helper")
        XCTAssertEqual(unmanaged.foundIn, [.claude, .grok])
        XCTAssertEqual(unmanaged.name, "Legacy Helper")
        XCTAssertEqual(unmanaged.description, "hand written")
    }

    func testAdoptionEvidenceComesFromSymlinksOnly() throws {
        let home = try makeMachineLayout()
        let report = SkillImportScanner.scan(homeDirectory: home.path)
        let byDirectory = Dictionary(uniqueKeysWithValues: report.adopted.map { ($0.directory, $0) })

        // Absolute links in three different app dirs, including AntiGravity's
        // ~/.gemini/config/skills, which is distinct from the Gemini CLI's.
        XCTAssertEqual(byDirectory["alpha"]?.enabledApps, [.claude, .gemini, .antigravity])
        XCTAssertEqual(byDirectory["alpha"]?.apps[.claude], SkillMaterialization(method: .symlink, adopted: true))
        XCTAssertEqual(byDirectory["alpha"]?.name, "alpha-skill")
        XCTAssertEqual(byDirectory["alpha"]?.description, "Alpha does things")
        XCTAssertNotNil(byDirectory["alpha"]?.contentHash)

        // A relative link resolves the same way an absolute one does.
        XCTAssertEqual(byDirectory["gamma"]?.enabledApps, [.claude])
        // The Gemini side of beta is a real directory: a conflict, not evidence.
        XCTAssertEqual(byDirectory["beta"]?.enabledApps, [.claude])
        // Never linked anywhere.
        XCTAssertEqual(byDirectory["delta"]?.enabledApps, [])
    }

    func testRecoversProvenanceFromTheLockFile() throws {
        let home = try makeMachineLayout()
        let report = SkillImportScanner.scan(homeDirectory: home.path)
        let byDirectory = Dictionary(uniqueKeysWithValues: report.adopted.map { ($0.directory, $0) })

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(byDirectory["alpha"]?.id, .repo(owner: "acme", repo: "skills", directory: "alpha"))
        XCTAssertNil(byDirectory["alpha"]?.repoBranch)
        XCTAssertEqual(byDirectory["alpha"]?.installedAt, iso.date(from: "2026-04-28T16:51:41.354Z"))
        XCTAssertEqual(byDirectory["alpha"]?.updatedAt, iso.date(from: "2026-08-03T07:30:25.276Z"))

        XCTAssertEqual(byDirectory["beta"]?.repoBranch, "dev")
        XCTAssertEqual(byDirectory["epsilon"]?.repoBranch, "release-2.0")
        XCTAssertEqual(byDirectory["zeta"]?.repoBranch, "feature-x")
        XCTAssertEqual(byDirectory["eta"]?.repoBranch, "explicit-branch")
        XCTAssertEqual(byDirectory["theta"]?.repoBranch, "fallback-branch")

        // Unknown sourceType and absent entries both fall back to local.
        XCTAssertEqual(byDirectory["gamma"]?.id, .local(directory: "gamma"))
        XCTAssertNil(byDirectory["gamma"]?.repoBranch)
        XCTAssertEqual(byDirectory["delta"]?.id, .local(directory: "delta"))
    }

    func testBranchParsingForms() {
        XCTAssertNil(SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills.git"))
        XCTAssertEqual(
            SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills/tree/dev/skills/beta"),
            "dev"
        )
        XCTAssertEqual(
            SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills/tree/main"),
            "main"
        )
        XCTAssertEqual(
            SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills.git#feature-x"),
            "feature-x"
        )
        XCTAssertEqual(
            SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills.git?branch=next"),
            "next"
        )
        XCTAssertEqual(
            SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills.git?ref=release%2F2.0"),
            "release/2.0"
        )
        // A /tree/ segment wins over a query, and the fragment never leaks into it.
        XCTAssertEqual(
            SkillLockFileReader.branch(fromSourceURL: "https://github.com/acme/skills/tree/dev?ref=other#frag"),
            "dev"
        )
    }

    func testScanPerformsNoFilesystemMutations() throws {
        let home = try makeMachineLayout()
        let before = home.lstatSnapshot()

        _ = SkillImportScanner.scan(homeDirectory: home.path)

        let after = home.lstatSnapshot()
        XCTAssertEqual(Set(before.keys), Set(after.keys))
        XCTAssertEqual(before, after)
        // Nothing was conjured up for the apps that have no skills dir yet.
        XCTAssertFalse(home.exists(home.appDirectory(.codex)))
        XCTAssertFalse(home.exists(home.appDirectory(.hermes)))
        XCTAssertFalse(home.exists(home.appDirectory(.opencode)))
        XCTAssertFalse(home.exists(VibeBarLocalStore.baseDirectory(homeDirectory: home.path)))
        // The dangling link is left dangling — not repaired, not deleted.
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("ghost")),
            .symlink
        )
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("ghost")))
    }

    func testRescanIsIdempotent() throws {
        let home = try makeMachineLayout()
        XCTAssertEqual(
            SkillImportScanner.scan(homeDirectory: home.path),
            SkillImportScanner.scan(homeDirectory: home.path)
        )
    }

    func testEmptyHomeScansCleanly() throws {
        let home = try SkillTestHome()
        let report = SkillImportScanner.scan(homeDirectory: home.path)
        XCTAssertTrue(report.isEmpty)
        XCTAssertFalse(home.exists(home.ssot))
    }

    private static let lockFileJSON = """
    {
      "version": 3,
      "skills": {
        "alpha": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills.git",
          "skillPath": "skills/alpha/SKILL.md",
          "skillFolderHash": "0000000000000000000000000000000000000000",
          "installedAt": "2026-04-28T16:51:41.354Z",
          "updatedAt": "2026-08-03T07:30:25.276Z"
        },
        "beta": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills/tree/dev/skills/beta",
          "skillPath": "skills/beta/SKILL.md"
        },
        "gamma": {
          "source": "acme/skills",
          "sourceType": "gitlab",
          "sourceUrl": "https://gitlab.example.com/acme/skills.git"
        },
        "epsilon": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills.git?ref=release-2.0"
        },
        "zeta": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills.git#feature-x"
        },
        "eta": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills/tree/other/skills/eta",
          "branch": "explicit-branch"
        },
        "theta": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills.git",
          "sourceBranch": "fallback-branch"
        },
        "removed-skill": {
          "source": "acme/skills",
          "sourceType": "github",
          "sourceUrl": "https://github.com/acme/skills.git"
        },
        "malformed": 42
      },
      "dismissed": {}
    }
    """
}
