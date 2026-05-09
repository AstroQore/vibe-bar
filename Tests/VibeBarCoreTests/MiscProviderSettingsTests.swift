import XCTest
@testable import VibeBarCore

final class MiscProviderSettingsTests: XCTestCase {
    // MARK: - Default round-trip

    func testDefaultRoundTrips() throws {
        let original = MiscProviderSettings.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MiscProviderSettings.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testCustomValuesRoundTrip() throws {
        let original = MiscProviderSettings(
            sourceMode: .browserOnly,
            cookieSource: .manual,
            region: "cn-beijing",
            enterpriseHost: URL(string: "https://copilot.example.com/")!,
            preferredBrowser: .brave,
            enabledOverride: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MiscProviderSettings.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let json = """
        { }
        """
        let decoded = try JSONDecoder().decode(MiscProviderSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sourceMode, .auto)
        XCTAssertEqual(decoded.cookieSource, .auto)
        XCTAssertNil(decoded.region)
        XCTAssertNil(decoded.enterpriseHost)
        XCTAssertNil(decoded.preferredBrowser)
        XCTAssertNil(decoded.enabledOverride)
    }

    // MARK: - Sensitive-field guard

    func testLooksSensitiveCatchesObviousSecretKeys() {
        XCTAssertTrue(MiscProviderSettings.looksSensitive("apiKey"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("api_key"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("apikey"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("API_KEY"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("cookieHeader"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("manual_cookie"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("accessToken"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("refresh_token"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("password"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("client_secret"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("sessionKey"))
        XCTAssertTrue(MiscProviderSettings.looksSensitive("personalAccessToken"))
    }

    func testLooksSensitiveLeavesBenignKeys() {
        // The `cookieSource` field IS non-sensitive metadata (an
        // auto/manual/off mode), so the matcher must not flag it
        // even though it contains the substring "cookie". The
        // refined marker list targets compound names that imply
        // secret payloads (e.g. "cookieHeader") rather than any
        // mention of "cookie".
        XCTAssertFalse(MiscProviderSettings.looksSensitive("sourceMode"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("cookieSource"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("region"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("enterpriseHost"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("preferredBrowser"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("enabledOverride"))
    }

    func testSanitizeStripsSecretKeys() {
        let dict: [String: Any] = [
            "sourceMode": "auto",
            "region": "cn-beijing",
            "apiKey": "sk-secret",
            "cookieHeader": "sessionKey=secret",
            "accessToken": "AT.123",
            "preferredBrowser": "chrome"
        ]
        let (cleaned, dropped) = MiscProviderSettings.sanitize(rawJSON: dict)
        XCTAssertNil(cleaned["apiKey"])
        XCTAssertNil(cleaned["cookieHeader"])
        XCTAssertNil(cleaned["accessToken"])
        XCTAssertEqual(cleaned["sourceMode"] as? String, "auto")
        XCTAssertEqual(cleaned["region"] as? String, "cn-beijing")
        XCTAssertEqual(cleaned["preferredBrowser"] as? String, "chrome")
        XCTAssertEqual(Set(dropped), ["apiKey", "cookieHeader", "accessToken"])
    }

    func testDecoderIgnoresUnknownAndSecretFields() throws {
        // Even if a settings.json from a future build accidentally
        // wrote a `cookieHeader` field, our decoder should ignore it
        // (it's not in CodingKeys) and never round-trip the secret.
        let json = """
        {
          "sourceMode": "browserOnly",
          "cookieHeader": "sessionKey=evil",
          "apiKey": "sk-evil",
          "region": "ap-southeast-1"
        }
        """
        let settings = try JSONDecoder().decode(MiscProviderSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sourceMode, .browserOnly)
        XCTAssertEqual(settings.region, "ap-southeast-1")

        // Re-encode and verify no leakage.
        let data = try JSONEncoder().encode(settings)
        let raw = String(data: data, encoding: .utf8)!
        XCTAssertFalse(raw.contains("cookieHeader"))
        XCTAssertFalse(raw.contains("sessionKey=evil"))
        XCTAssertFalse(raw.contains("apiKey"))
        XCTAssertFalse(raw.contains("sk-evil"))
    }

    func testSourceModeAccessGatesCredentialTypes() {
        XCTAssertTrue(MiscProviderSettings(sourceMode: .auto).allowsAPIOrOAuthAccess)
        XCTAssertTrue(MiscProviderSettings(sourceMode: .manualOnly).allowsAPIOrOAuthAccess)
        XCTAssertTrue(MiscProviderSettings(sourceMode: .apiOnly).allowsAPIOrOAuthAccess)
        XCTAssertFalse(MiscProviderSettings(sourceMode: .browserOnly).allowsAPIOrOAuthAccess)
        XCTAssertFalse(MiscProviderSettings(sourceMode: .off).allowsAPIOrOAuthAccess)

        XCTAssertTrue(MiscProviderSettings(sourceMode: .auto).allowsLocalProbeAccess)
        XCTAssertTrue(MiscProviderSettings(sourceMode: .apiOnly).allowsLocalProbeAccess)
        XCTAssertFalse(MiscProviderSettings(sourceMode: .manualOnly).allowsLocalProbeAccess)
        XCTAssertFalse(MiscProviderSettings(sourceMode: .browserOnly).allowsLocalProbeAccess)
        XCTAssertFalse(MiscProviderSettings(sourceMode: .off).allowsLocalProbeAccess)
    }
}

final class AppSettingsMiscProviderTests: XCTestCase {
    func testDefaultsIncludeEveryMiscProvider() {
        let settings = AppSettings.default
        for tool in ToolType.miscProviders {
            XCTAssertNotNil(settings.miscProviders[tool], "default settings missing entry for \(tool)")
            XCTAssertEqual(settings.miscProviders[tool], .default)
        }
    }

    func testMissingMiscProvidersFieldFillsDefaults() throws {
        // Old settings.json from before this PR had no miscProviders
        // key. Decoding should still produce a complete map.
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.miscProviders.count, ToolType.miscProviders.count)
    }

    func testUnknownMiscProviderKeysAreDropped() throws {
        let json = """
        {
          "miscProviders": {
            "alibaba": {"sourceMode": "browserOnly"},
            "removedProvider": {"sourceMode": "auto"}
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.miscProviders[.alibaba]?.sourceMode, .auto)
        // Every other misc tool falls back to default.
        for tool in ToolType.miscProviders where tool != .alibaba {
            XCTAssertEqual(settings.miscProviders[tool], .default, "expected default for \(tool)")
        }
    }

    func testLegacySourceSelectorsNormalizeToAutomatic() throws {
        let json = """
        {
          "miscProviders": {
            "minimax": {
              "sourceMode": "off",
              "cookieSource": "manual",
              "preferredBrowser": "chrome",
              "region": "cn"
            }
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        let minimax = settings.miscProvider(.minimax)
        XCTAssertEqual(minimax.sourceMode, .auto)
        XCTAssertEqual(minimax.cookieSource, .auto)
        XCTAssertNil(minimax.preferredBrowser)
        XCTAssertEqual(minimax.region, "cn")
    }
}
