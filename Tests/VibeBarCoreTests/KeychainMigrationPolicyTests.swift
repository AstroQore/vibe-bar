import XCTest
@testable import VibeBarCore

final class KeychainMigrationPolicyTests: XCTestCase {
    func testLegacyMiscMigrationNeverUsesPromptingLoginKeychain() {
        XCTAssertEqual(
            LegacyKeychainMigrationPolicy.backendsForAutomaticMigration,
            [.dataProtection]
        )
    }

    func testVaultUsesOneStablePhysicalKeychainItem() {
        XCTAssertEqual(VibeBarCredentialVault.keychainService, "com.astroqore.VibeBar.credential-vault")
        XCTAssertEqual(VibeBarCredentialVault.keychainAccount, "vault-v1")
    }

    func testVaultPayloadDeduplicatesAndRoundTripsBinaryData() throws {
        var payload = VibeBarCredentialVault.Payload(entries: [
            .init(service: "service-b", account: "account", data: Data([0, 1, 2])),
            .init(service: "service-a", account: "account", data: Data("old".utf8))
        ])
        payload.set(Data("new".utf8), service: "service-a", account: "account")
        payload.set(Data("second".utf8), service: "service-a", account: "other")

        let encoded = try VibeBarCredentialVault.encodePayload(payload)
        let decoded = try VibeBarCredentialVault.decodePayload(encoded)

        XCTAssertEqual(decoded.entries.count, 3)
        XCTAssertEqual(decoded.data(service: "service-a", account: "account"), Data("new".utf8))
        XCTAssertEqual(decoded.data(service: "service-b", account: "account"), Data([0, 1, 2]))
    }

    func testVaultPayloadDeleteDoesNotAffectSiblingAccount() {
        var payload = VibeBarCredentialVault.Payload(entries: [
            .init(service: "service", account: "one", data: Data("1".utf8)),
            .init(service: "service", account: "two", data: Data("2".utf8))
        ])

        XCTAssertTrue(payload.remove(service: "service", account: "one"))
        XCTAssertNil(payload.data(service: "service", account: "one"))
        XCTAssertEqual(payload.data(service: "service", account: "two"), Data("2".utf8))
    }
}
