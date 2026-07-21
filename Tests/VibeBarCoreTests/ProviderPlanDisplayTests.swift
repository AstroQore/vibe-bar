import XCTest
@testable import VibeBarCore

final class ProviderPlanDisplayTests: XCTestCase {
    func testCodexPlanDisplayHumanizesKnownMachineValues() {
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .codex, rawPlan: "pro"), "ChatGPT Pro")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .codex, rawPlan: "prolite"), "ChatGPT Pro Lite")
        XCTAssertEqual(
            ProviderPlanDisplay.displayName(for: .codex, rawPlan: "enterprise_cbp_usage_based"),
            "ChatGPT Enterprise CBP Usage Based"
        )
    }

    func testClaudePlanDisplayRecognizesRateLimitTiers() {
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "default_claude_max_20x"), "Claude Max")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "claude_pro"), "Claude Pro")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "Claude Enterprise Account"), "Claude Enterprise")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "Experimental"), "Claude Experimental")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .gemini, rawPlan: "Ultra"), "Google AI Ultra")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .antigravity, rawPlan: "Google AI Ultra"), "Google AI Ultra")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .grok, rawPlan: "supergrok_heavy"), "SuperGrok Heavy")
    }

    func testCodexCredentialDecodesPlanAndEmailFromIDToken() throws {
        let jwt = try makeJWT(payload: [
            "email": "person@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "prolite",
                "chatgpt_account_id": "acct_from_token"
            ]
        ])
        let json = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "access-token",
            "id_token": "\(jwt)"
          }
        }
        """

        let credential = try CodexCredentialReader.decode(jsonString: json, source: .cliDetected)

        XCTAssertEqual(credential.email, "person@example.com")
        XCTAssertEqual(credential.plan, "prolite")
        XCTAssertEqual(credential.accountId, "acct_from_token")
    }

    func testClaudeCredentialDecodesRateLimitTier() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "access-token",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """

        let credential = try ClaudeCredentialReader.decode(jsonString: json, source: .cliDetected)

        XCTAssertEqual(credential.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: credential.rateLimitTier), "Claude Max")
    }

    func testMiscProviderDisplayNamesUseNormalizedPlanNames() {
        XCTAssertEqual(ToolType.kimi.displayName, "Kimi Coding Plan")
        XCTAssertEqual(ToolType.alibaba.displayName, "Alibaba Bailian Coding Plan")
        XCTAssertEqual(ToolType.alibabaTokenPlan.displayName, "Alibaba Bailian Token Plan")
        XCTAssertEqual(ToolType.tencentHunyuan.displayName, "Tencent Hunyuan Coding Plan")
        XCTAssertEqual(ToolType.tencentTokenPlan.displayName, "Tencent Hunyuan Token Plan")
        XCTAssertEqual(ToolType.volcengine.displayName, "Volcengine Coding Plan")
        XCTAssertEqual(ToolType.mimo.displayName, "Xiaomi MiMo Token Plan")
        XCTAssertEqual(ToolType.minimax.displayName, "MiniMax Token Plan")
        XCTAssertEqual(ToolType.zai.displayName, "Zhipu GLM Coding Plan")
        XCTAssertEqual(ToolType.iflytek.displayName, "iFlytek Spark Coding Plan")
        XCTAssertEqual(ToolType.baiduQianfan.displayName, "Baidu Qianfan Coding Plan")
    }

    /// Misc-provider displayName + menuTitle + subtitle used to share
    /// a strict join invariant (`menuTitle + " " + subtitle == displayName`).
    /// The L1/L2/L3 hierarchy split severed that — menuTitle is now
    /// pure L2 product, displayName is curated per-tool, and the misc
    /// providers have a mix of vendor-prefixed (`Alibaba Bailian
    /// Coding Plan`) and vendor-omitted (`Volcengine Coding Plan`,
    /// where the vendor name `ByteDance` is implicit) display forms.
    /// We keep the assertions for the primary tools only because
    /// they're the ones the user mentally maps to the hierarchy.
    func testPrimaryToolHierarchyLevelsAreDistinct() {
        let tools: [ToolType] = [.codex, .claude, .gemini, .antigravity, .grok]
        for tool in tools {
            // L1 vendor and L2 product must not be empty.
            XCTAssertFalse(tool.vendorName.isEmpty, "vendorName for \(tool)")
            XCTAssertFalse(tool.productName.isEmpty, "productName for \(tool)")
            XCTAssertFalse(tool.toolName.isEmpty, "toolName for \(tool)")
            // For the primary tools, statusProviderName = L1 vendor.
            XCTAssertEqual(tool.statusProviderName, tool.vendorName,
                           "statusProviderName should equal vendorName for primary tool \(tool)")
            // menuTitle = L2 product.
            XCTAssertEqual(tool.menuTitle, tool.productName,
                           "menuTitle should equal productName for primary tool \(tool)")
        }
        // Both Gemini Web and AntiGravity roll up to the Gemini product
        // under the Google vendor — the dual page relies on this.
        XCTAssertEqual(ToolType.gemini.vendorName, ToolType.antigravity.vendorName)
        XCTAssertEqual(ToolType.gemini.productName, ToolType.antigravity.productName)
    }

    private func makeJWT(payload: [String: Any]) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64URL(headerData)).\(base64URL(payloadData)).signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
