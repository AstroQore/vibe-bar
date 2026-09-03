import XCTest
@testable import VibeBarCore

/// A localization pass that is only enforced by review lasts until the
/// next PR. `Scripts/lint_localization.py` holds the list of files that
/// have been through the pass and fails on a user-facing literal in one
/// of them that does not go through `L10n`; this runs it, so the failure
/// arrives at `swift test` rather than at translation time.
///
/// The allow-list is `Resources/i18n/_glossary.json` — company,
/// SubProvider, product, model and harness names, which are identifiers
/// rather than copy (`AGENTS.md` § 7.1). The lint reads that file rather
/// than hardcoding the names, so the app, the cross-platform client, and
/// a human translator all consult one list.
final class LocalizationLintTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMigratedSurfacesHaveNoHardcodedUserFacingStrings() throws {
        guard let python = try locatePython() else {
            throw XCTSkip("no python3 on PATH; the lint cannot be run here")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/lint_localization.py").path
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let findings = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\n\(findings)")
    }

    /// The manifest is the promise. A file listed in it that no longer
    /// exists — renamed, split, deleted — silently stops being checked,
    /// which is the failure mode a lint is least able to notice itself.
    func testEveryFileInTheManifestExists() throws {
        guard let python = try locatePython() else {
            throw XCTSkip("no python3 on PATH; the lint cannot be run here")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/lint_localization.py").path,
            "--list",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let listing = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        let files = listing.split(separator: "\n").map(String.init)
        XCTAssertFalse(files.isEmpty, "the migrated manifest is empty")
        for relative in files {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repositoryRoot.appendingPathComponent(relative).path
                ),
                "\(relative) is listed as migrated but is not in the tree"
            )
        }
    }

    private func locatePython() throws -> URL? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
