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

    func testLegacyWebLoginManualSlotDecodesAsBrowserImport() throws {
        let raw = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "cookieHeader": "session=synthetic",
          "sourceLabel": "Web login",
          "importedAt": "2026-08-23T10:00:00Z",
          "origin": "manual",
          "captureKind": "webLogin"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let slot = try decoder.decode(MiscCookieSlot.self, from: Data(raw.utf8))

        XCTAssertEqual(slot.origin, .browserImport)
        XCTAssertEqual(slot.sourceLabel, "Web login")
    }

    func testLegacyCaptureKindIsNotReencoded() throws {
        let raw = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "cookieHeader": "session=synthetic",
          "sourceLabel": "Web login",
          "importedAt": "2026-08-23T10:00:00Z",
          "origin": "manual",
          "captureKind": "webLogin"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let slot = try decoder.decode(MiscCookieSlot.self, from: Data(raw.utf8))

        let encoded = try JSONEncoder().encode(slot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["captureKind"])
        XCTAssertEqual(object["origin"] as? String, "browserImport")
    }

    func testOrdinaryManualSlotStaysManual() throws {
        let raw = """
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "cookieHeader": "session=synthetic",
          "sourceLabel": "Manual paste",
          "importedAt": "2026-08-23T10:00:00Z",
          "origin": "manual"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let slot = try decoder.decode(MiscCookieSlot.self, from: Data(raw.utf8))

        XCTAssertEqual(slot.origin, .manual)
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

    func testBrowserImportRefreshesTheSameProfileInPlace() {
        let id = UUID()
        let old = MiscCookieSlot(
            id: id,
            cookieHeader: "session=stale",
            sourceLabel: "Chrome Default",
            importedAt: Date(timeIntervalSince1970: 100),
            origin: .autoRefresh
        )
        let fresh = MiscCookieSlot(
            cookieHeader: "session=fresh",
            sourceLabel: "Chrome Default",
            importedAt: Date(timeIntervalSince1970: 200),
            origin: .browserImport
        )

        let merged = MiscCookieSlotStore.mergingBrowserImport(fresh, into: [old])

        XCTAssertEqual(merged.slots.count, 1)
        XCTAssertEqual(merged.stored.id, id)
        XCTAssertEqual(merged.stored.cookieHeader, "session=fresh")
        XCTAssertEqual(merged.stored.origin, .browserImport)
        XCTAssertEqual(merged.stored.importedAt, fresh.importedAt)
    }

    func testBrowserImportKeepsDifferentProfilesStacked() {
        let existing = MiscCookieSlot(
            cookieHeader: "session=shared",
            sourceLabel: "Chrome Profile 1",
            origin: .browserImport
        )
        let incoming = MiscCookieSlot(
            cookieHeader: "session=shared",
            sourceLabel: "Chrome Default",
            origin: .browserImport
        )

        let merged = MiscCookieSlotStore.mergingBrowserImport(incoming, into: [existing])

        XCTAssertEqual(merged.slots.map(\.sourceLabel), ["Chrome Profile 1", "Chrome Default"])
        XCTAssertEqual(merged.stored.id, incoming.id)
    }

    func testBrowserImportReclaimsSingleLegacyAutoRefreshSlot() {
        let manual = MiscCookieSlot(
            cookieHeader: "session=manual",
            sourceLabel: "Manual paste",
            origin: .manual
        )
        let legacyID = UUID()
        let legacy = MiscCookieSlot(
            id: legacyID,
            cookieHeader: "session=stale",
            sourceLabel: "Auto-refresh",
            importedAt: Date(timeIntervalSince1970: 100),
            origin: .autoRefresh
        )
        let incoming = MiscCookieSlot(
            cookieHeader: "session=fresh",
            sourceLabel: "Chrome Default",
            importedAt: Date(timeIntervalSince1970: 200),
            origin: .browserImport
        )

        let merged = MiscCookieSlotStore.mergingBrowserImport(
            incoming,
            into: [manual, legacy]
        )

        XCTAssertEqual(merged.slots.count, 2)
        XCTAssertEqual(merged.slots[0], manual)
        XCTAssertEqual(merged.stored.id, legacyID)
        XCTAssertEqual(merged.stored.cookieHeader, "session=fresh")
        XCTAssertEqual(merged.stored.sourceLabel, "Chrome Default")
        XCTAssertEqual(merged.stored.origin, .browserImport)
        XCTAssertEqual(merged.stored.importedAt, incoming.importedAt)
    }

    func testBrowserImportNeverOverwritesManualSlot() {
        let manual = MiscCookieSlot(
            cookieHeader: "session=same",
            sourceLabel: "Chrome Default",
            origin: .manual
        )
        let incoming = MiscCookieSlot(
            cookieHeader: "session=same",
            sourceLabel: "Chrome Default",
            origin: .browserImport
        )

        let merged = MiscCookieSlotStore.mergingBrowserImport(incoming, into: [manual])

        XCTAssertEqual(merged.slots.count, 2)
        XCTAssertEqual(merged.slots.first, manual)
        XCTAssertEqual(merged.stored.id, incoming.id)
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
