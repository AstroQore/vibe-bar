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
}
