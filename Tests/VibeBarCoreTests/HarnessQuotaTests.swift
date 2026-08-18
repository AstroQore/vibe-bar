import XCTest
@testable import VibeBarCore

/// The billing half of `Harness`. Naming, ordering and the raw-value
/// storage keys are `AgentSessionKit`'s and are covered by its own
/// `HarnessNamingTests`; what is Vibe Bar's — and tested here — is the
/// mapping onto `ToolType`, the company grouping, and the filter chips.
final class HarnessQuotaTests: XCTestCase {
    /// Gemini Web is a quota SubProvider with no local usage at all. The
    /// deprecated CLI owns the historical tokens under `~/.gemini/tmp`, and
    /// labelling those "Gemini Web" would put a quota name on a usage row.
    func testGeminiHarnessIsNamedForTheCLINotTheWebSubProvider() {
        XCTAssertEqual(Harness.geminiCLI.displayName, "Gemini CLI")
        XCTAssertNotEqual(Harness.geminiCLI.displayName, ToolType.gemini.productName)
    }

    func testEachHarnessMapsToItsQuotaToolAndCompany() {
        let expected: [Harness: (ToolType, ToolType)] = [
            .codex:        (.codex, .codex),
            .chatgptWork:  (.codex, .codex),
            .claudeCode:   (.claude, .claude),
            .claudeCowork: (.claude, .claude),
            .geminiCLI:    (.gemini, .gemini),
            .antigravity:  (.antigravity, .gemini),
            .grokBuild:    (.grok, .grok),
            .cursor:       (.cursor, .grok)
        ]
        XCTAssertEqual(expected.count, Harness.allCases.count)
        for harness in Harness.allCases {
            guard let pair = expected[harness] else {
                return XCTFail("\(harness) is missing from the expectation table")
            }
            XCTAssertEqual(harness.quotaTool, pair.0, "\(harness) quota tool")
            XCTAssertEqual(harness.company, pair.1, "\(harness) company")
        }
        XCTAssertEqual(Harness.chatgptWork.companyName, "OpenAI")
        XCTAssertEqual(Harness.antigravity.companyName, "Google AI")
        XCTAssertEqual(Harness.cursor.companyName, "SpaceXAI")
    }

    func testDefaultHarnessCoversEveryCostAwareToolAndNothingElse() {
        XCTAssertEqual(Harness.defaultHarness(for: .codex), .codex)
        XCTAssertEqual(Harness.defaultHarness(for: .claude), .claudeCode)
        XCTAssertEqual(Harness.defaultHarness(for: .gemini), .geminiCLI)
        XCTAssertEqual(Harness.defaultHarness(for: .antigravity), .antigravity)
        XCTAssertEqual(Harness.defaultHarness(for: .grok), .grokBuild)
        XCTAssertEqual(Harness.defaultHarness(for: .cursor), .cursor)

        for tool in ToolType.allCases {
            if tool.supportsTokenCost {
                XCTAssertNotNil(
                    Harness.defaultHarness(for: tool),
                    "\(tool) is scanned for cost and needs a harness to attribute rows to"
                )
            } else {
                XCTAssertNil(Harness.defaultHarness(for: tool), "\(tool) has no local harness")
            }
        }
    }

    func testHarnessesGroupUnderTheirCompanyRepresentative() {
        XCTAssertEqual(Harness.harnesses(forCompany: .codex), [.codex, .chatgptWork])
        XCTAssertEqual(Harness.harnesses(forCompany: .claude), [.claudeCode, .claudeCowork])
        XCTAssertEqual(Harness.harnesses(forCompany: .gemini), [.geminiCLI, .antigravity])
        XCTAssertEqual(Harness.harnesses(forCompany: .grok), [.grokBuild, .cursor])
        // A non-representative member resolves to the same company list.
        XCTAssertEqual(
            Harness.harnesses(forCompany: .cursor),
            Harness.harnesses(forCompany: .grok)
        )
        XCTAssertTrue(Harness.harnesses(forCompany: .warp).isEmpty)
    }

    /// The filter rows on Sessions and Usage Stats are harness-primary: the
    /// company is a section head that toggles its members, so the group has to
    /// carry the members in display order.
    func testChipGroupsCoverEveryCompanyInOrder() {
        let groups = Harness.chipGroups(companies: ToolType.coreProviderRepresentatives)
        XCTAssertEqual(groups.map(\.company), [.codex, .claude, .gemini, .grok])
        XCTAssertEqual(
            groups.map(\.harnesses),
            [
                [.codex, .chatgptWork],
                [.claudeCode, .claudeCowork],
                [.geminiCLI, .antigravity],
                [.grokBuild, .cursor]
            ]
        )
        XCTAssertEqual(groups.flatMap(\.harnesses), Harness.allCases)
    }

    func testChipGroupsNarrowToTheHarnessesAPageKnowsAbout() {
        let groups = Harness.chipGroups(
            companies: ToolType.coreProviderRepresentatives,
            harnesses: [.cursor, .claudeCode]
        )
        XCTAssertEqual(groups.map(\.company), [.claude, .grok])
        XCTAssertEqual(groups.map(\.harnesses), [[.claudeCode], [.cursor]])
        XCTAssertTrue(
            Harness.chipGroups(
                companies: ToolType.coreProviderRepresentatives,
                harnesses: []
            ).isEmpty
        )
    }

    /// A non-representative member and a company with no harness at all both
    /// have to resolve without producing a duplicate or an empty chip.
    func testChipGroupsNormalizeCompaniesAndDropEmptyOnes() {
        let groups = Harness.chipGroups(companies: [.cursor, .grok, .warp])
        XCTAssertEqual(groups.map(\.company), [.grok])
        XCTAssertEqual(groups.first?.harnesses, [.grokBuild, .cursor])
        XCTAssertEqual(groups.first?.harnessSet, Set([Harness.grokBuild, .cursor]))
    }
}
