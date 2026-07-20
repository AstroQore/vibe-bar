import XCTest
@testable import VibeBarCore

final class AppSettingsTests: XCTestCase {
    func testOldSettingsDecodeWithDefaultClaudeUsageMode() throws {
        let json = """
        {
          "displayMode": "remaining",
          "showEmail": false,
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.codexUsageMode, .auto)
        XCTAssertEqual(settings.claudeUsageMode, .auto)
        XCTAssertEqual(settings.menuBarItems.count, MenuBarItemKind.allCases.count)
        XCTAssertEqual(settings.menuBarItem(.compact).layout, .iconOnly)
        XCTAssertFalse(settings.menuBarItem(.compact).showTitle)
        XCTAssertTrue(settings.menuBarItem(.compact).selectedFieldIds.contains("codex.five_hour"))
        XCTAssertTrue(settings.menuBarItem(.compact).selectedFieldIds.contains("codex.weekly"))
        XCTAssertTrue(settings.menuBarItem(.compact).selectedFieldIds.contains("claude.weekly"))
        XCTAssertEqual(settings.popoverDensity, .regular)
        XCTAssertEqual(settings.miniWindow.displayMode, .regular)
        XCTAssertTrue(settings.miniWindow.selectedFieldIds.contains("claude.weekly"))
        XCTAssertTrue(settings.miniWindow.compactSelectedFieldIds.contains("claude.weekly"))
        XCTAssertTrue(settings.miniWindow.selectedFieldIds.contains("claude.daily_routines"))
        XCTAssertNil(settings.miniWindow.customLabels["codex.five_hour"])
        XCTAssertEqual(settings.visibleCoreProviders, AppSettings.defaultVisibleCoreProviders)
        XCTAssertEqual(settings.costData.retentionDays, CostDataSettings.defaultRetentionDays)
        XCTAssertEqual(settings.costData.retentionDays, CostDataSettings.unlimitedRetentionDays)
        XCTAssertFalse(settings.costData.privacyModeEnabled)
    }

    func testMenuBarFieldLabelsRoundTrip() throws {
        var settings = AppSettings.default
        var compact = settings.menuBarItem(.compact)
        compact.customLabels["codex.weekly"] = "ow"
        compact.selectedFieldIds = ["codex.weekly"]
        compact.layout = .singleLine
        settings.setMenuBarItem(compact)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.menuBarItem(.compact).customLabels["codex.weekly"], "ow")
        XCTAssertEqual(decoded.menuBarItem(.compact).selectedFieldIds, ["codex.weekly"])
        XCTAssertEqual(decoded.menuBarItem(.compact).layout, .singleLine)
    }

    /// Old configs persisted before Gemini removal include {"kind":"gemini",...}
    /// in their menuBarItems array. The lossy decoder must drop those entries
    /// without throwing the entire AppSettings decode.
    func testLegacyGeminiMenuItemDoesNotBreakDecode() throws {
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "claudeUsageMode": "cliThenWeb",
          "menuBarItems": [
            { "kind": "gemini", "isVisible": true, "showTitle": true, "selectedFieldIds": ["gemini.gemini_pro"] },
            { "kind": "claude", "isVisible": true, "showTitle": true, "selectedFieldIds": ["claude.weekly"] }
          ]
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        // Retired standalone provider items are silently dropped and the
        // single Overview item is restored from defaults.
        XCTAssertEqual(settings.menuBarItems.map(\.kind), [.compact])
        XCTAssertTrue(settings.menuBarItem(.compact).selectedFieldIds.contains("claude.weekly"))
    }

    func testClaudeWebThenCliModeRoundTrip() throws {
        var settings = AppSettings.default
        settings.claudeUsageMode = .webThenCli

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.claudeUsageMode, .webThenCli)
        XCTAssertEqual(ClaudeUsageMode.webThenCli.label, "Claude Web, then Claude Code")
    }

    func testMiniWindowSettingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.miniWindow.displayMode = .compact
        settings.miniWindow.selectedFieldIds = ["claude.weekly_design"]
        settings.miniWindow.compactSelectedFieldIds = ["claude.daily_routines"]
        settings.miniWindow.customLabels["claude.weekly_design"] = "Design"
        settings.miniWindow.groupLabels["claude.design"] = "Design-ish"
        settings.miniWindow.wasOpen = true
        settings.miniWindow.savedOriginX = 42.5
        settings.miniWindow.savedOriginY = 100.0
        settings.miniWindow.savedPixelOriginX = 85.0
        settings.miniWindow.savedPixelOriginY = 200.0
        settings.miniWindow.savedScreenScale = 2.0

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.miniWindow.selectedFieldIds, ["claude.weekly_design"])
        XCTAssertEqual(decoded.miniWindow.compactSelectedFieldIds, ["claude.daily_routines"])
        XCTAssertEqual(decoded.miniWindow.displayMode, .compact)
        XCTAssertEqual(decoded.miniWindow.customLabels["claude.weekly_design"], "Design")
        XCTAssertEqual(decoded.miniWindow.groupLabels["claude.design"], "Design-ish")
        XCTAssertTrue(decoded.miniWindow.wasOpen)
        XCTAssertEqual(decoded.miniWindow.savedOriginX, 42.5)
        XCTAssertEqual(decoded.miniWindow.savedOriginY, 100.0)
        XCTAssertEqual(decoded.miniWindow.savedPixelOriginX, 85.0)
        XCTAssertEqual(decoded.miniWindow.savedPixelOriginY, 200.0)
        XCTAssertEqual(decoded.miniWindow.savedScreenScale, 2.0)
    }

    /// Pre-restoration legacy settings won't have the new wasOpen/savedOrigin
    /// fields. We must default them sensibly (closed, no saved position).
    func testMiniWindowDecodesLegacyWithoutWasOpen() throws {
        let json = """
        {
          "selectedFieldIds": ["codex.five_hour"],
          "customLabels": {}
        }
        """
        let decoded = try JSONDecoder().decode(MiniWindowSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.selectedFieldIds, ["codex.five_hour"])
        XCTAssertEqual(decoded.compactSelectedFieldIds, ["codex.five_hour"])
        XCTAssertEqual(decoded.displayMode, .regular)
        XCTAssertTrue(decoded.groupLabels.isEmpty)
        XCTAssertFalse(decoded.wasOpen)
        XCTAssertNil(decoded.savedOriginX)
        XCTAssertNil(decoded.savedOriginY)
        XCTAssertNil(decoded.savedPixelOriginX)
        XCTAssertNil(decoded.savedPixelOriginY)
        XCTAssertNil(decoded.savedScreenScale)
    }

    func testMiniWindowMigratesLegacyAntigravityFields() throws {
        let json = """
        {
          "selectedFieldIds": [
            "antigravity.gemini-3-flash",
            "antigravity.gemini-2.5-flash",
            "antigravity.gemini-3-pro",
            "antigravity.claude-sonnet-4-5",
            "antigravity.gemini-2.5-flash-lite"
          ],
          "compactSelectedFieldIds": [
            "antigravity.claude-sonnet-4-20250514",
            "antigravity.gemini-2.5-pro"
          ],
          "customLabels": {}
        }
        """
        let decoded = try JSONDecoder().decode(MiniWindowSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.selectedFieldIds, [
            "antigravity.gemini_five_hour",
            "antigravity.claude_gpt_five_hour"
        ])
        XCTAssertEqual(decoded.compactSelectedFieldIds, [
            "antigravity.claude_gpt_five_hour",
            "antigravity.gemini_five_hour"
        ])
    }

    func testMenuBarItemMigratesLegacyAntigravityFields() throws {
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "menuBarItems": [
            {
              "kind": "compact",
              "isVisible": true,
              "showTitle": false,
              "layout": "twoRows",
              "selectedFieldIds": [
                "antigravity.gemini-3-flash",
                "antigravity.claude-sonnet-4-20250514"
              ],
              "customLabels": {}
            }
          ]
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        let compact = settings.menuBarItem(.compact)

        XCTAssertEqual(compact.selectedFieldIds, [
            "antigravity.gemini_five_hour",
            "antigravity.claude_gpt_five_hour"
        ])
    }

    func testOldCompactDefaultMigratesToOverviewIconOnly() throws {
        let json = """
        {
          "displayMode": "remaining",
          "showEmail": false,
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": false,
          "claudeUsageMode": "cliThenWeb",
          "menuBarItems": [
            {
              "kind": "compact",
              "isVisible": true,
              "showTitle": true,
              "selectedFieldIds": ["codex.five_hour", "codex.weekly", "claude.five_hour", "claude.weekly"],
              "customLabels": {
                "codex.five_hour": "O5h",
                "codex.weekly": "Owk",
                "claude.five_hour": "C5h",
                "claude.weekly": "Cwk"
              }
            }
          ]
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        let compact = settings.menuBarItem(.compact)

        XCTAssertEqual(compact.layout, .iconOnly)
        XCTAssertFalse(compact.showTitle)
        XCTAssertNil(compact.customLabels["codex.five_hour"])
        XCTAssertNil(compact.customLabels["codex.weekly"])
    }

    func testMockDataIsForcedOffWhenDecodingPersistedSettings() throws {
        let json = """
        {
          "displayMode": "remaining",
          "refreshIntervalSeconds": 600,
          "launchAtLogin": false,
          "menuBarTextEnabled": true,
          "mockEnabled": true
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.mockEnabled)
    }

    func testCostDataSettingsRoundTripAndNormalizeRetention() throws {
        var settings = AppSettings.default
        settings.costData = CostDataSettings(retentionDays: 10_000, privacyModeEnabled: true)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.costData.retentionDays, CostDataSettings.maximumRetentionDays)
        XCTAssertTrue(decoded.costData.privacyModeEnabled)
    }

    func testOverviewMenuItemAndCompactLayoutDefaults() {
        XCTAssertEqual(MenuBarItemKind.compact.label, "Overview")
        XCTAssertEqual(MenuBarLayout.compact.label, "Compact")
        XCTAssertTrue(MenuBarLayout.allCases.contains(.compact))

        let overview = AppSettings.default.menuBarItem(.compact)
        XCTAssertEqual(overview.kind, .compact)
        XCTAssertEqual(overview.layout, .iconOnly)
        XCTAssertFalse(overview.showTitle)

        XCTAssertTrue(AppSettings.default.menuBarItem(.compact).isVisible)
        XCTAssertEqual(MenuBarItemKind.allCases, [.compact])
        XCTAssertEqual(AppSettings.default.menuBarItems.count, 1)
        XCTAssertEqual(AppSettings.default.menuBarItems.filter(\.isVisible).map(\.kind), [.compact])
        XCTAssertTrue(overview.customLabels.isEmpty)
    }

    func testMenuBarCompactLayoutRoundTrip() throws {
        var settings = AppSettings.default
        var overview = settings.menuBarItem(.compact)
        overview.layout = .compact
        settings.setMenuBarItem(overview)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.menuBarItem(.compact).layout, .compact)
    }

    func testMenuBarIconOnlyLayoutRoundTrip() throws {
        var settings = AppSettings.default
        var overview = settings.menuBarItem(.compact)
        overview.layout = .iconOnly
        settings.setMenuBarItem(overview)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.menuBarItem(.compact).layout, .iconOnly)
    }

    func testGlobalPopoverDensityRoundTrips() throws {
        var settings = AppSettings.default
        settings.popoverDensity = .spacious

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.popoverDensity, .spacious)
    }

    func testLegacyPerItemDensitiesUseOverviewValue() throws {
        let json = """
        {
          "popoverDensities": {
            "compact": "compact",
            "codex": "spacious",
            "claude": "regular",
            "status": "spacious"
          }
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.popoverDensity, .compact)
    }

    func testOnlyIconOnlyLayoutShowsMenuBarIcon() {
        XCTAssertTrue(MenuBarLayout.iconOnly.showsMenuBarIcon)
        XCTAssertFalse(MenuBarLayout.singleLine.showsMenuBarIcon)
        XCTAssertFalse(MenuBarLayout.twoRows.showsMenuBarIcon)
        XCTAssertFalse(MenuBarLayout.compact.showsMenuBarIcon)
    }

    func testProviderPlanLabelsDefaultToAutoAndNormalizeProviderPlans() {
        let settings = AppSettings.default

        XCTAssertNil(settings.planBadgeLabel(for: .codex))
        XCTAssertEqual(settings.planBadgeLabel(for: .codex, quotaPlan: "prolite"), "Pro Lite")
        XCTAssertEqual(settings.planBadgeLabel(for: .codex, accountPlan: "self_serve_business_usage_based"), "Self Serve Business Usage Based")
        XCTAssertEqual(settings.planBadgeLabel(for: .claude, quotaPlan: "default_claude_max_20x"), "Max")
        XCTAssertEqual(settings.planBadgeLabel(for: .claude, accountPlan: "Claude Pro Account"), "Pro")
    }

    func testProviderPlanLabelOverrideWinsAndRoundTrips() throws {
        var settings = AppSettings.default
        settings.setProviderPlanLabel("Founder", for: .codex)

        XCTAssertEqual(settings.planBadgeLabel(for: .codex, quotaPlan: "pro"), "Founder")

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.planBadgeLabel(for: .codex, quotaPlan: "pro"), "Founder")
    }

    func testProviderPlanLabelOverrideDropsCredentialLikeValues() {
        var settings = AppSettings.default
        settings.setProviderPlanLabel("sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789", for: .codex)

        XCTAssertNil(settings.planBadgeLabel(for: .codex))
    }

    func testCoreProviderVisibilityGroupsGeminiAndAntigravityAndRoundTrips() throws {
        var settings = AppSettings.default

        settings.setCoreProviderVisible(false, for: .antigravity)

        XCTAssertFalse(settings.isCoreProviderVisible(.gemini))
        XCTAssertFalse(settings.isCoreProviderVisible(.antigravity))
        XCTAssertTrue(settings.isCoreProviderVisible(.codex))

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(decoded.isCoreProviderVisible(.gemini))
        XCTAssertFalse(decoded.isCoreProviderVisible(.antigravity))
        XCTAssertEqual(
            decoded.visibleCoreProviders,
            Set([.codex, .claude, .grok])
        )
    }

    func testCoreProviderVisibilityDropsNonCoreValues() throws {
        let json = """
        {
          "visibleCoreProviders": ["codex", "antigravity", "minimax", "removedProvider"]
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.visibleCoreProviders, Set([.codex, .gemini]))
    }
}
