import XCTest
@testable import VibeBarCore

/// The naming spec is generated from the same catalogs the app renders from,
/// so these assertions are what stops it silently going stale when a provider
/// or a harness is added.
final class MCPResourceCatalogTests: XCTestCase {
    private let spec = MCPResourceCatalog.namingSpec

    func testEveryHarnessAppearsByDisplayNameAndKey() {
        for harness in Harness.allCases {
            XCTAssertTrue(
                spec.contains(harness.displayName),
                "The naming spec never mentions the harness '\(harness.displayName)'."
            )
            XCTAssertTrue(
                spec.contains("`\(harness.rawValue)`"),
                "The naming spec never mentions the harness key '\(harness.rawValue)'."
            )
        }
        XCTAssertEqual(Harness.allCases.count, 9, "A new harness needs a row in the evidence table.")
    }

    func testEveryL1CompanyAppears() {
        let companies = Set(ToolType.coreProviderRepresentatives.map(\.vendorName))
        XCTAssertEqual(companies, ["OpenAI", "Anthropic", "Google AI", "SpaceXAI"])
        for company in companies {
            XCTAssertTrue(spec.contains(company), "The naming spec never mentions '\(company)'.")
        }
    }

    func testEveryDedicatedSubProviderAppears() {
        for tool in ToolType.dedicatedCardProviders {
            XCTAssertTrue(
                spec.contains(tool.quotaSubProviderName()),
                "The naming spec never mentions the SubProvider '\(tool.quotaSubProviderName())'."
            )
        }
    }

    func testEveryMiscProviderAppears() {
        for tool in ToolType.miscPageProviders {
            XCTAssertTrue(
                spec.contains("`\(tool.rawValue)`"),
                "The naming spec never mentions the misc provider key '\(tool.rawValue)'."
            )
        }
    }

    func testTheTwoAxisRuleAndModelRuleAreStated() {
        XCTAssertTrue(spec.contains("two orthogonal axes"))
        XCTAssertTrue(spec.contains("Quota axis"))
        XCTAssertTrue(spec.contains("Usage / cost axis"))
        XCTAssertTrue(spec.contains("canonical vendor id"))
        XCTAssertTrue(spec.contains("Gemini Web"))
    }

    func testTheToolGuideRoutesEveryTool() {
        let guide = MCPResourceCatalog.toolsGuide
        for tool in MCPToolCatalog.all {
            XCTAssertTrue(guide.contains(tool.name), "The tool guide never mentions '\(tool.name)'.")
        }
    }

    func testResourceLookupIsExhaustiveAndClosed() {
        for resource in MCPResourceCatalog.all {
            XCTAssertNotNil(MCPResourceCatalog.contents(of: resource.uri), resource.uri)
        }
        XCTAssertNil(MCPResourceCatalog.contents(of: "vibebar://something-else"))
    }

    func testTheAgentSetupPromptIsTheDocumentedOne() {
        XCTAssertEqual(
            MCPClientConfig.agentSetupPrompt,
            "Fetch and execute the appropriate instructions to set me up for Vibe Bar from "
                + "https://raw.githubusercontent.com/AstroQore/vibe-bar/main/docs/agent-setup/prompt.md"
        )
    }

    func testEveryClientConfigRunsTheSameCommand() {
        let path = "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar"
        XCTAssertEqual(
            MCPClientConfig.claudeCodeCommand(executablePath: path),
            "claude mcp add --scope user vibebar -- \"\(path)\" --mcp-stdio"
        )
        for snippet in [
            MCPClientConfig.codexTOML(executablePath: path),
            MCPClientConfig.cursorJSON(executablePath: path),
            MCPClientConfig.genericJSON(executablePath: path)
        ] {
            XCTAssertTrue(snippet.contains(path), snippet)
            XCTAssertTrue(snippet.contains("--mcp-stdio"), snippet)
            XCTAssertTrue(snippet.contains("vibebar"), snippet)
        }
    }
}
