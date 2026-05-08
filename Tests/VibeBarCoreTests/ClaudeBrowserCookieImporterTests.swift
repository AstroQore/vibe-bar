import XCTest
@testable import VibeBarCore

final class ClaudeBrowserCookieImporterTests: XCTestCase {
    func testSessionHeaderExtractsOnlySessionKey() {
        let header = ClaudeBrowserCookieImporter.sessionHeader(from: [
            (name: "other", value: "ignored"),
            (name: "sessionKey", value: "sk-ant-test")
        ])

        XCTAssertEqual(header, "sessionKey=sk-ant-test")
    }

    func testSessionHeaderReturnsNilWithoutSessionKey() {
        XCTAssertNil(ClaudeBrowserCookieImporter.sessionHeader(from: [
            (name: "sessionKeyLC", value: "1"),
            (name: "cf_clearance", value: "not-auth")
        ]))
    }

    func testSessionHeaderRejectsNonClaudeSessionKey() {
        XCTAssertNil(ClaudeBrowserCookieImporter.sessionHeader(from: [
            (name: "sessionKey", value: "not-a-claude-session")
        ]))
    }
}
