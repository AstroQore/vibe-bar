import XCTest
@testable import VibeBarCore

/// The quota axis — L1 company, L2 SubProvider, L3 group — is shared with Vibe
/// Bar Desktop through `docs/contracts/quota-naming-v1.json`. Both clients
/// arrange every provider list by it, and `AGENTS.md` § 7.1 makes agreeing on
/// these names a behavioural rule rather than a nicety: a bucket filed under
/// "Spark" here and "GPT-5.3 Codex Spark" there is two things to the reader.
///
/// The contract is generated from three Swift files. Rather than reimplement
/// that parsing in Swift and get a second thing to keep in step, this runs the
/// generator and compares — so the check is exact and total by construction,
/// including any rule added after this test was written.
final class QuotaNamingContractTests: XCTestCase {
    /// `Tests/VibeBarCoreTests/<this file>` → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var contractURL: URL {
        repositoryRoot.appendingPathComponent("docs/contracts/quota-naming-v1.json")
    }

    func testContractIsWhatTheGeneratorProduces() throws {
        let committed = try Data(contentsOf: contractURL)
        guard let python = try locatePython() else {
            throw XCTSkip("no python3 on PATH; the generator cannot be re-run here")
        }

        // Regenerate into a scratch copy of the repository's contract path so a
        // failing test never leaves the working tree modified.
        let backup = committed
        defer { try? backup.write(to: contractURL) }

        let process = Process()
        process.executableURL = python
        process.arguments = [
            repositoryRoot
                .appendingPathComponent("Scripts/generate_quota_naming_contract.py")
                .path
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0,
            "the generator refused to run: \(errorText)"
        )

        let regenerated = try Data(contentsOf: contractURL)
        XCTAssertEqual(
            regenerated, committed,
            """
            quota-naming-v1.json is stale. The naming tables in ToolType.swift, \
            MiniWindowGroupLabelCatalog.swift or QuotaFieldRegistry.swift changed \
            without the contract being regenerated, which leaves Vibe Bar Desktop \
            grouping providers the way this app used to. Run \
            Scripts/generate_quota_naming_contract.py.
            """
        )
    }

    /// The parts a second implementation cannot infer, asserted directly. If
    /// the generator were ever pointed at the wrong file it would still agree
    /// with itself; these do not.
    func testTheContractDescribesTheHierarchyThisAppUses() throws {
        let document = try contract()
        let hierarchy = try XCTUnwrap(document["hierarchy"] as? [String: [String: String]])

        XCTAssertEqual(hierarchy.count, ToolType.allCases.count,
                       "every tool needs a place on the quota axis")
        for tool in ToolType.allCases {
            let entry = try XCTUnwrap(hierarchy[tool.rawValue], "no hierarchy for \(tool.rawValue)")
            XCTAssertEqual(entry["company"], tool.hierarchy.vendor)
            XCTAssertEqual(entry["subProvider"], tool.hierarchy.product)
        }

        // Cursor reports Grok Bot's usage, so that one bucket belongs to a
        // different SubProvider than the account it arrives on. It is the only
        // case, and the one a naive tool-level mapping gets wrong.
        let overrides = try XCTUnwrap(document["subProviderOverrides"] as? [[String: String]])
        let grokBot = try XCTUnwrap(overrides.first { $0["bucket"] == "grok_bot_weekly" })
        XCTAssertEqual(grokBot["tool"], ToolType.cursor.rawValue)
        XCTAssertEqual(
            grokBot["subProvider"],
            ToolType.cursor.quotaSubProviderName(bucketID: "grok_bot_weekly")
        )
        XCTAssertNotEqual(grokBot["subProvider"], ToolType.cursor.hierarchy.product,
                          "an override that matches the default is not an override")
    }

    /// Every group key a rule can produce is either labelled here or documented
    /// as taking the bucket's own `groupTitle`. Without this a rule could point
    /// at a key nothing names, and the second client would draw a blank column
    /// header where this one draws a word.
    func testEveryRuleKeyIsEitherLabelledOrExplicitlyUnlabelled() throws {
        let document = try contract()
        let labels = try XCTUnwrap(document["groupLabels"] as? [String: String])
        let rules = try XCTUnwrap(document["groupKey"] as? [String: Any])
        let exact = try XCTUnwrap(rules["exact"] as? [[String: Any]])
        let contains = try XCTUnwrap(rules["contains"] as? [[String: Any]])

        let keys = Set(
            exact.compactMap { $0["key"] as? String }
                + contains.compactMap { $0["key"] as? String }
        )
        XCTAssertFalse(keys.isEmpty)
        for key in keys where labels[key] == nil {
            // Unlabelled is allowed, but only for keys this app also leaves to
            // the runtime catalog. Those all describe model families a provider
            // may or may not expose.
            XCTAssertTrue(
                key.hasPrefix("antigravity."),
                "\(key) has no label and is not one of the runtime-named groups"
            )
        }
        XCTAssertNotNil(document["fallback"] as? String,
                        "the unnamed case has to be written down somewhere")
    }

    private func contract() throws -> [String: Any] {
        let data = try Data(contentsOf: contractURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
