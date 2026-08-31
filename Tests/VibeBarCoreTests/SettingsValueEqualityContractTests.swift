import XCTest
@testable import VibeBarCore

/// When two JSON values mean the same setting.
///
/// Both clients decide this, and a disagreement is not academic: whichever
/// side thinks a value changed writes a file the other did not expect, and
/// tells its user their setting was replaced when nothing happened to it.
final class SettingsValueEqualityContractTests: XCTestCase {
    private func contract() throws -> SettingsDocument.Object {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/contracts/settings-value-equality-v1.json")
        // Parsed the same way settings are, so the cases exercise the same
        // number representation the real path produces.
        return try XCTUnwrap(SettingsDocument.object(from: try Data(contentsOf: url)))
    }

    /// A divergence is only worth recording while it is still true. If this
    /// client's answer changes, the record is stale and the note explaining
    /// why it was left alone no longer applies.
    func testTheRecordedDivergencesAreStillWhatThisClientDoes() throws {
        let divergences = try XCTUnwrap(contract()["knownDivergences"] as? [[String: Any]])
        for entry in divergences {
            let name = try XCTUnwrap(entry["case"] as? String)
            XCTAssertEqual(
                SettingsDocument.equal(entry["left"], entry["right"]),
                try XCTUnwrap(entry["native"] as? Bool),
                "\(name): this client no longer behaves as the contract records"
            )
        }
    }

    func testEveryCaseAgreesWithTheContract() throws {
        let cases = try XCTUnwrap(contract()["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10, "the contract file looks truncated")

        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let expected = try XCTUnwrap(entry["equal"] as? Bool)
            // `nil` in the file is `NSNull` here, which is the point of two of
            // the cases; a missing key would be a different fact entirely.
            XCTAssertTrue(entry.keys.contains("left") && entry.keys.contains("right"), name)
            XCTAssertEqual(
                SettingsDocument.equal(entry["left"], entry["right"]), expected,
                "\(name): left=\(entry["left"] ?? "nil") right=\(entry["right"] ?? "nil")"
            )
        }
    }
}
