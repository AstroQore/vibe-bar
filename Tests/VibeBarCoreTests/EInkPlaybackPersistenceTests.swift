import XCTest
@testable import VibeBarCore

/// Round 1 stored "seconds per slide" *inside* the carousel case, so switching
/// to One slide and back put 300 back. Round 2 stores the mode and the cadence
/// as independent fields; these are the tests that say so.
final class EInkPlaybackPersistenceTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func roundTrip(_ device: EInkDeviceConfig) throws -> EInkDeviceConfig {
        try JSONDecoder().decode(EInkDeviceConfig.self, from: try encoder().encode(device))
    }

    func testSwitchingToOneSlideAndBackKeepsTheSecondsPerSlide() {
        var device = EInkDeviceConfig(deviceID: "panel-1")
        device.playbackMode = .appTimer
        device.secondsPerSlide = 45
        device.playbackMode = .single
        device.singleSlideID = "slide-2"
        XCTAssertEqual(device.secondsPerSlide, 45)
        device.playbackMode = .deviceLoop
        XCTAssertEqual(device.secondsPerSlide, 45)
        XCTAssertEqual(device.playback, .carousel(driver: .deviceLoop, secondsPerSlide: 45))
        // And the slide the single mode was on is still there to come back to.
        device.playbackMode = .single
        XCTAssertEqual(device.playback, .single(slideID: "slide-2"))
    }

    func testTheLegacyPlaybackEnumStillDecodesIntoTheNewFields() throws {
        let legacy = Data("""
        {"deviceID":"panel-1","alias":"","enabled":true,"orientation":0,
         "playback":{"kind":"carousel","driver":"appTimer","secondsPerSlide":600},
         "dataRefreshMinutes":15,"batteryRefreshMinutes":90,"taskKeys":[],"slides":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(EInkDeviceConfig.self, from: legacy)
        XCTAssertEqual(decoded.playbackMode, .appTimer)
        XCTAssertEqual(decoded.secondsPerSlide, 600)
        XCTAssertEqual(decoded.batteryRefreshMinutes, 90)
    }

    func testALegacySingleSlideKeepsItsSlideAndGetsTheDefaultCadence() throws {
        let legacy = Data("""
        {"deviceID":"panel-1","playback":{"kind":"single","slideID":"slide-7"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(EInkDeviceConfig.self, from: legacy)
        XCTAssertEqual(decoded.playbackMode, .single)
        XCTAssertEqual(decoded.singleSlideID, "slide-7")
        XCTAssertEqual(decoded.secondsPerSlide, EInkDeviceConfig.defaultSecondsPerSlide)
    }

    /// A file written by round 2 and read by round 1 must still work, so both
    /// shapes go out. The new keys win on the way back in.
    func testTheNewFieldsWinOverTheLegacyEnumOnDecode() throws {
        let mixed = Data("""
        {"deviceID":"panel-1",
         "playback":{"kind":"single","slideID":"old"},
         "playbackMode":"deviceLoop","secondsPerSlide":77,"singleSlideID":"new"}
        """.utf8)
        let decoded = try JSONDecoder().decode(EInkDeviceConfig.self, from: mixed)
        XCTAssertEqual(decoded.playbackMode, .deviceLoop)
        XCTAssertEqual(decoded.secondsPerSlide, 77)
        XCTAssertEqual(decoded.singleSlideID, "new")
    }

    func testTheBatteryCadenceRoundTripsThroughSettings() throws {
        var settings = AppSettings.default
        var device = EInkDeviceConfig(deviceID: "panel-1")
        device.batteryRefreshMinutes = 240
        device.dataRefreshMinutes = 3
        device.secondsPerSlide = 20
        settings.einkSync = EInkSyncSettings(apiKeyPresent: true, syncEnabled: true, devices: [device])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: try encoder().encode(settings))
        let stored = try XCTUnwrap(decoded.einkSync.devices.first)
        XCTAssertEqual(stored.batteryRefreshMinutes, 240)
        XCTAssertEqual(stored.dataRefreshMinutes, 3)
        XCTAssertEqual(stored.secondsPerSlide, 20)
    }

    func testTheThreeCadencesClampToTheirRanges() {
        var device = EInkDeviceConfig(deviceID: "panel-1")
        device.dataRefreshMinutes = 0
        device.batteryRefreshMinutes = 100_000
        device.secondsPerSlide = 1
        var clamped = device.sanitized
        XCTAssertEqual(clamped.dataRefreshMinutes, 1)
        XCTAssertEqual(clamped.batteryRefreshMinutes, 1440)
        XCTAssertEqual(clamped.secondsPerSlide, 10)

        device.dataRefreshMinutes = 5_000
        device.batteryRefreshMinutes = 0
        device.secondsPerSlide = 999_999
        clamped = device.sanitized
        XCTAssertEqual(clamped.dataRefreshMinutes, 1440)
        XCTAssertEqual(clamped.batteryRefreshMinutes, 1)
        XCTAssertEqual(clamped.secondsPerSlide, 86_400)
    }

    func testTheRangesAreTheOnesTheSettingsPaneWillOffer() {
        XCTAssertEqual(EInkDeviceConfig.minimumDataRefreshMinutes, 1)
        XCTAssertEqual(EInkDeviceConfig.maximumDataRefreshMinutes, 1440)
        XCTAssertEqual(EInkDeviceConfig.minimumBatteryRefreshMinutes, 1)
        XCTAssertEqual(EInkDeviceConfig.maximumBatteryRefreshMinutes, 1440)
        XCTAssertEqual(EInkPlayback.minimumSecondsPerSlide, 10)
        XCTAssertEqual(EInkPlayback.maximumSecondsPerSlide, 86_400)
    }

    // MARK: - Alerts, tap link, quiet hours

    func testAlertsDefaultToOnAtTenPercentAndClamp() {
        XCTAssertTrue(EInkAlertConfig().enabled)
        XCTAssertEqual(EInkAlertConfig().thresholdPercent, 10)
        XCTAssertEqual(EInkAlertConfig(enabled: true, thresholdPercent: 0).sanitized.thresholdPercent, 1)
        XCTAssertEqual(EInkAlertConfig(enabled: true, thresholdPercent: 500).sanitized.thresholdPercent, 99)
    }

    /// A tap link ends up on a phone, so it is HTTPS only and never carries
    /// credentials.
    func testTapLinksAreHTTPSOnlyAndNeverCarryCredentials() {
        XCTAssertNil(EInkTapLink.none.url(remoteDashboard: URL(string: "https://example.com")))
        XCTAssertEqual(
            EInkTapLink.remoteDashboard.url(remoteDashboard: URL(string: "https://example.com")),
            URL(string: "https://example.com")
        )
        XCTAssertNil(EInkTapLink.remoteDashboard.url(remoteDashboard: nil), "no workspace, no link")
        XCTAssertNil(EInkTapLink.custom("http://example.com").url(remoteDashboard: nil))
        XCTAssertNil(EInkTapLink.custom("https://user:secret@example.com").url(remoteDashboard: nil))
        XCTAssertNil(EInkTapLink.custom("javascript:alert(1)").url(remoteDashboard: nil))
        XCTAssertEqual(
            EInkTapLink.custom(" https://example.com/panel ").url(remoteDashboard: nil),
            URL(string: "https://example.com/panel")
        )
    }

    func testQuietHoursOnlyAcceptsAWholeHourMinutePair() {
        XCTAssertEqual(EInkQuietHours.normalized("7:5"), "07:05")
        XCTAssertEqual(EInkQuietHours.normalized("23:00"), "23:00")
        XCTAssertNil(EInkQuietHours.normalized("24:00"))
        XCTAssertNil(EInkQuietHours.normalized("22:60"))
        XCTAssertNil(EInkQuietHours.normalized("late"))
        XCTAssertEqual(EInkQuietHours(enabled: true, start: "bad", end: "bad").sanitized.start, "23:00")
    }

    func testAlertsTapLinkAndQuietHoursRoundTrip() throws {
        var device = EInkDeviceConfig(deviceID: "panel-1")
        device.alerts = EInkAlertConfig(enabled: false, thresholdPercent: 25)
        device.tapLink = .custom("https://example.com/panel")
        device.quietHours = EInkQuietHours(enabled: true, start: "22:30", end: "06:15")
        let decoded = try roundTrip(device)
        XCTAssertEqual(decoded.alerts, device.alerts)
        XCTAssertEqual(decoded.tapLink, device.tapLink)
        XCTAssertEqual(decoded.quietHours, device.quietHours)
    }
}
