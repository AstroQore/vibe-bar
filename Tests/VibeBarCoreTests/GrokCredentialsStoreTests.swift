import XCTest
@testable import VibeBarCore

final class GrokCredentialsStoreTests: XCTestCase {
    func testParsesOIDCSuperGrokEntry() throws {
        let json = """
        {
          "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
            "key": "secret-access-token-123",
            "auth_mode": "oidc",
            "user_id": "user-uuid",
            "email": "user@example.com",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "team_id": "team-uuid",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """
        let creds = try GrokCredentialsStore.parse(data: Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "secret-access-token-123")
        XCTAssertEqual(creds.email, "user@example.com")
        XCTAssertEqual(creds.teamId, "team-uuid")
        XCTAssertEqual(creds.authMode, "oidc")
        XCTAssertEqual(creds.planLabel, "SuperGrok")
        XCTAssertEqual(creds.displayName, "Ada Lovelace")
        XCTAssertFalse(creds.isExpired)
    }

    func testFallsBackToLegacySessionWhenOIDCAbsent() throws {
        let json = """
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "session",
            "email": "legacy@example.com"
          }
        }
        """
        let creds = try GrokCredentialsStore.parse(data: Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "legacy-token")
        XCTAssertEqual(creds.email, "legacy@example.com")
        XCTAssertEqual(creds.planLabel, "Session")
    }

    func testPrefersOIDCWhenBothPresent() throws {
        let json = """
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-should-not-win",
            "auth_mode": "session"
          },
          "https://auth.x.ai::client-id": {
            "key": "oidc-wins",
            "auth_mode": "oidc",
            "email": "preferred@example.com"
          }
        }
        """
        let creds = try GrokCredentialsStore.parse(data: Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "oidc-wins")
        XCTAssertEqual(creds.email, "preferred@example.com")
    }

    func testStaleOIDCEntryDoesNotShadowHealthyLegacy() throws {
        let json = """
        {
          "https://auth.x.ai::stale-client": {
            "auth_mode": "oidc",
            "email": "stale@example.com"
          },
          "https://accounts.x.ai/sign-in": {
            "key": "healthy-legacy-token",
            "auth_mode": "session",
            "email": "healthy@example.com"
          }
        }
        """
        let creds = try GrokCredentialsStore.parse(data: Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "healthy-legacy-token")
        XCTAssertEqual(creds.email, "healthy@example.com")
    }

    func testThrowsNoCredentialWhenKeyAbsent() {
        let json = #"{"https://auth.x.ai::abc": {"auth_mode": "oidc"}}"#
        do {
            _ = try GrokCredentialsStore.parse(data: Data(json.utf8))
            XCTFail("Expected noCredential")
        } catch let error as QuotaError {
            guard case .noCredential = error else {
                return XCTFail("Expected .noCredential, got \(error)")
            }
        } catch {
            XCTFail("Expected QuotaError, got \(error)")
        }
    }

    func testThrowsParseFailureWhenJSONInvalid() {
        do {
            _ = try GrokCredentialsStore.parse(data: Data("not-json".utf8))
            XCTFail("Expected parseFailure")
        } catch let error as QuotaError {
            guard case .parseFailure = error else {
                return XCTFail("Expected .parseFailure, got \(error)")
            }
        } catch {
            XCTFail("Expected QuotaError, got \(error)")
        }
    }

    func testIsExpiredFlipsAtExpiresAt() throws {
        let pastJSON = """
        {
          "https://auth.x.ai::client": {
            "key": "stale-token",
            "expires_at": "2020-01-01T00:00:00Z"
          }
        }
        """
        XCTAssertTrue(try GrokCredentialsStore.parse(data: Data(pastJSON.utf8)).isExpired)

        let futureJSON = """
        {
          "https://auth.x.ai::client": {
            "key": "fresh-token",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """
        XCTAssertFalse(try GrokCredentialsStore.parse(data: Data(futureJSON.utf8)).isExpired)

        // Missing expires_at is treated as "never expires" so a legacy
        // auth.json predating this field doesn't lock the user out.
        let noExpiryJSON = """
        {
          "https://auth.x.ai::client": {
            "key": "ageless-token"
          }
        }
        """
        XCTAssertFalse(try GrokCredentialsStore.parse(data: Data(noExpiryJSON.utf8)).isExpired)
    }

    func testAuthFileURLResolvesUnderHomeDirectory() {
        let url = GrokCredentialsStore.authFileURL(homeDirectory: "/Users/example")
        XCTAssertEqual(url.path, "/Users/example/.grok/auth.json")
    }
}
