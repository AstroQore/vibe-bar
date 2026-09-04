import XCTest
@testable import VibeBarCore

final class FilterQueryTests: XCTestCase {
    private let keys = ["Claude Code", "Anthropic", "claudeCode"]

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(FilterQuery.matches(keys, query: ""))
        XCTAssertTrue(FilterQuery.matches(keys, query: "   "))
    }

    func testEveryWordMustAppearInAnyOrder() {
        XCTAssertTrue(FilterQuery.matches(keys, query: "claude code"))
        XCTAssertTrue(FilterQuery.matches(keys, query: "code claude"))
        XCTAssertFalse(FilterQuery.matches(keys, query: "claude cowork"))
    }

    func testCompanyAndIdentifierKeysCount() {
        XCTAssertTrue(FilterQuery.matches(keys, query: "anthropic"))
        XCTAssertTrue(FilterQuery.matches(keys, query: "claudecode"))
    }

    func testCaseAndDiacriticsDoNotMatter() {
        XCTAssertTrue(FilterQuery.matches(keys, query: "CLAUDE"))
        XCTAssertTrue(FilterQuery.matches(["Café"], query: "cafe"))
    }
}
