import XCTest
@testable import VibeBarCore

final class PrimaryProviderRouteHealthTests: XCTestCase {
    func testRoutesCoverDedicatedGoogleAndGrokProviders() {
        XCTAssertEqual(
            PrimaryProviderRoute.routes(for: .gemini),
            [.geminiBrowserCookies]
        )
        XCTAssertEqual(
            PrimaryProviderRoute.routes(for: .antigravity),
            [.antigravityLocalProbe]
        )
        XCTAssertEqual(
            PrimaryProviderRoute.routes(for: .grok),
            [.grokAuthJSON, .grokBrowserCookies]
        )
    }

    func testProcessOutputDrainsLargeStdoutBeforeWaiting() throws {
        let result = try XCTUnwrap(
            PrimaryProviderRouteHealthChecker.captureProcessOutput(
                executablePath: "/usr/bin/awk",
                arguments: [
                    #"BEGIN { for (i = 0; i < 20000; i++) print "antigravity language_server_macos" }"#
                ]
            )
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.output.contains("antigravity language_server_macos"))
    }
}
