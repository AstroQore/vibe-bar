import XCTest
@testable import VibeBarCore

final class StudioCardGroupsTests: XCTestCase {
    private func ids(_ values: [String]) -> [PageLayoutModuleID] { values.map(PageLayoutModuleID.init(rawValue:)) }

    func testGroupsGatherAcrossColumnsWithoutTakingUnselectedCards() {
        let columns = [ids(["a", "b"]), ids(["c", "d"])]
        let groups = StudioCardGroups.grouping(["a", "d"], in: [], order: ["a", "b", "c", "d"])
        XCTAssertEqual(groups, [["a", "d"]])
        XCTAssertEqual(StudioCardGroups.gathering(groups, columns: columns), [ids(["a", "d", "b"]), ids(["c"])])
        let moved = StudioCardGroups.moving(ids(["a", "d"]), to: .init(column: 1, index: 1), columns: columns)
        XCTAssertEqual(moved, [ids(["b"]), ids(["c", "a", "d"])])
    }

    func testExistingGroupsEnterWholeAndHiddenMembersAreRetained() {
        let group = StudioCardGroups.grouping(["b", "d"], in: [["a", "b", "hidden"]], order: ["a", "b", "c", "d"])
        XCTAssertEqual(group, [["a", "b", "d", "hidden"]])
        let columns = StudioCardGroups.gathering(group, columns: [ids(["a", "c"]), ids(["b", "d"])])
        XCTAssertEqual(columns, [ids(["a", "b", "d", "c"]), []])
        XCTAssertFalse(columns.flatMap { $0 }.contains(PageLayoutModuleID(rawValue: "hidden")))
    }

    func testMovedGroupSharesItsAnchorsSegment() {
        let result = StudioCardGroups.joiningSegment(ids(["a", "d"]), anchor: ids(["a"])[0], segments: [ids(["a", "b"]), ids(["c", "d"])])
        XCTAssertEqual(result.map(Set.init), [Set(ids(["a", "b", "d"])), Set(ids(["c"]))])
    }

    func testSettingsRoundTripGroupsAndNormalizeMalformedMembership() throws {
        var settings = AppSettings.default
        settings.studioCardGroups["overview"] = [["a", "a", "b", ""], ["b", "c"], ["d"]]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.studioCardGroups["overview"], [["a", "b"]])
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).studioCardGroups.isEmpty)
    }
}
