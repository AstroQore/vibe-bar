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

    func testWebLoginCaptureKindRoundTripsWithLegacyOrigin() throws {
        let slot = MiscCookieSlot(
            cookieHeader: "kimi-auth=synthetic.header.signature",
            sourceLabel: "Kimi Web login",
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .manual,
            captureKind: .webLogin
        )

        XCTAssertEqual(try JSONDecoder().decode(MiscCookieSlot.self, from: JSONEncoder().encode(slot)), slot)
    }

    func testDev40DecoderCanReadWebLoginSlotWithoutDroppingTheArray() throws {
        let slot = webLoginSlot()
        let data = try JSONEncoder().encode([slot])

        let legacy = try JSONDecoder().decode([Dev40MiscCookieSlot].self, from: data)

        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy[0].cookieHeader, slot.cookieHeader)
        XCTAssertEqual(legacy[0].origin, .manual)
    }

    func testSlotFilterFromSettings() {
        // Auto mode: all origins pass.
        let auto = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .auto, cookieSource: .auto)
        )
        XCTAssertEqual(auto, .all)
        XCTAssertTrue(auto.allows(slot(origin: .manual)))
        XCTAssertTrue(auto.allows(slot(origin: .browserImport)))
        XCTAssertTrue(auto.allows(webLoginSlot()))
        XCTAssertTrue(auto.allows(slot(origin: .autoRefresh)))

        // Auto with cookieSource = manual collapses to manualOnly.
        let manualViaCookieSource = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .auto, cookieSource: .manual)
        )
        XCTAssertEqual(manualViaCookieSource, .manualOnly)
        XCTAssertTrue(manualViaCookieSource.allows(slot(origin: .manual)))
        XCTAssertTrue(manualViaCookieSource.allows(webLoginSlot()))
        XCTAssertFalse(manualViaCookieSource.allows(slot(origin: .browserImport)))

        // Explicit browserOnly source mode.
        let browser = MiscCookieResolver.SlotFilter(
            settings: MiscProviderSettings(sourceMode: .browserOnly)
        )
        XCTAssertEqual(browser, .browserOnly)
        XCTAssertFalse(browser.allows(slot(origin: .manual)))
        XCTAssertTrue(browser.allows(slot(origin: .browserImport)))
        XCTAssertTrue(browser.allows(webLoginSlot()))
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

    func testOnlySystemBrowserOriginsCanBeSilentlyReimported() {
        XCTAssertFalse(slot(origin: .manual).isSystemBrowserRefreshable)
        XCTAssertTrue(slot(origin: .browserImport).isSystemBrowserRefreshable)
        XCTAssertTrue(slot(origin: .autoRefresh).isSystemBrowserRefreshable)
        XCTAssertFalse(webLoginSlot().isSystemBrowserRefreshable)
    }

    private func slot(origin: MiscCookieSlot.Origin) -> MiscCookieSlot {
        MiscCookieSlot(
            cookieHeader: "name=value",
            sourceLabel: "test",
            importedAt: Date(),
            origin: origin
        )
    }

    private func webLoginSlot() -> MiscCookieSlot {
        MiscCookieSlot(
            cookieHeader: "kimi-auth=synthetic.header.signature",
            sourceLabel: "Kimi Web login",
            importedAt: Date(),
            origin: .manual,
            captureKind: .webLogin
        )
    }
}

/// Exact wire shape shipped in Dev 40. Unknown additive object fields are
/// ignored by synthesized Decodable, but unknown enum raw values are not.
private struct Dev40MiscCookieSlot: Decodable {
    enum Origin: String, Decodable {
        case manual
        case browserImport
        case autoRefresh
    }

    let id: UUID
    let cookieHeader: String
    let sourceLabel: String
    let importedAt: Date
    let origin: Origin
}
