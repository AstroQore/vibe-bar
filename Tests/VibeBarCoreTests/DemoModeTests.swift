import XCTest
@testable import VibeBarCore

/// Demo mode is how the README screenshots are made: the real app against a
/// synthetic home. These tests pin the parse rules and the one guard that
/// matters — the real home can never be used as the demo home — without
/// touching the process-wide override, which `bootstrap` alone may set.
final class DemoModeTests: XCTestCase {
    private var temporaryHome: URL!

    override func setUpWithError() throws {
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-demo-mode-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryHome)
    }

    // MARK: - RealHomeDirectory shadow

    /// `VibeBarCore.RealHomeDirectory` shadows the kit's. This file imports
    /// only `VibeBarCore` — the same view of the world `VibeBarApp` has — so
    /// an unqualified `RealHomeDirectory` must be the overridable one, or demo
    /// mode would redirect some paths and not others. (A file that imports
    /// the kit directly as well sees both and has to qualify; see
    /// `RealHomeDirectoryShadowTests`.)
    func testRealHomeDirectoryResolvesToTheOverridableShadow() {
        XCTAssertTrue(ObjectIdentifier(RealHomeDirectory.self) == ObjectIdentifier(VibeBarCore.RealHomeDirectory.self))
        XCTAssertEqual(RealHomeDirectory.path, RealHomeDirectory.systemPath)
        XCTAssertFalse(DemoMode.isEnabled)
    }

    // MARK: - Parsing

    func testNotRequestedIsNil() throws {
        XCTAssertNil(try DemoMode.parse(environment: [:], arguments: ["VibeBar"], systemHome: "/Users/example"))
        XCTAssertNil(try DemoMode.parse(
            environment: [DemoMode.homeEnvironmentKey: ""],
            arguments: ["VibeBar"],
            systemHome: "/Users/example"
        ))
    }

    func testEnvironmentEnablesWithDefaults() throws {
        let configuration = try XCTUnwrap(DemoMode.parse(
            environment: [DemoMode.homeEnvironmentKey: temporaryHome.path],
            arguments: ["VibeBar"],
            systemHome: "/Users/example"
        ))
        XCTAssertEqual(configuration.homeDirectory, temporaryHome.resolvingSymlinksInPath().path)
        XCTAssertNil(configuration.appearance)
        XCTAssertNil(configuration.surface)
        XCTAssertTrue(configuration.showsBackdrop)
    }

    func testArgumentWinsOverEnvironment() throws {
        let other = temporaryHome.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let configuration = try XCTUnwrap(DemoMode.parse(
            environment: [DemoMode.homeEnvironmentKey: temporaryHome.path],
            arguments: ["VibeBar", DemoMode.homeArgument, other.path],
            systemHome: "/Users/example"
        ))
        XCTAssertEqual(configuration.homeDirectory, other.resolvingSymlinksInPath().path)
    }

    func testArgumentWithoutAValueThrows() {
        XCTAssertThrowsError(try DemoMode.parse(
            environment: [:],
            arguments: ["VibeBar", DemoMode.homeArgument],
            systemHome: "/Users/example"
        )) { error in
            XCTAssertEqual(error as? DemoMode.BootstrapError, .missingArgument)
        }
    }

    func testMissingDirectoryThrows() {
        let missing = temporaryHome.appendingPathComponent("missing").path
        XCTAssertThrowsError(try DemoMode.parse(
            environment: [DemoMode.homeEnvironmentKey: missing],
            arguments: ["VibeBar"],
            systemHome: "/Users/example"
        )) { error in
            XCTAssertEqual(error as? DemoMode.BootstrapError, .notADirectory(missing))
        }
    }

    /// The guard that keeps a typo from putting the live store into a mode
    /// that never refreshes it. Compared after resolving symlinks, so `/tmp`
    /// and `/private/tmp` cannot be used to slip past it either.
    func testTheRealHomeIsRefused() {
        let resolved = temporaryHome.resolvingSymlinksInPath().path
        XCTAssertThrowsError(try DemoMode.parse(
            environment: [DemoMode.homeEnvironmentKey: temporaryHome.path],
            arguments: ["VibeBar"],
            systemHome: resolved
        )) { error in
            XCTAssertEqual(error as? DemoMode.BootstrapError, .isRealHome(resolved))
        }
    }

    func testAppearanceSurfaceAndBackdropOptions() throws {
        let configuration = try XCTUnwrap(DemoMode.parse(
            environment: [
                DemoMode.homeEnvironmentKey: temporaryHome.path,
                DemoMode.appearanceEnvironmentKey: "Light",
                DemoMode.surfaceEnvironmentKey: "settings:provider:codex",
                DemoMode.backdropEnvironmentKey: "0",
            ],
            arguments: ["VibeBar"],
            systemHome: "/Users/example"
        ))
        XCTAssertEqual(configuration.appearance, .light)
        XCTAssertEqual(configuration.surface, .settings(section: "provider:codex"))
        XCTAssertFalse(configuration.showsBackdrop)
    }

    func testUnknownAppearanceAndSurfaceAreIgnoredNotFatal() throws {
        let configuration = try XCTUnwrap(DemoMode.parse(
            environment: [
                DemoMode.homeEnvironmentKey: temporaryHome.path,
                DemoMode.appearanceEnvironmentKey: "sepia",
                DemoMode.surfaceEnvironmentKey: "dock:overview",
            ],
            arguments: ["VibeBar"],
            systemHome: "/Users/example"
        ))
        XCTAssertNil(configuration.appearance)
        XCTAssertNil(configuration.surface)
    }

    func testSurfaceParsing() {
        XCTAssertEqual(DemoMode.Surface(parsing: "popover:openAI"), .popover(page: "openAI"))
        XCTAssertEqual(DemoMode.Surface(parsing: "popover"), .popover(page: ""))
        XCTAssertEqual(DemoMode.Surface(parsing: "mini:compact"), .miniWindow(mode: "compact"))
        XCTAssertEqual(DemoMode.Surface(parsing: " workbench:skillsManager "), .workbench(page: "skillsManager"))
        XCTAssertEqual(DemoMode.Surface(parsing: "settings:layout"), .settings(section: "layout"))
        XCTAssertEqual(DemoMode.Surface(parsing: "onboarding"), .onboarding(step: ""))
        XCTAssertEqual(DemoMode.Surface(parsing: "onboarding:subscriptions"), .onboarding(step: "subscriptions"))
        XCTAssertNil(DemoMode.Surface(parsing: "window:main"))
        XCTAssertNil(DemoMode.Surface(parsing: ""))
    }

    // MARK: - Demo accounts

    func testDemoAccountsFileRoundTrip() throws {
        let file = DemoAccountsStore.File(accounts: [
            DemoAccountsStore.Entry(id: "demo-codex", tool: .codex, alias: "Codex OAuth", plan: "pro", source: .oauthCLI),
            DemoAccountsStore.Entry(id: "web-claude", tool: .claude, alias: "Claude Web", plan: "Max", source: .webCookie),
        ])
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(DemoAccountsStore.File.self, from: data)
        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.accounts.map(\.id), ["demo-codex", "web-claude"])
    }

    /// The file `Scripts/demo_home.py` writes, as it writes it.
    func testDemoAccountsFileDecodesTheScriptsShape() throws {
        let json = """
        {
          "accounts": [
            {"alias": "Codex OAuth", "id": "demo-codex", "plan": "pro", "source": "oauthCLI", "tool": "codex"},
            {"alias": "Antigravity", "id": "local-antigravity", "plan": null, "source": "localProbe", "tool": "antigravity"}
          ],
          "schemaVersion": 1
        }
        """
        let decoded = try JSONDecoder().decode(DemoAccountsStore.File.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.accounts.count, 2)
        XCTAssertEqual(decoded.accounts[1].tool, .antigravity)
        XCTAssertNil(decoded.accounts[1].plan)
        XCTAssertEqual(decoded.accounts[1].source, .localProbe)
    }
}
