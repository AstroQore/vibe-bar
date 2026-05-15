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
        // Cookie-backed misc providers now stack their sessions through
        // `MiscCookieSlotStore` (one Keychain entry per tool, holding a
        // JSON-encoded list of slots). The authorizer needs to cover
        // every cookie-backed tool's slot list.
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "kimi.cookieSlots"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "cursor.cookieSlots"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "volcengine.cookieSlots"
        )))
        XCTAssertTrue(targets.contains(.init(
            service: "com.astroqore.VibeBar.misc-secrets",
            account: "alibaba.cookieSlots"
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
        // The single-cookie `CookieHeaderCache` entries are no longer the
        // authoritative storage (their contents migrate into slots on
        // first read) and should not appear in the current target list.
        XCTAssertFalse(targets.contains(.init(
            service: CookieHeaderCache.keychainService,
            account: CookieHeaderCache.keychainAccount(for: .minimax)
        )))
        XCTAssertFalse(targets.contains(.init(
            service: "com.astroqore.VibeBar.web-cookies",
            account: "misc.kimi.cookie"
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
