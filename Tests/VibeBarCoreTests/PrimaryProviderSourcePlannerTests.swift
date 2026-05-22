import XCTest
@testable import VibeBarCore

final class PrimaryProviderSourcePlannerTests: XCTestCase {
    func testCodexAutoPrefersCLIThenOAuth() {
        let plan = CodexSourcePlanner.resolve(mode: .auto)

        XCTAssertEqual(plan, [.cliDetected, .oauthCLI])
    }

    func testCodexExplicitCLIOnlyDoesNotFallback() {
        let plan = CodexSourcePlanner.resolve(mode: .cliOnly)

        XCTAssertEqual(plan, [.cliDetected])
    }

    func testClaudeAutoPrefersWebThenOAuthThenCLI() {
        let plan = ClaudeSourcePlanner.resolve(mode: .auto)

        XCTAssertEqual(plan, [.webCookie, .oauthCLI, .cliDetected])
    }

    func testClaudeWebThenCLIThenOAuthOrder() {
        let plan = ClaudeSourcePlanner.resolve(mode: .webThenCli)

        XCTAssertEqual(plan, [.webCookie, .cliDetected, .oauthCLI])
    }

    // MARK: - Gemini
    //
    // Gemini live quota is Web-only. CLI telemetry remains a
    // cost-history input, not a quota source.

    func testGeminiEnablesOnlyWeb() {
        XCTAssertEqual(GeminiSourcePlanner.enabledSources(mode: .webOnly), [.webCookie])
        XCTAssertFalse(GeminiSourcePlanner.runsOAuth(mode: .webOnly))
        XCTAssertTrue(GeminiSourcePlanner.runsWeb(mode: .webOnly))
    }

    // MARK: - Antigravity

    func testAntigravityAutoCollapsesToLocalProbeWhileWebFlagOff() {
        // `antigravityWebSourceAvailable` is `false` until the
        // Antigravity Cloud endpoint spike completes (plan §9).
        // Until then, every mode that would include `.webCookie`
        // must degrade gracefully to local-probe-only.
        XCTAssertFalse(AntigravitySourcePlanner.antigravityWebSourceAvailable,
                       "Flip this test once antigravityWebSourceAvailable goes true.")

        let plan = AntigravitySourcePlanner.resolve(mode: .auto)

        XCTAssertEqual(plan, [.localProbe])
    }

    func testAntigravityLocalOnlyAlwaysReturnsLocal() {
        let plan = AntigravitySourcePlanner.resolve(mode: .localOnly)

        XCTAssertEqual(plan, [.localProbe])
    }

    func testAntigravityWebOnlyCollapsesToLocalWhileWebFlagOff() {
        // `.webOnly` is a user-visible option; planner must still
        // degrade rather than return an empty source list, otherwise
        // the dedicated card would show "no credential" forever.
        let plan = AntigravitySourcePlanner.resolve(mode: .webOnly)

        XCTAssertEqual(plan, [.localProbe])
    }

    func testAntigravityWebThenLocalCollapsesWhileWebFlagOff() {
        let plan = AntigravitySourcePlanner.resolve(mode: .webThenLocal)

        XCTAssertEqual(plan, [.localProbe])
    }
}
