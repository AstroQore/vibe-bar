import XCTest
@testable import VibeBarCore

/// `skills.install` end to end: the source string an agent types, the real
/// `SkillsService` install path behind it, and a disposable home directory in
/// place of the user's. Nothing here touches the machine's `~/.agents`.
final class MCPSkillInstallTests: XCTestCase {
    private var home: SkillTestHome!
    private var fetcher: FakeRepoFetcher!
    private var source: FakeMCPDataSource!
    private var server: MCPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = try SkillTestHome()
        fetcher = FakeRepoFetcher()
        fetcher.repos["AstroQore/vibe-bar"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: ["docs/agent-setup/skill/vibe-bar": [
                "SKILL.md": "---\nname: vibe-bar\ndescription: Reads Vibe Bar\n---\n\n# vibe-bar\n"
            ]]
        )
        fetcher.repos["acme/many"] = FakeRepoFetcher.Repo(
            branch: "main",
            skills: [
                "skills/alpha": ["SKILL.md": "---\nname: Alpha\n---\n"],
                "skills/beta": ["SKILL.md": "---\nname: Beta\n---\n"]
            ]
        )
        source = FakeMCPDataSource()
        source.skillsService = SkillsService(homeDirectory: home.path, fetcher: fetcher)
        server = MCPServer(dataSource: source, now: { FakeMCPDataSource.epoch })
    }

    override func tearDown() {
        home = nil
        super.tearDown()
    }

    // MARK: - Happy paths

    func testInstallsARepositorySkillAndProjectsItIntoTheNamedApps() async throws {
        let result = try await call([
            "source": .string("AstroQore/vibe-bar"),
            "apps": .array([.string("claude"), .string("codex")])
        ])

        let installed = try XCTUnwrap(result["installed"]?.arrayValue)
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed[0]["id"]?.stringValue, "AstroQore/vibe-bar:vibe-bar")
        XCTAssertEqual(installed[0]["name"]?.stringValue, "vibe-bar")
        XCTAssertEqual(installed[0]["description"]?.stringValue, "Reads Vibe Bar")
        XCTAssertEqual(installed[0]["directory"]?.stringValue, "vibe-bar")
        XCTAssertEqual(installed[0]["branch"]?.stringValue, "main")
        XCTAssertEqual(
            installed[0]["path"]?.stringValue,
            home.ssot.appendingPathComponent("vibe-bar").path
        )

        let projected = try XCTUnwrap(installed[0]["projectedTo"]?.objectValue)
        XCTAssertEqual(Set(projected.keys), ["claude", "codex"])
        XCTAssertEqual(
            projected["claude"]?.stringValue,
            home.appDirectory(.claude).appendingPathComponent("vibe-bar").path
        )
        XCTAssertTrue(result["message"]?.stringValue?.contains("Claude Code, Codex") ?? false)

        // The payload really landed, and the app entry is a link into it.
        XCTAssertTrue(home.exists(home.ssot.appendingPathComponent("vibe-bar/SKILL.md")))
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.claude).appendingPathComponent("vibe-bar")),
            .symlink
        )
        XCTAssertEqual(source.lastSkillApps, [.claude, .codex])
        XCTAssertEqual(source.lastSkillMethod, .auto)
    }

    func testInstallingWithoutAppsSaysNobodyHasItYet() async throws {
        let result = try await call(["source": .string("AstroQore/vibe-bar@main")])

        let installed = try XCTUnwrap(result["installed"]?.arrayValue)
        XCTAssertEqual(installed[0]["projectedTo"]?.objectValue?.isEmpty, true)
        XCTAssertTrue(
            result["message"]?.stringValue?.contains("No agent has it switched on yet") ?? false,
            result["message"]?.stringValue ?? ""
        )
        for app in SkillAppTarget.allCases {
            XCTAssertFalse(home.exists(home.appDirectory(app).appendingPathComponent("vibe-bar")))
        }
    }

    /// A GitHub URL is folded back into owner/repo rather than downloaded as
    /// an arbitrary file, so the archive path stays the only network shape.
    func testAcceptsAGitHubURLAndAFragment() async throws {
        let result = try await call([
            "source": .string("https://github.com/acme/many/tree/main#beta")
        ])
        XCTAssertEqual(result["installed"]?.arrayValue?.first?["name"]?.stringValue, "Beta")
        XCTAssertEqual(
            source.lastSkillSource,
            .repository(ref: SkillRepoRef("acme/many@main")!, skillDirectory: "beta")
        )
    }

    func testInstallsALocalDirectory() async throws {
        let local = try home.makeSkillDirectory(
            at: home.url.appendingPathComponent("elsewhere/notes"),
            name: "Notes"
        )
        let result = try await call([
            "source": .string(local.path),
            "apps": .array([.string("grok")]),
            "method": .string("copy")
        ])

        let installed = try XCTUnwrap(result["installed"]?.arrayValue)
        XCTAssertEqual(installed[0]["id"]?.stringValue, "local:notes")
        XCTAssertEqual(installed[0]["name"]?.stringValue, "Notes")
        XCTAssertEqual(source.lastSkillMethod, .copy)
        XCTAssertEqual(
            SkillFileSystem.kind(of: home.appDirectory(.grok).appendingPathComponent("notes")),
            .directory
        )
    }

    // MARK: - Refusals

    func testRefusesAHostOutsideTheAllowList() async throws {
        let response = try await raw(["source": .string("https://evil.example.com/skills.zip")])
        let message = try XCTUnwrap(response["error"]?["message"]?.stringValue)
        XCTAssertTrue(message.contains("evil.example.com"), message)
        XCTAssertNil(source.lastSkillSource, "A bad host must not reach the Skills manager")
    }

    func testRefusesARelativeLocalPath() async throws {
        let response = try await raw(["source": .string("./skills/vibe-bar")])
        XCTAssertTrue(
            (response["error"]?["message"]?.stringValue ?? "").contains("relative"),
            response["error"]?["message"]?.stringValue ?? ""
        )
        XCTAssertNil(source.lastSkillSource)
    }

    func testRefusesALocalPathThatIsNotADirectory() async throws {
        let file = home.url.appendingPathComponent("loose/SKILL.md")
        try home.write("---\nname: Loose\n---\n", to: file)

        let response = try await raw(["source": .string(file.path)])
        XCTAssertTrue(MCPTestSupport.isError(response))
        XCTAssertTrue(
            (MCPTestSupport.errorText(response) ?? "").contains("is not a directory"),
            MCPTestSupport.errorText(response) ?? ""
        )
    }

    func testRefusesADirectoryWithoutSkillMD() async throws {
        let empty = try home.makeDirectory(home.url.appendingPathComponent("elsewhere/blank"))

        let response = try await raw(["source": .string(empty.path)])
        XCTAssertTrue(MCPTestSupport.isError(response))
        XCTAssertTrue(
            (MCPTestSupport.errorText(response) ?? "").contains("no SKILL.md"),
            MCPTestSupport.errorText(response) ?? ""
        )
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("blank")))
    }

    /// A collection repository is not installed wholesale on a guess; the
    /// error is the menu.
    func testAsksWhichSkillWhenTheRepositoryHasSeveral() async throws {
        let response = try await raw(["source": .string("acme/many")])
        let text = try XCTUnwrap(MCPTestSupport.errorText(response))
        XCTAssertTrue(MCPTestSupport.isError(response))
        XCTAssertTrue(text.contains("alpha"), text)
        XCTAssertTrue(text.contains("beta"), text)
        let installed = await source.skillsService?.installedSkills() ?? []
        XCTAssertTrue(installed.isEmpty)
    }

    func testNamesTheAvailableSkillsWhenTheFragmentIsWrong() async throws {
        let response = try await raw(["source": .string("acme/many#gamma")])
        let text = try XCTUnwrap(MCPTestSupport.errorText(response))
        XCTAssertTrue(text.contains("gamma"), text)
        XCTAssertTrue(text.contains("alpha, beta"), text)
    }

    func testReportsThatInstallingIsSwitchedOff() async throws {
        source.allowSkillInstall = false

        let response = try await raw(["source": .string("AstroQore/vibe-bar")])
        XCTAssertTrue(MCPTestSupport.isError(response))
        XCTAssertTrue(
            (MCPTestSupport.errorText(response) ?? "").contains("switched off"),
            MCPTestSupport.errorText(response) ?? ""
        )
        XCTAssertFalse(home.exists(home.ssot.appendingPathComponent("vibe-bar")))
    }

    func testRejectsAnInventedArgument() async throws {
        let response = try await raw([
            "source": .string("AstroQore/vibe-bar"),
            "force": .bool(true)
        ])
        XCTAssertNotNil(response["error"])
        XCTAssertNil(source.lastSkillSource)
    }

    func testRejectsAutoAsAnExplicitMethod() async throws {
        let response = try await raw([
            "source": .string("AstroQore/vibe-bar"),
            "method": .string("auto")
        ])
        XCTAssertTrue(
            (response["error"]?["message"]?.stringValue ?? "").contains("'symlink' or 'copy'"),
            response["error"]?["message"]?.stringValue ?? ""
        )
    }

    // MARK: - Source parsing

    func testSourceParsingCoversTheSpellingsAgentsUse() throws {
        let ref = SkillRepoRef("AstroQore/vibe-bar")!
        XCTAssertEqual(
            try SkillInstallSource("AstroQore/vibe-bar"),
            .repository(ref: ref, skillDirectory: nil)
        )
        XCTAssertEqual(
            try SkillInstallSource("AstroQore/vibe-bar#vibe-bar"),
            .repository(ref: ref, skillDirectory: "vibe-bar")
        )
        XCTAssertEqual(
            try SkillInstallSource("https://github.com/AstroQore/vibe-bar"),
            .repository(ref: ref, skillDirectory: nil)
        )
        XCTAssertEqual(
            try SkillInstallSource("https://github.com/AstroQore/vibe-bar.git"),
            .repository(ref: ref, skillDirectory: nil)
        )
        XCTAssertEqual(
            try SkillInstallSource("https://github.com/AstroQore/vibe-bar/archive/refs/heads/dev.zip"),
            .repository(ref: SkillRepoRef("AstroQore/vibe-bar@dev")!, skillDirectory: nil)
        )
        XCTAssertEqual(
            try SkillInstallSource("https://codeload.github.com/AstroQore/vibe-bar/zip/refs/heads/dev"),
            .repository(ref: SkillRepoRef("AstroQore/vibe-bar@dev")!, skillDirectory: nil)
        )
        XCTAssertEqual(
            try SkillInstallSource("~/skills/mine", homeDirectory: "/Users/example"),
            .localDirectory(URL(fileURLWithPath: "/Users/example/skills/mine", isDirectory: true))
        )

        // `skills/mine` is deliberately absent from this list: a bare
        // `owner/repo` shape is read as a repository, never as a relative
        // path, and a relative path is refused outright.
        for bad in ["", "vibe-bar", "a/b/c", "http://github.com/a/b", "../mine", "./mine"] {
            XCTAssertThrowsError(try SkillInstallSource(bad), "\"\(bad)\" must not parse")
        }
        XCTAssertThrowsError(try SkillInstallSource("acme/many#../escape")) { error in
            XCTAssertEqual(error as? SkillInstallSourceError, .invalidSkillDirectory("../escape"))
        }
    }

    // MARK: - Helpers

    private func raw(_ arguments: [String: MCPJSON]) async throws -> MCPJSON {
        try MCPTestSupport.decode(
            await server.handle(
                line: MCPTestSupport.call(id: 1, tool: "skills.install", arguments: .object(arguments))
            )
        )
    }

    private func call(_ arguments: [String: MCPJSON]) async throws -> MCPJSON {
        let response = try await raw(arguments)
        if let error = response["error"] {
            throw MCPTestError("Unexpected JSON-RPC error: \(error)")
        }
        XCTAssertFalse(MCPTestSupport.isError(response), "\(MCPTestSupport.errorText(response) ?? "")")
        return try MCPTestSupport.structured(response)
    }
}
