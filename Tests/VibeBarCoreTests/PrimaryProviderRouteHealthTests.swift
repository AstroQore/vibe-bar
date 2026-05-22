import XCTest
@testable import VibeBarCore

final class PrimaryProviderRouteHealthTests: XCTestCase {
    func testRoutesCoverDedicatedGoogleAndGrokProviders() {
        XCTAssertEqual(
            PrimaryProviderRoute.routes(for: .gemini),
            [.geminiOAuth, .geminiBrowserCookies]
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
}
