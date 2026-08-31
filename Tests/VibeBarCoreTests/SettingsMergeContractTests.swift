import XCTest
@testable import VibeBarCore

/// The merge cases both clients must resolve the same way.
///
/// Hand-written tests on each side drift: each ends up covering what its
/// author thought of, and a disagreement shows up as a setting that reverts on
/// one client only. These run from one file, vendored by Vibe Bar Desktop and
/// executed there too.
final class SettingsMergeContractTests: XCTestCase {
    private struct Case {
        let name: String
        let baseline: SettingsDocument.Object
        let mine: SettingsDocument.Object
        let theirs: SettingsDocument.Object
        let owned: Set<String>?
        let merged: SettingsDocument.Object
        let conflicts: [String]
    }

    private func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VibeBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("docs/contracts/settings-merge-v1.json")
        let object = try XCTUnwrap(
            SettingsDocument.object(from: try Data(contentsOf: url)),
            "the contract file is missing or is not an object"
        )
        let raw = try XCTUnwrap(object["cases"] as? [[String: Any]])
        return try raw.map { entry in
            Case(
                name: try XCTUnwrap(entry["name"] as? String),
                baseline: try XCTUnwrap(entry["baseline"] as? SettingsDocument.Object),
                mine: try XCTUnwrap(entry["mine"] as? SettingsDocument.Object),
                theirs: try XCTUnwrap(entry["theirs"] as? SettingsDocument.Object),
                owned: (entry["owned"] as? [String]).map(Set.init),
                merged: try XCTUnwrap(entry["merged"] as? SettingsDocument.Object),
                conflicts: try XCTUnwrap(entry["conflicts"] as? [String])
            )
        }
    }

    func testEveryCaseMergesAsTheContractSays() throws {
        let cases = try loadCases()
        XCTAssertGreaterThan(cases.count, 10, "the contract file looks truncated")
        for testCase in cases {
            let merged = SettingsDocument.merge(
                baseline: testCase.baseline, mine: testCase.mine,
                theirs: testCase.theirs, owned: testCase.owned
            )
            XCTAssertTrue(
                SettingsDocument.equal(merged, testCase.merged),
                "\(testCase.name): merged to \(merged), contract says \(testCase.merged)"
            )
        }
    }

    func testEveryCaseReportsTheConflictsTheContractSays() throws {
        for testCase in try loadCases() {
            let conflicts = SettingsDocument.conflictingKeys(
                baseline: testCase.baseline, mine: testCase.mine,
                theirs: testCase.theirs, owned: testCase.owned
            )
            XCTAssertEqual(
                conflicts.sorted(), testCase.conflicts.sorted(),
                "\(testCase.name): conflicts"
            )
        }
    }
}
