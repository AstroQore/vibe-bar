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

    /// The lint is trusted, so it needs its own test.
    ///
    /// The first version matched regexes anchored to "a literal
    /// immediately after a known initializer". It reported clean while
    /// three migrated files still showed English, because that shape misses
    /// a ternary inside the argument, a call this codebase wrote itself,
    /// and an argument that wrapped onto the next line. This fixture is one
    /// of each, plus the things that must *not* be flagged.
    func testTheScannerCatchesTheShapesThatUsedToSlipPast() throws {
        guard let python = try locatePython() else {
            throw XCTSkip("no python3 on PATH; the lint cannot be run here")
        }
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LintFixture-\(UUID().uuidString).swift")
        try """
        import SwiftUI

        struct Fixture: View {
            var body: some View {
                Text("Plain literal")
                Label(busy ? "Ternary A" : "Ternary B", systemImage: "safari")
                sectionLabel("Project helper")
                Text(
                    "Wrapped onto its own line"
                )
                Button {
                    act()
                } label: {
                    Label(open ? "Fold" : "Unfold", systemImage: open ? "a" : "b")
                }
                .help("Modifier literal")

                // Not flagged, each for its own reason:
                Text(L10n.Common.refresh)
                Text("OpenAI")
                Text("·")
                Image(systemName: "arrow.clockwise")
                Text("x").tag("weekly")
                // Text("In a line comment")
                /* Text("In a block comment") */
                let path = url.appendingPathComponent("Contents/Resources")
                let flag = expanded(forGroupName: "Components")

                // Display formatting that asks the process locale instead
                // of the app's — the other half of what this lint guards.
                Text(bad.formatted(date: .abbreviated, time: .shortened))
                Text(count.formatted(.number.grouping(.automatic)))
                let stale = DateFormatter()
                let relative = RelativeDateTimeFormatter()
                let wrong = Locale.current

                // …and the same three done correctly, which must stay quiet.
                Text(AppLocale.string(good, dateStyle: .medium, timeStyle: .short))
                Text(count.formatted(.number.grouping(.automatic).locale(AppLocale.current)))
                let right = AppLocale.dateFormatter(template: "MMMd")
            }

            // A stored static holding a catalog value: frozen in whatever
            // language the process launched in, which no other rule here sees.
            static let frozenPills: [(String, TimeInterval)] = [
                (L10n.Common.durationHours(hours: 6), 6 * 3_600),
                (L10n.Common.durationDays(days: 7), 7 * 86_400)
            ]
            static var frozenVar: String = L10n.Common.refresh
            static let frozenNames = [CostChartGranularity.hour.displayName]

            // …and the shapes that must stay quiet: a computed static derives
            // per access, and a stored static of non-catalog values is data.
            static var derivedPills: [String] { [L10n.Common.refresh] }
            static let widths: [CGFloat] = [32, 64]
            // A closure defers the lookup to call time, which is how
            // QuotaGroupLabelLocalizer's table stays correct while looking
            // exactly like the bug.
            static let deferred: [String: () -> String] = [
                "weekly": { L10n.Quota.groupWeekly }
            ]

            private func sectionLabel(_ text: String) -> some View { Text(text) }
        }
        """.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let process = Process()
        process.executableURL = python
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/lint_localization.py").path,
            "--scan", fixture.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        let found = Set(
            text.split(separator: "\n").compactMap { $0.split(separator: "\t").last }
                .map(String.init)
        )
        for expected in [
            "Plain literal", "Ternary A", "Ternary B", "Project helper",
            "Wrapped onto its own line", "Fold", "Unfold", "Modifier literal",
        ] {
            XCTAssertTrue(found.contains(expected), "the lint missed \(expected): \(found)")
        }

        // The frozen-static rule: three stored statics hold a catalog value,
        // and the two beside them that do not must stay quiet. Counted rather
        // than matched by text so the wording of the finding can change.
        let frozen = text.split(separator: "\n").filter {
            $0.contains("frozen at launch language")
        }
        XCTAssertEqual(
            frozen.count, 3,
            "expected exactly the three stored statics holding a catalog value: \(text)"
        )
        // The formatting rule reports a reason rather than a literal, so
        // these are matched as substrings of the whole report.
        for expected in [
            ".formatted(date:time:)", "DateFormatter()",
            "RelativeDateTimeFormatter()", "Locale.current",
            "without .locale(AppLocale.current)",
        ] {
            XCTAssertTrue(
                text.contains(expected),
                "the lint missed the formatting shape \(expected)"
            )
        }
        XCTAssertEqual(
            text.components(separatedBy: "DateFormatter()").count - 1, 1,
            "AppLocale.dateFormatter was flagged as a raw DateFormatter"
        )
        for ignored in [
            "safari", "arrow.clockwise", "OpenAI", "·", "weekly", "a", "b",
            "In a line comment", "In a block comment",
            "Contents/Resources", "Components",
        ] {
            XCTAssertFalse(found.contains(ignored), "the lint flagged \(ignored), which is not copy")
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
