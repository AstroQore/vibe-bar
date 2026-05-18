import XCTest
@testable import VibeBarCore

final class ProviderPlanDisplayTests: XCTestCase {
    func testCodexPlanDisplayHumanizesKnownMachineValues() {
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .codex, rawPlan: "pro"), "Pro")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .codex, rawPlan: "prolite"), "Pro Lite")
        XCTAssertEqual(
            ProviderPlanDisplay.displayName(for: .codex, rawPlan: "enterprise_cbp_usage_based"),
            "Enterprise CBP Usage Based"
        )
    }

    func testClaudePlanDisplayRecognizesRateLimitTiers() {
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "default_claude_max_20x"), "Max")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "claude_pro"), "Pro")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "Claude Enterprise Account"), "Enterprise")
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: "Experimental"), "Experimental")
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
        XCTAssertEqual(ProviderPlanDisplay.displayName(for: .claude, rawPlan: credential.rateLimitTier), "Max")
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

    func testMiscProviderMenuTitleAndSubtitleComposeNormalizedPlanNames() {
        let tools: [ToolType] = [
            .kimi, .alibaba, .alibabaTokenPlan, .tencentHunyuan,
            .tencentTokenPlan, .volcengine, .mimo, .minimax,
            .zai, .iflytek, .baiduQianfan
        ]

        for tool in tools {
            XCTAssertEqual("\(tool.menuTitle) \(tool.subtitle)", tool.displayName)
        }
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
