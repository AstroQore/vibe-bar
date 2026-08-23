import XCTest
@testable import VibeBarCore

final class HostSuffixMatcherTests: XCTestCase {
    func testMatchesExactHostAndSubdomainsOnly() {
        XCTAssertTrue(HostSuffixMatcher.matches("kimi.com", allowedSuffixes: ["kimi.com"]))
        XCTAssertTrue(HostSuffixMatcher.matches("www.kimi.com", allowedSuffixes: ["kimi.com"]))
        XCTAssertTrue(HostSuffixMatcher.matches("WWW.KIMI.COM", allowedSuffixes: [".kimi.com"]))
        XCTAssertFalse(HostSuffixMatcher.matches("evilkimi.com", allowedSuffixes: ["kimi.com"]))
        XCTAssertFalse(HostSuffixMatcher.matches("moonshot.cn", allowedSuffixes: ["kimi.com"]))
        XCTAssertFalse(HostSuffixMatcher.matches(nil, allowedSuffixes: ["kimi.com"]))
        XCTAssertFalse(HostSuffixMatcher.matches("kimi.com", allowedSuffixes: [""]))
    }
}
