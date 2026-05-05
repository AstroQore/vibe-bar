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
