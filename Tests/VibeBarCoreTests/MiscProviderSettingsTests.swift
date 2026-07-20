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
            planVariant: "personal",
            enterpriseHost: URL(string: "https://copilot.example.com/")!,
            workspaceID: "wrk_demo",
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
        XCTAssertNil(decoded.planVariant)
        XCTAssertNil(decoded.enterpriseHost)
        XCTAssertNil(decoded.workspaceID)
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
        XCTAssertFalse(MiscProviderSettings.looksSensitive("planVariant"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("enterpriseHost"))
        XCTAssertFalse(MiscProviderSettings.looksSensitive("workspaceID"))
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
    func testDefaultsIncludeEveryMiscPageProvider() {
        // Partial-primary providers (`.gemini`, `.antigravity`) live in
        // top-level `*UsageMode` fields after the dedicated-card upgrade
        // and are intentionally absent from `miscProviders` defaults.
        let settings = AppSettings.default
        for tool in ToolType.miscPageProviders {
            XCTAssertNotNil(settings.miscProviders[tool], "default settings missing entry for \(tool)")
            XCTAssertEqual(settings.miscProviders[tool], .default)
            XCTAssertTrue(settings.isMiscProviderVisible(tool), "default settings should show \(tool)")
        }
    }

    func testMissingMiscProvidersFieldFillsDefaults() throws {
        // Old settings.json from before this PR had no miscProviders
        // key. Decoding should still produce a complete map for every
        // misc-page provider.
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
        XCTAssertEqual(settings.miscProviders.count, ToolType.miscPageProviders.count)
        XCTAssertEqual(settings.visibleMiscProviders, AppSettings.defaultVisibleMiscProviders)
    }

    func testVisibleMiscProvidersRoundTripAndDropsUnknowns() throws {
        let json = """
        {
          "visibleMiscProviders": ["minimax", "openRouter", "removedProvider", "codex"]
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.visibleMiscProviders, [.minimax, .openRouter])
        XCTAssertTrue(settings.isMiscProviderVisible(.minimax))
        XCTAssertFalse(settings.isMiscProviderVisible(.kilo))

        var mutable = settings
        mutable.setMiscProviderVisible(true, for: .kilo)
        mutable.setMiscProviderVisible(false, for: .minimax)
        XCTAssertEqual(mutable.visibleMiscProviderList, [.kilo, .openRouter])

        let encoded = try JSONEncoder().encode(mutable)
        let raw = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(raw.contains("visibleMiscProviders"))
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let visibleRaw = object?["visibleMiscProviders"] as? [String]
        XCTAssertEqual(visibleRaw, ["kilo", "openRouter"])
    }

    func testMiscProviderOrderRoundTripAndDrivesVisibilityOrder() throws {
        let json = """
        {
          "visibleMiscProviders": ["minimax", "openRouter", "kilo"],
          "miscProviderOrder": ["openRouter", "removedProvider", "codex", "minimax"]
        }
        """
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.miscProviderOrder.prefix(2), [.openRouter, .minimax])
        XCTAssertEqual(settings.visibleMiscProviderList, [.openRouter, .minimax, .kilo])

        settings.moveMiscProvider(.kilo, offset: -20)
        XCTAssertEqual(settings.miscProviderOrder.first, .kilo)
        XCTAssertEqual(settings.visibleMiscProviderList, [.kilo, .openRouter, .minimax])

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["miscProviderOrder"] as? [String], settings.miscProviderOrder.map(\.rawValue))
    }

    func testClonedMiscProviderInstancesAreIndependentAndReorderable() {
        var settings = AppSettings.default
        let originalID = ToolType.volcengine.rawValue

        guard let clone = settings.cloneMiscProviderInstance(id: originalID) else {
            return XCTFail("expected Volcengine clone")
        }

        XCTAssertNotEqual(clone.id, originalID)
        XCTAssertEqual(clone.tool, .volcengine)
        XCTAssertEqual(settings.visibleMiscProviderInstances.filter { $0.tool == .volcengine }.count, 2)

        var cloneSettings = settings.miscProviderInstance(id: clone.id)?.settings ?? .default
        cloneSettings.region = "cn-beijing"
        settings.setMiscProviderInstanceSettings(cloneSettings, forID: clone.id)

        XCTAssertNil(settings.miscProviderInstance(id: originalID)?.settings.region)
        XCTAssertEqual(settings.miscProviderInstance(id: clone.id)?.settings.region, "cn-beijing")

        settings.moveMiscProviderInstance(id: clone.id, before: originalID)
        let ids = settings.miscProviderInstances.map(\.id)
        XCTAssertLessThan(
            try XCTUnwrap(ids.firstIndex(of: clone.id)),
            try XCTUnwrap(ids.firstIndex(of: originalID))
        )
        settings.moveMiscProviderInstanceToEnd(id: clone.id)
        XCTAssertEqual(settings.miscProviderInstances.last?.id, clone.id)

        settings.setMiscProviderInstanceVisible(false, forID: clone.id)
        XCTAssertEqual(settings.visibleMiscProviderInstances.filter { $0.tool == .volcengine }.map(\.id), [originalID])
    }

    func testMiscProviderInstanceDisplayNamesAreIndependentAndRoundTrip() throws {
        var settings = AppSettings.default
        let originalID = ToolType.volcengine.rawValue

        guard let clone = settings.cloneMiscProviderInstance(id: originalID) else {
            return XCTFail("expected Volcengine clone")
        }

        settings.setMiscProviderInstanceDisplayName("  Work account  ", forID: clone.id)

        XCTAssertNil(settings.miscProviderInstance(id: originalID)?.displayName)
        XCTAssertEqual(settings.miscProviderInstance(id: clone.id)?.displayName, "Work account")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.miscProviderInstance(id: clone.id)?.displayName, "Work account")

        var mutable = decoded
        mutable.setMiscProviderInstanceDisplayName("   ", forID: clone.id)
        XCTAssertNil(mutable.miscProviderInstance(id: clone.id)?.displayName)
    }

    func testLegacyMiscProviderFieldsMigrateToDefaultInstances() throws {
        let json = """
        {
          "visibleMiscProviders": ["openRouter", "minimax"],
          "miscProviderOrder": ["openRouter", "removedProvider", "codex", "minimax"],
          "miscProviders": {
            "minimax": { "region": "global" }
          }
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.miscProviderInstances.prefix(2).map(\.tool), [.openRouter, .minimax])
        XCTAssertEqual(settings.visibleMiscProviderInstances.map(\.tool), [.openRouter, .minimax])
        XCTAssertEqual(settings.miscProviderInstance(id: ToolType.minimax.rawValue)?.settings.region, "global")
    }

    func testAccountStoreCreatesSeparateAccountsForMiscProviderInstances() {
        var settings = AppSettings.default
        guard let clone = settings.cloneMiscProviderInstance(id: ToolType.volcengine.rawValue) else {
            return XCTFail("expected Volcengine clone")
        }

        let accounts = AccountStore.miscAccounts(for: settings.miscProviderInstances)
        let volcengineAccounts = accounts.filter { $0.tool == .volcengine }

        XCTAssertEqual(volcengineAccounts.map(\.id), [
            AccountStore.miscAccountId(forInstanceID: ToolType.volcengine.rawValue),
            AccountStore.miscAccountId(forInstanceID: clone.id)
        ])
        XCTAssertEqual(Set(volcengineAccounts.map(\.id)).count, 2)
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
        // Every other misc-page tool falls back to default. Partial-primary
        // providers no longer live in this dictionary.
        for tool in ToolType.miscPageProviders where tool != .alibaba {
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
