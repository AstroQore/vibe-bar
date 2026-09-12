import XCTest
@testable import VibeBarCore

final class EInkSettingsTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func testDefaultsAreEmptyAndDisabled() {
        let settings = EInkSyncSettings.default
        XCTAssertFalse(settings.apiKeyPresent)
        XCTAssertFalse(settings.syncEnabled)
        XCTAssertTrue(settings.devices.isEmpty)
    }

    func testDeviceDefaultsMatchThePlan() {
        let device = EInkDeviceConfig(deviceID: "0000AAAA0000")
        XCTAssertEqual(device.dataRefreshMinutes, 15)
        XCTAssertEqual(device.batteryRefreshMinutes, 60)
        XCTAssertEqual(device.orientation, .degrees0)
        XCTAssertEqual(device.profile.width, 296)
        XCTAssertEqual(device.profile.height, 152)
        XCTAssertEqual(device.profile.model, .quote0)
        XCTAssertFalse(device.enabled)
    }

    func testRoundTripPreservesEverySlideAndPlaybackShape() throws {
        var settings = EInkSyncSettings(apiKeyPresent: true, syncEnabled: true, devices: [])
        settings.devices = [
            EInkDeviceConfig(
                deviceID: "0000AAAA0000",
                alias: "Desk",
                enabled: true,
                orientation: .degrees270,
                playback: .carousel(driver: .deviceLoop, secondsPerSlide: 600),
                dataRefreshMinutes: 5,
                batteryRefreshMinutes: 120,
                taskKeys: ["task-key-0001", "task-key-0002"],
                slides: [
                    EInkSlide(
                        id: "a",
                        title: "Quota",
                        kind: .preset(.quotaRings),
                        quotaFieldIDs: ["claude.weekly", "codex.weekly"],
                        usagePeriods: [.today, .week]
                    ),
                    EInkSlide(id: "b", title: "Custom", kind: .custom(layoutID: "layout-1"), quotaFieldIDs: [], usagePeriods: [])
                ]
            )
        ]
        let data = try encoder().encode(settings)
        let decoded = try JSONDecoder().decode(EInkSyncSettings.self, from: data)
        XCTAssertEqual(decoded, settings.sanitized)
        XCTAssertEqual(decoded.devices.first?.playback, .carousel(driver: .deviceLoop, secondsPerSlide: 600))
        XCTAssertEqual(decoded.devices.first?.slides.last?.kind.layoutID, "layout-1")
    }

    func testEncodedKeysAreLockedDown() throws {
        let data = try encoder().encode(EInkSyncSettings(apiKeyPresent: true, syncEnabled: false, devices: [EInkDeviceConfig(deviceID: "x")]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["apiKeyPresent", "syncEnabled", "devices"])
        let device = try XCTUnwrap((object["devices"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(device.keys),
            [
                "deviceID", "alias", "profile", "enabled", "orientation", "playback",
                "playbackMode", "secondsPerSlide", "singleSlideID",
                "alerts", "tapLink", "quietHours",
                "dataRefreshMinutes", "batteryRefreshMinutes", "taskKeys", "slides"
            ]
        )
        XCTAssertEqual(device["orientation"] as? Int, 0)
    }

    func testTolerantDecodeSurvivesGarbageAndMissingFields() throws {
        let json = """
        {
          "apiKeyPresent": "yes-please",
          "devices": [
            {"deviceID": "0000AAAA0000", "orientation": 37, "playback": {"kind": "unknown"},
             "profile": {"model": "future_panel"}, "dataRefreshMinutes": 0,
             "slides": [{"id": "a", "kind": {"kind": "preset", "preset": "notARealPreset"},
                         "usagePeriods": ["today", "aeon"]}]}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(EInkSyncSettings.self, from: Data(json.utf8)).sanitized
        XCTAssertFalse(decoded.apiKeyPresent)
        let device = try XCTUnwrap(decoded.devices.first)
        XCTAssertEqual(device.orientation, .degrees0)
        XCTAssertEqual(device.playback, .single(slideID: ""))
        XCTAssertEqual(device.profile.model, .quote0)
        XCTAssertEqual(device.dataRefreshMinutes, EInkDeviceConfig.minimumDataRefreshMinutes)
        XCTAssertEqual(device.slides.first?.kind.preset, .quotaLedger)
        XCTAssertEqual(device.slides.first?.usagePeriods, [.today])
    }

    func testSanitizeDropsDuplicateDevicesSlidesAndTaskKeys() {
        let settings = EInkSyncSettings(
            devices: [
                EInkDeviceConfig(deviceID: "dup", taskKeys: ["k", "k", ""], slides: [
                    EInkSlide(id: "s", quotaFieldIDs: ["a", "a"]),
                    EInkSlide(id: "s")
                ]),
                EInkDeviceConfig(deviceID: "dup"),
                EInkDeviceConfig(deviceID: "")
            ]
        ).sanitized
        XCTAssertEqual(settings.devices.count, 1)
        XCTAssertEqual(settings.devices[0].taskKeys, ["k"])
        XCTAssertEqual(settings.devices[0].slides.count, 1)
        XCTAssertEqual(settings.devices[0].slides[0].quotaFieldIDs, ["a"])
    }

    func testCarouselSecondsAreClamped() {
        XCTAssertEqual(
            EInkPlayback.carousel(driver: .appTimer, secondsPerSlide: 1).sanitized,
            .carousel(driver: .appTimer, secondsPerSlide: EInkPlayback.minimumSecondsPerSlide)
        )
        XCTAssertEqual(
            EInkPlayback.carousel(driver: .appTimer, secondsPerSlide: 10_000_000).sanitized,
            .carousel(driver: .appTimer, secondsPerSlide: EInkPlayback.maximumSecondsPerSlide)
        )
    }

    func testPresetCapacitiesMatchTheVerifiedDemo() {
        let landscape = EInkOrientation.degrees0
        let portrait = EInkOrientation.degrees90
        XCTAssertEqual(EInkPreset.quotaLedger.capacity(for: landscape), 5)
        XCTAssertEqual(EInkPreset.quotaLedger.capacity(for: portrait), 6)
        XCTAssertEqual(EInkPreset.quotaRings.capacity(for: landscape), 5)
        XCTAssertEqual(EInkPreset.quotaRings.capacity(for: portrait), 6)
        XCTAssertEqual(EInkPreset.quotaRail.capacity(for: landscape), 5)
        XCTAssertEqual(EInkPreset.quotaRail.capacity(for: portrait), 6)
        XCTAssertEqual(EInkPreset.usageTiles.capacity(for: landscape), 4)
        XCTAssertEqual(EInkPreset.usageSplit.capacity(for: landscape), 3)
        XCTAssertEqual(EInkPreset.usageTable.capacity(for: landscape), 5)
        XCTAssertEqual(EInkPreset.usageDual.capacity(for: landscape), 4)
        XCTAssertEqual(EInkPreset.usageDual.capacity(for: portrait), 5)
        XCTAssertEqual(EInkPreset.usageTrend.capacity(for: landscape), 1)
        XCTAssertEqual(EInkPreset.briefing.capacity(for: landscape), 6)
        XCTAssertEqual(EInkPreset.briefing.capacity(for: portrait), 8)
        XCTAssertEqual(EInkPreset.forecast.capacity(for: landscape), 4)
        XCTAssertEqual(EInkPreset.resets.capacity(for: portrait), 7)
        XCTAssertEqual(EInkPreset.heatmap.capacity(for: landscape), 1)
        XCTAssertEqual(EInkPreset.topModels.rowCount(for: portrait), 7)
        XCTAssertEqual(EInkPreset.allCases.count, 14)
        XCTAssertEqual(EInkPreset.userSelectable.count, 13)
        XCTAssertFalse(EInkPreset.userSelectable.contains(.alert))
    }

    func testOrientationRotationAngles() {
        XCTAssertEqual(EInkOrientation.degrees90.cssDegrees, 90)
        XCTAssertEqual(EInkOrientation.degrees270.cssDegrees, -90)
        XCTAssertEqual(EInkOrientation.degrees180.cssDegrees, 180)
        XCTAssertTrue(EInkOrientation.degrees90.isPortrait)
        XCTAssertFalse(EInkOrientation.degrees180.isPortrait)
        let size = EInkDeviceProfile.quote0.frameSize(for: .degrees90)
        XCTAssertEqual(size.width, 152)
        XCTAssertEqual(size.height, 296)
    }

    // MARK: - AppSettings wiring

    func testAppSettingsCarriesBothTopLevelKeys() throws {
        var settings = AppSettings.default
        settings.einkSync = EInkSyncSettings(
            apiKeyPresent: true,
            syncEnabled: true,
            devices: [EInkDeviceConfig(deviceID: "0000AAAA0000", enabled: true)]
        )
        var layout = EInkCanvasLayout(profile: .quote0, orientation: .degrees90)
        layout.add(.text)
        settings.einkCanvasLayouts = ["layout-1": layout.normalized()]

        let data = try encoder().encode(settings)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["einkSync"])
        XCTAssertNotNil(object["einkCanvasLayouts"])

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.einkSync, settings.einkSync.sanitized)
        XCTAssertEqual(decoded.einkCanvasLayouts["layout-1"], layout.normalized())
    }

    func testAppSettingsWithoutEInkKeysDecodesToDefaults() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder().encode(AppSettings.default)) as? [String: Any]
        )
        object.removeValue(forKey: "einkSync")
        object.removeValue(forKey: "einkCanvasLayouts")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.einkSync, .default)
        XCTAssertTrue(decoded.einkCanvasLayouts.isEmpty)
    }

    func testAppSettingsSurvivesGarbageEInkKeys() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder().encode(AppSettings.default)) as? [String: Any]
        )
        object["einkSync"] = "not an object"
        object["einkCanvasLayouts"] = 17
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.einkSync, .default)
        XCTAssertTrue(decoded.einkCanvasLayouts.isEmpty)
        XCTAssertEqual(decoded.displayMode, AppSettings.default.displayMode)
    }

    func testCredentialStoreNamesTheDedicatedKeychainSlot() {
        XCTAssertEqual(EInkCredentialStore.service, "com.astroqore.VibeBar.eink")
        XCTAssertEqual(EInkCredentialStore.apiKeyAccount, "dot-api-key")
    }
}
