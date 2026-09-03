import XCTest
@testable import VibeBarCore

/// The "Open console" link has to land where the credential actually
/// lives. `ToolType.statusPageURL` holds one fixed URL per tool, so a Z.ai
/// instance set to China mainland was still sent to the Global site, and a
/// MiniMax China instance to platform.minimax.io — in both cases a console
/// that cannot issue the key the card is asking for.
final class MiscProviderConsoleLinkTests: XCTestCase {
    private func settings(region: String?) -> MiscProviderSettings {
        MiscProviderSettings(region: region)
    }

    private func hosts(_ tool: ToolType, region: String?) -> [String] {
        MiscProviderConsole.links(for: tool, settings: settings(region: region))
            .compactMap(\.url.host)
    }

    // MARK: - Z.ai

    func testZaiFollowsTheRegionPicker() {
        XCTAssertEqual(hosts(.zai, region: "global"), ["z.ai"])
        XCTAssertEqual(hosts(.zai, region: "bigmodel-cn"), ["open.bigmodel.cn"])
    }

    /// On Auto either console could hold the key, so offer both rather
    /// than silently guessing Global.
    func testZaiOnAutoOffersBothConsoles() {
        XCTAssertEqual(hosts(.zai, region: nil), ["z.ai", "open.bigmodel.cn"])
        XCTAssertEqual(hosts(.zai, region: ""), ["z.ai", "open.bigmodel.cn"])
    }

    // MARK: - MiniMax

    func testMiniMaxChinaInstanceGetsTheMainlandConsole() {
        XCTAssertEqual(hosts(.minimax, region: "cn"), ["platform.minimaxi.com"])
        XCTAssertEqual(hosts(.minimax, region: "cn-beijing"), ["platform.minimaxi.com"])
    }

    /// The picker has no Auto entry and defaults to Global, matching
    /// `MiniMaxRegion.resolve`.
    func testMiniMaxDefaultsToTheGlobalConsole() {
        XCTAssertEqual(hosts(.minimax, region: nil), ["platform.minimax.io"])
        XCTAssertEqual(hosts(.minimax, region: "global"), ["platform.minimax.io"])
    }

    // MARK: - Alibaba Bailian

    func testAlibabaFollowsTheRegionPicker() {
        XCTAssertEqual(hosts(.alibaba, region: "cn-beijing"), ["bailian.console.aliyun.com"])
        XCTAssertEqual(
            hosts(.alibaba, region: "ap-southeast-1"),
            ["modelstudio.console.alibabacloud.com"]
        )
    }

    func testAlibabaOnAutoOffersBothConsoles() {
        XCTAssertEqual(
            hosts(.alibaba, region: nil),
            ["bailian.console.aliyun.com", "modelstudio.console.alibabacloud.com"]
        )
    }

    func testAlibabaTokenPlanLinksLandOnTheTokenPlanTab() {
        let links = MiscProviderConsole.links(
            for: .alibabaTokenPlan,
            settings: settings(region: "cn-beijing")
        )
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].url.absoluteString.contains("token-plan"))
    }

    // MARK: - Everything else

    /// Tencent's Token Plan card stores its *variant* in `region`, so it
    /// must never be treated as a region.
    func testTencentTokenPlanVariantIsNotMistakenForARegion() {
        let generic = MiscProviderConsole.links(for: .tencentTokenPlan, settings: settings(region: nil))
        let hy3 = MiscProviderConsole.links(for: .tencentTokenPlan, settings: settings(region: "hy3"))
        XCTAssertEqual(generic, hy3)
        XCTAssertEqual(generic.count, 1)
    }

    func testCopilotPointsAtSettingsRatherThanTheStatusPage() {
        let links = MiscProviderConsole.links(for: .copilot, settings: .default)
        XCTAssertEqual(links.map(\.url.host), ["github.com"])
        XCTAssertNotEqual(links[0].url, ToolType.copilot.statusPageURL)
    }

    func testEveryMiscProviderOffersAtLeastOneLink() {
        for tool in ToolType.allCases where tool.isMiscPageProvider {
            let links = MiscProviderConsole.links(for: tool, settings: .default)
            XCTAssertFalse(links.isEmpty, "\(tool.rawValue) has no console link")
            for link in links {
                XCTAssertEqual(link.url.scheme, "https", "\(tool.rawValue) link is not https")
                XCTAssertTrue(link.title.hasPrefix("Open "), "\(tool.rawValue): \(link.title)")
            }
        }
    }

    func testAgentPlanKeepsItsDeepLink() {
        let links = MiscProviderConsole.links(for: .volcengineAgentPlan, settings: .default)
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].url.absoluteString.contains("agentPlan"))
    }
}
