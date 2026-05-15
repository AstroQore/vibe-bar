import XCTest
@testable import VibeBarCore

final class MiscCookieSlotTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let original = MiscCookieSlot(
            cookieHeader: "kimi-auth=eyJ.example; trace=abc",
            sourceLabel: "Chrome (Default)",
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .browserImport
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MiscCookieSlot.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testOriginDecodesFromString() throws {
        let raw = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "cookieHeader": "foo=bar",
          "sourceLabel": "Manual paste",
          "importedAt": "2026-05-16T10:00:00Z",
          "origin": "manual"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let slot = try decoder.decode(MiscCookieSlot.self, from: Data(raw.utf8))
        XCTAssertEqual(slot.origin, .manual)
        XCTAssertEqual(slot.cookieHeader, "foo=bar")
    }

    func testSlotFilterFromSettings() {
        // Auto mode: all origins pass.
        let auto = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .auto, cookieSource: .auto)
        )
        XCTAssertEqual(auto, .all)
        XCTAssertTrue(auto.allows(slot(origin: .manual)))
        XCTAssertTrue(auto.allows(slot(origin: .browserImport)))
        XCTAssertTrue(auto.allows(slot(origin: .autoRefresh)))

        // Auto with cookieSource = manual collapses to manualOnly.
        let manualViaCookieSource = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .auto, cookieSource: .manual)
        )
        XCTAssertEqual(manualViaCookieSource, .manualOnly)
        XCTAssertTrue(manualViaCookieSource.allows(slot(origin: .manual)))
        XCTAssertFalse(manualViaCookieSource.allows(slot(origin: .browserImport)))

        // Explicit browserOnly source mode.
        let browser = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .browserOnly)
        )
        XCTAssertEqual(browser, .browserOnly)
        XCTAssertFalse(browser.allows(slot(origin: .manual)))
        XCTAssertTrue(browser.allows(slot(origin: .browserImport)))
        XCTAssertTrue(browser.allows(slot(origin: .autoRefresh)))

        // apiOnly / off shut every slot out.
        let api = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .apiOnly)
        )
        XCTAssertEqual(api, .none)
        XCTAssertFalse(api.allows(slot(origin: .browserImport)))

        let off = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .off)
        )
        XCTAssertEqual(off, .none)
    }

    private func slot(origin: MiscCookieSlot.Origin) -> MiscCookieSlot {
        MiscCookieSlot(
            cookieHeader: "name=value",
            sourceLabel: "test",
            importedAt: Date(),
            origin: origin
        )
    }
}
