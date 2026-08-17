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
        XCTAssertEqual(settings.coreProviderOrder, AppSettings.defaultCoreProviderOrder)
        XCTAssertEqual(settings.costData.retentionDays, CostDataSettings.defaultRetentionDays)
        XCTAssertEqual(settings.costData.retentionDays, CostDataSettings.unlimitedRetentionDays)
        XCTAssertFalse(settings.costData.privacyModeEnabled)
        XCTAssertEqual(settings.updateChannel, .main)
        XCTAssertTrue(settings.remoteCostIncludedMachineIDs.isEmpty)
    }

    func testRemoteCostMachineSelectionDefaultsEmptyNormalizesAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertTrue(legacy.remoteCostIncludedMachineIDs.isEmpty)

        var settings = AppSettings.default
        settings.remoteCostIncludedMachineIDs = [
            "11111111-1111-4111-8111-111111111111:AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        ]
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(
            decoded.remoteCostIncludedMachineIDs,
            ["11111111-1111-4111-8111-111111111111:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        )
    }

    func testMiscCookieAutoImportDefaultsToOffAndRoundTrips() throws {
        // Must decode to `false` for a settings file written before the
        // toggle existed: opening an old config with a newer build cannot
        // be what starts background browser / Keychain reads.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertFalse(legacy.miscCookieAutoImportEnabled)
        XCTAssertFalse(AppSettings.default.miscCookieAutoImportEnabled)

        var settings = AppSettings.default
        settings.miscCookieAutoImportEnabled = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.miscCookieAutoImportEnabled)
    }

    func testMenuBarBlockAlertSuppressionDefaultsToOffAndRoundTrips() throws {
        // A settings file written before the self-check existed must leave the
        // check armed — silence about a blocked menu bar item is the failure
        // mode this whole feature exists to end.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertFalse(legacy.menuBarBlockAlertSuppressed)
        XCTAssertFalse(AppSettings.default.menuBarBlockAlertSuppressed)

        var settings = AppSettings.default
        settings.menuBarBlockAlertSuppressed = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.menuBarBlockAlertSuppressed)
    }

    func testMenuBarColorBasisDefaultsToForecastAndRoundTrips() throws {
        // Deliberately the opposite of the usual "absent key keeps the old
        // behavior" rule: forecast coloring is the intended menu-bar reading,
        // so a settings file written before the picker existed has to adopt it
        // on upgrade. The picker exists to opt *back* into raw thresholds.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertEqual(legacy.menuBarColorBasis, .forecast)
        XCTAssertEqual(AppSettings.default.menuBarColorBasis, .forecast)

        var settings = AppSettings.default
        settings.menuBarColorBasis = .actual
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.menuBarColorBasis, .actual)
    }

    func testSessionPreferencesDefaultAndRoundTrip() throws {
        // A settings file written before the Sessions page existed has to
        // land on the shipping behavior: Terminal.app, bodies indexed.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertEqual(legacy.preferredTerminal, .terminal)
        XCTAssertTrue(legacy.sessionBodyIndexingEnabled)
        XCTAssertEqual(AppSettings.default.preferredTerminal, .terminal)
        XCTAssertTrue(AppSettings.default.sessionBodyIndexingEnabled)

        var settings = AppSettings.default
        settings.preferredTerminal = .iterm2
        settings.sessionBodyIndexingEnabled = false
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.preferredTerminal, .iterm2)
        XCTAssertFalse(decoded.sessionBodyIndexingEnabled)
    }

    func testUnknownPreferredTerminalFallsBackWithoutFailingTheFile() throws {
        // Same rule the color-basis picker follows: an unknown raw value
        // costs the user this one preference, not every other setting.
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining","preferredTerminal":"kitty"}"#.utf8)
        )
        XCTAssertEqual(settings.preferredTerminal, .terminal)
        XCTAssertEqual(settings.displayMode, .remaining)
    }

    func testUnknownMenuBarColorBasisFallsBackWithoutFailingTheFile() throws {
        // A hand-edited or downgraded raw value must cost the user this one
        // preference, not every other setting in the file.
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"used","menuBarColorBasis":"vibes"}"#.utf8)
        )
        XCTAssertEqual(settings.menuBarColorBasis, .forecast)
        XCTAssertEqual(settings.displayMode, .used)
    }

    func testSkillsSyncMethodDefaultsToAutoAndRoundTrips() throws {
        // `.auto` links where it can and copies where it cannot, which is the
        // only value that keeps every agent CLI reading one copy of a skill —
        // so a settings file written before the Skills manager existed has to
        // decode to it, and so does a raw value this build does not know.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertEqual(legacy.skillsSyncMethod, .auto)
        XCTAssertEqual(AppSettings.default.skillsSyncMethod, .auto)

        var settings = AppSettings.default
        settings.skillsSyncMethod = .copy
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.skillsSyncMethod, .copy)

        let unknown = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"used","skillsSyncMethod":"hardlink"}"#.utf8)
        )
        XCTAssertEqual(unknown.skillsSyncMethod, .auto)
        XCTAssertEqual(unknown.displayMode, .used)
    }

    func testOverviewQuotaHistoryHiddenCurvesDefaultToNoneAndRoundTrip() throws {
        // Stored as *hidden* ids, so a settings file written before the
        // Overview chart existed has to mean "show everything" — not "show
        // nothing", which is what a visible-id list would have decoded to.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertTrue(legacy.overviewQuotaHistoryHiddenCurveIds.isEmpty)
        XCTAssertTrue(AppSettings.default.overviewQuotaHistoryHiddenCurveIds.isEmpty)

        var settings = AppSettings.default
        settings.overviewQuotaHistoryHiddenCurveIds = [
            "claude|account-1|weekly_fable",
            "codex|account-2|five_hour"
        ]
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(
            decoded.overviewQuotaHistoryHiddenCurveIds,
            ["claude|account-1|weekly_fable", "codex|account-2|five_hour"]
        )
    }

    func testPageLayoutsDefaultToNoneAndRoundTrip() throws {
        // A settings file written before the layout editor existed means "no
        // page has been customized", which is exactly an empty map — every
        // page keeps its built-in arrangement, no migration needed.
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertTrue(legacy.pageLayouts.isEmpty)
        XCTAssertTrue(AppSettings.default.pageLayouts.isEmpty)

        var settings = AppSettings.default
        settings.pageLayouts[.overview] = StoredPageLayout(
            ratio: .wideNarrow,
            columns: [[.status, .costAll], [.quotaHistoryAll]]
        )
        settings.pageLayouts[.detail(.claude)] = StoredPageLayout(
            ratio: .narrowWide,
            columns: [[.quotaGroup(tool: .claude, groupKey: "all")], [.cost(tool: .claude)]]
        )

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.pageLayouts.count, 2)
        XCTAssertEqual(decoded.pageLayouts[.overview]?.ratio, .wideNarrow)
        XCTAssertEqual(decoded.pageLayouts[.overview]?.columns, [[.status, .costAll], [.quotaHistoryAll]])
        XCTAssertEqual(
            decoded.pageLayouts[.detail(.claude)]?.columns,
            [[.quotaGroup(tool: .claude, groupKey: "all")], [.cost(tool: .claude)]]
        )
    }

    func testPageLayoutModesRoundTripPerPage() throws {
        var settings = AppSettings.default
        settings.pageLayouts[.overview] = StoredPageLayout(mode: .compact, ratio: .wideNarrow)
        settings.pageLayouts[.detail(.claude)] = StoredPageLayout(
            mode: .manual,
            ratio: .narrowWide,
            columns: [[.quotaGroup(tool: .claude, groupKey: "all")], [.cost(tool: .claude)]]
        )
        settings.pageLayouts[.detail(.codex)] = StoredPageLayout(
            mode: .auto,
            ratio: .equal,
            columns: [[.status], [.cost(tool: .codex)]]
        )

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.pageLayouts[.overview]?.mode, .compact)
        XCTAssertEqual(decoded.pageLayouts[.overview]?.ratio, .wideNarrow)
        XCTAssertEqual(decoded.pageLayouts[.detail(.claude)]?.mode, .manual)
        // An `auto` page keeps the arrangement it had before the switch, so
        // going back to Manual restores it instead of starting over.
        XCTAssertEqual(decoded.pageLayouts[.detail(.codex)]?.mode, .auto)
        XCTAssertEqual(
            decoded.pageLayouts[.detail(.codex)]?.columns,
            [[.status], [.cost(tool: .codex)]]
        )
    }

    func testLayoutsSavedBeforeModesExistedComeBackAsManual() throws {
        // The upgrade path that matters: a settings file from the build that
        // shipped the drag editor has no `mode` key anywhere, and every entry
        // in it is an arrangement the user made by hand.
        let json = #"""
        {
          "displayMode": "remaining",
          "pageLayouts": {
            "overview": {"ratio": "equal", "columns": [["status", "cost-all"], ["quota-history-all"]]},
            "detail:claude": {"ratio": "narrow-wide", "columns": [[], []]}
          }
        }
        """#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.pageLayouts[.overview]?.mode, .manual)
        XCTAssertEqual(
            decoded.pageLayouts[.overview]?.columns,
            [[.status, .costAll], [.quotaHistoryAll]]
        )
        // An entry with no arrangement was never a customization to begin with.
        XCTAssertEqual(decoded.pageLayouts[.detail(.claude)]?.mode, .auto)
    }

    func testPageLayoutPresetsDefaultToNoneAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertTrue(legacy.pageLayoutPresets.isEmpty)
        XCTAssertTrue(AppSettings.default.pageLayoutPresets.isEmpty)

        var settings = AppSettings.default
        settings.pageLayoutPresets[.overview] = [
            StoredPageLayoutPreset(
                name: "Cost on the left",
                layout: StoredPageLayout(
                    mode: .manual,
                    ratio: .wideNarrow,
                    columns: [[.costAll], [.status, .quotaHistoryAll]]
                )
            ),
            StoredPageLayoutPreset(
                name: "Shortest",
                layout: StoredPageLayout(mode: .compact, ratio: .equal)
            )
        ]

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        let presets = try XCTUnwrap(decoded.pageLayoutPresets[.overview])
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets.map(\.name), ["Cost on the left", "Shortest"])
        XCTAssertEqual(presets[0].layout.ratio, .wideNarrow)
        XCTAssertEqual(presets[0].layout.columns, [[.costAll], [.status, .quotaHistoryAll]])
        XCTAssertEqual(presets[1].layout.mode, .compact)
    }

    func testPageLayoutPresetsEncodeAsAPlainObjectKeyedByPage() throws {
        var settings = AppSettings.default
        settings.pageLayoutPresets[.detail(.codex)] = [
            StoredPageLayoutPreset(
                name: "Tall left",
                layout: StoredPageLayout(mode: .manual, ratio: .equal, columns: [[.status], []])
            )
        ]

        let data = try JSONEncoder().encode(settings)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let byPage = try XCTUnwrap(root["pageLayoutPresets"] as? [String: Any])
        let codex = try XCTUnwrap(byPage["detail:codex"] as? [[String: Any]])
        XCTAssertEqual(codex.count, 1)
        XCTAssertEqual(codex[0]["name"] as? String, "Tall left")
        let layout = try XCTUnwrap(codex[0]["layout"] as? [String: Any])
        XCTAssertEqual(layout["mode"] as? String, "manual")
        XCTAssertEqual(layout["columns"] as? [[String]], [["status"], []])
    }

    func testPageLayoutPresetsAreNormalizedOnTheWayIn() {
        var settings = AppSettings.default
        settings.pageLayoutPresets = [
            .overview: [
                StoredPageLayoutPreset(name: "  Keep  ", layout: StoredPageLayout()),
                // Unnamed presets cannot be picked out of a menu.
                StoredPageLayoutPreset(name: "   ", layout: StoredPageLayout()),
                // A name that differs only by case is the same menu entry.
                StoredPageLayoutPreset(name: "keep", layout: StoredPageLayout(ratio: .wideNarrow))
            ],
            .detail(.claude): []
        ]

        let normalized = AppSettings(
            displayMode: .remaining,
            refreshIntervalSeconds: 600,
            launchAtLogin: false,
            menuBarTextEnabled: true,
            mockEnabled: false,
            pageLayoutPresets: settings.pageLayoutPresets
        )

        XCTAssertEqual(normalized.pageLayoutPresets[.overview]?.map(\.name), ["Keep"])
        // A page with nothing left keeps no empty entry.
        XCTAssertNil(normalized.pageLayoutPresets[.detail(.claude)])
    }

    func testPageLayoutPresetsAreCappedPerPage() {
        let tooMany = (0..<(AppSettings.maximumPresetsPerPage + 8)).map { index in
            StoredPageLayoutPreset(name: "preset-\(index)", layout: StoredPageLayout())
        }
        let normalized = AppSettings(
            displayMode: .remaining,
            refreshIntervalSeconds: 600,
            launchAtLogin: false,
            menuBarTextEnabled: true,
            mockEnabled: false,
            pageLayoutPresets: [.overview: tooMany]
        )

        XCTAssertEqual(
            normalized.pageLayoutPresets[.overview]?.count,
            AppSettings.maximumPresetsPerPage
        )
        // The cap keeps the oldest, so saving more never reshuffles the menu.
        XCTAssertEqual(normalized.pageLayoutPresets[.overview]?.first?.name, "preset-0")
    }

    func testMangledPageLayoutPresetsDoNotCostTheRestOfTheSettings() throws {
        let json = #"""
        {"displayMode": "used", "refreshIntervalSeconds": 1800, "pageLayoutPresets": "not-an-object"}
        """#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.pageLayoutPresets.isEmpty)
        XCTAssertEqual(decoded.displayMode, .used)
        XCTAssertEqual(decoded.refreshIntervalSeconds, 1800)
    }

    func testPageLayoutPresetsSurviveUnknownPagesAndModules() throws {
        let json = #"""
        {
          "displayMode": "remaining",
          "pageLayoutPresets": {
            "detail:some-future-provider": [
              {"name": "From v9", "layout": {"mode": "manual", "ratio": "equal", "columns": [["future-card:v9"], []]}}
            ]
          }
        }
        """#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        let presets = try XCTUnwrap(
            decoded.pageLayoutPresets[PageLayoutPageID("detail:some-future-provider")]
        )
        XCTAssertEqual(presets.first?.name, "From v9")
        XCTAssertEqual(presets.first?.layout.columns.first, [PageLayoutModuleID("future-card:v9")])
    }

    func testPageLayoutsEncodeAsAPlainObjectKeyedByPageAndModuleIdentifiers() throws {
        var settings = AppSettings.default
        settings.pageLayouts[.detail(.codex)] = StoredPageLayout(
            ratio: .equal,
            columns: [[.status], [.cost(tool: .codex)]]
        )

        let data = try JSONEncoder().encode(settings)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let layouts = try XCTUnwrap(root["pageLayouts"] as? [String: Any])
        let codex = try XCTUnwrap(layouts["detail:codex"] as? [String: Any])
        XCTAssertEqual(codex["ratio"] as? String, "equal")
        XCTAssertEqual(codex["columns"] as? [[String]], [["status"], ["cost:codex"]])
        // Measured heights are render telemetry and stay in layout.json.
        XCTAssertNil(codex["measuredHeights"])
    }

    func testPageLayoutsToleratePartialAndUnknownEntries() throws {
        let json = #"""
        {
          "displayMode": "remaining",
          "pageLayouts": {
            "overview": {"columns": [["status"], []]},
            "detail:claude": {"ratio": "spiral", "columns": [["cost:claude"], []]},
            "detail:some-future-provider": {"ratio": "equal", "columns": [["future-card:v9"], []]}
          }
        }
        """#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        // Missing ratio degrades to the fallback rather than dropping the page.
        XCTAssertEqual(decoded.pageLayouts[.overview]?.ratio, .equal)
        XCTAssertEqual(decoded.pageLayouts[.overview]?.columns.first, [.status])
        // An unreadable ratio does the same.
        XCTAssertEqual(decoded.pageLayouts[.detail(.claude)]?.ratio, .equal)
        // A page and a module this build knows nothing about survive intact.
        let future = decoded.pageLayouts[PageLayoutPageID("detail:some-future-provider")]
        XCTAssertEqual(future?.columns.first, [PageLayoutModuleID("future-card:v9")])
    }

    func testAMangledPageLayoutMapDoesNotCostTheRestOfTheSettings() throws {
        // `pageLayouts` decodes with `try?`: losing a hand-mangled card
        // arrangement is acceptable, silently resetting the whole settings file
        // is not.
        let json = #"""
        {"displayMode": "used", "refreshIntervalSeconds": 1800, "pageLayouts": "not-an-object"}
        """#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.pageLayouts.isEmpty)
        XCTAssertEqual(decoded.displayMode, .used)
        XCTAssertEqual(decoded.refreshIntervalSeconds, 1800)
    }

    func testStoredPageLayoutAppliesTheConfigInvariants() {
        // A hand-edited file cannot smuggle in a duplicate or a third column:
        // the DTO round-trips through `PageLayoutConfig`'s initializer.
        let stored = StoredPageLayout(
            ratio: .equal,
            columns: [[.status, .costAll], [.status], [.quotaHistoryAll]]
        )
        XCTAssertEqual(stored.columns.count, PageLayoutConfig.columnCount)
        XCTAssertEqual(stored.columns[0], [.status, .costAll])
        XCTAssertEqual(stored.columns[1], [.quotaHistoryAll])
        XCTAssertFalse(stored.isEmpty)
        XCTAssertTrue(StoredPageLayout().isEmpty)
    }

    func testStoredPageLayoutCarriesMeasuredHeightsBackIntoTheCanonicalModel() {
        let stored = StoredPageLayout(ratio: .narrowWide, columns: [[.status], [.costAll]])
        let config = stored.config(measuredHeights: [.status: 120])

        XCTAssertEqual(config.ratio, .narrowWide)
        XCTAssertEqual(config.leftColumn, [.status])
        XCTAssertEqual(config.measuredHeight(for: .status), 120)
        // And back again, dropping the telemetry.
        XCTAssertEqual(StoredPageLayout(config), stored)
    }

    func testUpdateChannelRoundTripsAndUnknownValuesFallBackToMain() throws {
        var settings = AppSettings.default
        settings.updateChannel = .dev

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let unknown = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"updateChannel":"nightly"}"#.utf8)
        )

        XCTAssertEqual(decoded.updateChannel, .dev)
        XCTAssertEqual(decoded.updateChannel.additionalSparkleChannels, ["dev"])
        XCTAssertEqual(unknown.updateChannel, .main)
        XCTAssertTrue(unknown.updateChannel.additionalSparkleChannels.isEmpty)
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

    func testPricingSettingsRoundTripAndLegacyDefaults() throws {
        var settings = AppSettings.default
        settings.pricingRefreshIntervalSeconds = 12 * 60 * 60
        settings.modelPricingOverrides = [ModelPricingOverride(
            provider: .grok,
            model: "grok-custom",
            inputPerMillion: 3,
            outputPerMillion: 15,
            cacheReadPerMillion: 0.5
        )]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.pricingRefreshIntervalSeconds, 12 * 60 * 60)
        XCTAssertEqual(decoded.modelPricingOverrides, settings.modelPricingOverrides)

        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"displayMode":"remaining"}"#.utf8)
        )
        XCTAssertEqual(
            legacy.pricingRefreshIntervalSeconds,
            AppSettings.default.pricingRefreshIntervalSeconds
        )
        XCTAssertTrue(legacy.modelPricingOverrides.isEmpty)
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
        XCTAssertEqual(settings.planBadgeLabel(for: .codex, quotaPlan: "prolite"), "ChatGPT Pro Lite")
        XCTAssertEqual(settings.planBadgeLabel(for: .codex, accountPlan: "self_serve_business_usage_based"), "ChatGPT Self Serve Business Usage Based")
        XCTAssertEqual(settings.planBadgeLabel(for: .claude, quotaPlan: "default_claude_max_20x"), "Claude Max")
        XCTAssertEqual(settings.planBadgeLabel(for: .claude, accountPlan: "Claude Pro Account"), "Claude Pro")
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

    func testCoreProviderOrderNormalizesAliasesDuplicatesAndUnknownValues() throws {
        let json = """
        {
          "coreProviderOrder": ["grok", "antigravity", "minimax", "grok"]
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.orderedCoreProviders, [.grok, .gemini, .codex, .claude])
    }

    func testCoreProviderOrderMovesAndRoundTrips() throws {
        var settings = AppSettings.default
        settings.moveCoreProvider(.grok, before: .codex)
        settings.moveCoreProvider(.claude, before: .gemini)
        settings.setCoreProviderVisible(false, for: .codex)

        XCTAssertEqual(settings.orderedCoreProviders, [.grok, .codex, .claude, .gemini])
        XCTAssertEqual(settings.visibleCoreProviderList, [.grok, .claude, .gemini])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.orderedCoreProviders, settings.orderedCoreProviders)
        XCTAssertEqual(decoded.visibleCoreProviderList, settings.visibleCoreProviderList)
    }

    func testRefreshPreferencesRoundTrip() throws {
        var settings = AppSettings.default
        settings.refreshIntervalSeconds = 300
        settings.refreshOnPopoverOpen = true
        settings.popoverOpenRefreshCooldownSeconds = 120

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.refreshIntervalSeconds, 300)
        XCTAssertTrue(decoded.refreshOnPopoverOpen)
        XCTAssertEqual(decoded.popoverOpenRefreshCooldownSeconds, 120)
    }

    func testFiveMinuteRefreshIntervalIsNotRewrittenDuringMigration() async {
        await MainActor.run {
            var settings = AppSettings.default
            settings.refreshIntervalSeconds = 300

            XCTAssertEqual(SettingsStore.migrated(settings).refreshIntervalSeconds, 300)
        }
    }
}
