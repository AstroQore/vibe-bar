import XCTest
@testable import VibeBarCore

final class KeychainMigrationPolicyTests: XCTestCase {
    func testLegacyMiscMigrationNeverUsesPromptingLoginKeychain() {
        XCTAssertEqual(
            LegacyKeychainMigrationPolicy.backendsForAutomaticMigration,
            [.dataProtection]
        )
    }

    func testAuthorizationTargetsCoverVibeBarOwnedStores() {
        let targets = Set(VibeBarKeychainAccessAuthorizer.ownedTargets)

        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.web-cookies",
            account: "openai.browser.cookie"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.web-cookies",
            account: "claude.webView.cookie"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.web-cookies",
            account: "claude.organization-id"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.web-cookies",
            account: "misc.kimi.cookie"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.web-cookies",
            account: "misc.cursor.cookie"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "copilot.oauthAccessToken"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "zai.apiKey"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "minimax.apiKey"
        )))
        XCTAssertFalse(targets.contains(.init(
            service: CookieHeaderCache.keychainService,
            account: CookieHeaderCache.keychainAccount(for: .minimax)
        )))
    }

    func testAuthorizationTargetsIncludeLegacyOwnedStores() {
        let targets = Set(VibeBarKeychainAccessAuthorizer.ownedTargets)

        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc",
            account: "cookie.antigravity"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc",
            account: "antigravity.importedCookieHeader"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "Vibe Bar Claude Web Cookies",
            account: "claude.ai"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "Vibe Bar Claude Web Cookies",
            account: "claude.ai.organization"
        )))
    }

    func testAuthorizationTargetsExcludeExternalCredentialStores() {
        let targets = VibeBarKeychainAccessAuthorizer.ownedTargets
        let pairs = Set(targets.map { "\($0.service)|\($0.account)" })

        XCTAssertEqual(targets.count, pairs.count)
        XCTAssertFalse(targets.contains { $0.service == "Codex Auth" })
        XCTAssertFalse(targets.contains { $0.service == "Claude Code-credentials" })
        XCTAssertFalse(targets.contains { $0.service.localizedCaseInsensitiveContains("Chrome Safe Storage") })
    }
}
