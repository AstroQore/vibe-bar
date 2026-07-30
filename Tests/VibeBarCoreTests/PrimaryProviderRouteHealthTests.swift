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

    func testAntigravityCachedDataIsHealthyWhileLSPIsOffline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let health = PrimaryProviderRouteHealthChecker.antigravityLocalProbeHealth(
            languageServerRunning: false,
            hasLocalData: true,
            now: now
        )

        XCTAssertEqual(health.status, .ok)
        XCTAssertEqual(health.detail, "Local data available; LSP offline")
        XCTAssertEqual(health.checkedAt, now)
    }

    func testAntigravityWithoutLSPOrLocalDataNeedsSetup() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let health = PrimaryProviderRouteHealthChecker.antigravityLocalProbeHealth(
            languageServerRunning: false,
            hasLocalData: false,
            now: now
        )

        XCTAssertEqual(health.status, .missing)
        XCTAssertEqual(health.detail, "No local Antigravity data")
    }

    /// The probe spawns `/bin/ps` and blocks until it exits, and route health is
    /// re-checked on every refresh — including per provider, so refreshing the
    /// Gemini card alone used to spawn it twice. Inside the TTL the answer is
    /// reused; past it, and after an explicit invalidation, it is re-probed.
    func testLanguageServerProbeIsCachedForItsTTL() {
        PrimaryProviderRouteHealthChecker.invalidateLanguageServerProbeCache()
        defer { PrimaryProviderRouteHealthChecker.invalidateLanguageServerProbeCache() }

        var probes = 0
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let probe: () -> Bool = {
            probes += 1
            return true
        }

        XCTAssertTrue(PrimaryProviderRouteHealthChecker.antigravityLanguageServerIsRunning(
            now: start,
            probe: probe
        ))
        XCTAssertTrue(PrimaryProviderRouteHealthChecker.antigravityLanguageServerIsRunning(
            now: start.addingTimeInterval(30),
            probe: probe
        ))
        XCTAssertEqual(probes, 1)

        XCTAssertTrue(PrimaryProviderRouteHealthChecker.antigravityLanguageServerIsRunning(
            now: start.addingTimeInterval(61),
            probe: probe
        ))
        XCTAssertEqual(probes, 2)

        PrimaryProviderRouteHealthChecker.invalidateLanguageServerProbeCache()
        XCTAssertTrue(PrimaryProviderRouteHealthChecker.antigravityLanguageServerIsRunning(
            now: start.addingTimeInterval(61),
            probe: probe
        ))
        XCTAssertEqual(probes, 3)
    }
}
