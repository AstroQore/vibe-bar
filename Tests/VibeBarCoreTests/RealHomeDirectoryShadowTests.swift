import AgentSessionKit
import XCTest
@testable import VibeBarCore

/// With both modules imported, the two `RealHomeDirectory` types are
/// distinct and, absent a demo override, agree on the answer.
final class RealHomeDirectoryShadowTests: XCTestCase {
    func testShadowAndKitAreDifferentTypesWithTheSameAnswer() {
        XCTAssertFalse(
            ObjectIdentifier(VibeBarCore.RealHomeDirectory.self)
                == ObjectIdentifier(AgentSessionKit.RealHomeDirectory.self)
        )
        XCTAssertEqual(VibeBarCore.RealHomeDirectory.path, AgentSessionKit.RealHomeDirectory.path)
        XCTAssertEqual(VibeBarCore.RealHomeDirectory.systemPath, AgentSessionKit.RealHomeDirectory.path)
        XCTAssertEqual(VibeBarCore.RealHomeDirectory.url, AgentSessionKit.RealHomeDirectory.url)
    }
}
