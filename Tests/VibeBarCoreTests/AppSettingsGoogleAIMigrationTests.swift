import XCTest
@testable import VibeBarCore

/// Locks the one-way migration from "Gemini / Antigravity were misc
/// providers" to "they're partial-primary, have top-level
/// `*UsageMode` fields, and are excluded from `miscProviderInstances`."
///
/// The migration runs on every `init(from:)` because both the decode
/// path and the normalisation helpers now filter by `isMiscPageProvider`.
final class AppSettingsGoogleAIMigrationTests: XCTestCase {
    func testDefaultIncludesNewGoogleAIUsageModes() {
        XCTAssertEqual(AppSettings.default.geminiUsageMode, .webOnly)
        XCTAssertEqual(AppSettings.default.antigravityUsageMode, .auto)
    }

    func testGeminiUsageModeRoundTrip() throws {
        var settings = AppSettings.default
        settings.geminiUsageMode = .webOnly
        settings.antigravityUsageMode = .localOnly

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.geminiUsageMode, .webOnly)
        XCTAssertEqual(decoded.antigravityUsageMode, .localOnly)
    }

    /// Old `settings.json` files persisted while earlier enums were
    /// in place may contain CLI/OAuth modes. The `decodeIfPresent`
    /// fallback should drop the unknown value and re-default to
    /// `.webOnly`, because CLI quota fetch is no longer supported.
    func testLegacyGeminiUsageModeFallsBackToWebOnly() throws {
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "geminiUsageMode": "webThenOAuth"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.geminiUsageMode, .webOnly)
    }

    func testLegacyGeminiMiscInstanceIsDroppedOnDecode() throws {
        // Older settings files include `.gemini` / `.antigravity` in
        // `miscProviderInstances`. After the partial-primary upgrade
        // those entries are stale and must not survive a decode.
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "miscProviderInstances": [
            { "id": "gemini", "tool": "gemini", "isVisible": true, "isDefault": true, "settings": {} },
            { "id": "antigravity", "tool": "antigravity", "isVisible": true, "isDefault": true, "settings": {} },
            { "id": "cursor", "tool": "cursor", "isVisible": true, "isDefault": true, "settings": {} }
          ]
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.miscProviderInstances.contains { $0.tool == .gemini },
                       "legacy .gemini misc instance must be filtered out")
        XCTAssertFalse(settings.miscProviderInstances.contains { $0.tool == .antigravity },
                       "legacy .antigravity misc instance must be filtered out")
        XCTAssertTrue(settings.miscProviderInstances.contains { $0.tool == .cursor },
                      "unrelated misc instances must survive the migration")
    }

    func testLegacyGeminiMiscEntryInMiscProvidersDictIsDroppedOnDecode() throws {
        // The decode path also reads the legacy `miscProviders` dictionary
        // (the pre-instance shape). Same migration rule applies there.
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "miscProviders": {
            "gemini": {},
            "antigravity": {},
            "cursor": {}
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertNil(settings.miscProviders[.gemini])
        XCTAssertNil(settings.miscProviders[.antigravity])
        XCTAssertNotNil(settings.miscProviders[.cursor])
    }

    func testMigrationIsIdempotent() throws {
        // Encoding then decoding a freshly-migrated AppSettings must
        // not resurrect partial-primary misc entries.
        let initialJSON = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "miscProviderInstances": [
            { "id": "gemini", "tool": "gemini", "isVisible": true, "isDefault": true, "settings": {} }
          ]
        }
        """
        let firstPass = try JSONDecoder().decode(AppSettings.self, from: Data(initialJSON.utf8))
        let reencoded = try JSONEncoder().encode(firstPass)
        let secondPass = try JSONDecoder().decode(AppSettings.self, from: reencoded)

        XCTAssertFalse(secondPass.miscProviderInstances.contains { $0.tool == .gemini })
        XCTAssertFalse(secondPass.miscProviderInstances.contains { $0.tool == .antigravity })
    }
}
