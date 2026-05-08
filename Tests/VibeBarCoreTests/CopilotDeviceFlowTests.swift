import Foundation
import XCTest
@testable import VibeBarCore

final class CopilotDeviceFlowTests: XCTestCase {
    func testPrefersCompleteVerificationURLWhenAvailable() throws {
        let response = try JSONDecoder().decode(
            CopilotDeviceFlow.DeviceCodeResponse.self,
            from: Data(
                """
                {
                  "device_code": "device-code",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "verification_uri_complete": "https://github.com/login/device?user_code=ABCD-EFGH",
                  "expires_in": 900,
                  "interval": 5
                }
                """.utf8
            )
        )

        XCTAssertEqual(
            response.verificationURLToOpen,
            "https://github.com/login/device?user_code=ABCD-EFGH"
        )
    }

    func testFallsBackToVerificationURLWhenCompleteURLMissing() throws {
        let response = try JSONDecoder().decode(
            CopilotDeviceFlow.DeviceCodeResponse.self,
            from: Data(
                """
                {
                  "device_code": "device-code",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "expires_in": 900,
                  "interval": 5
                }
                """.utf8
            )
        )

        XCTAssertEqual(response.verificationURLToOpen, "https://github.com/login/device")
    }

    func testDeviceFlowUsesGitHubByDefault() throws {
        let flow = CopilotDeviceFlow()

        XCTAssertEqual(flow.deviceCodeURL?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(flow.accessTokenURL?.absoluteString, "https://github.com/login/oauth/access_token")
    }

    func testDeviceFlowUsesEnterpriseHostAndPort() throws {
        let flow = CopilotDeviceFlow(enterpriseHost: "https://octocorp.ghe.com:8443/login")

        XCTAssertEqual(
            flow.deviceCodeURL?.absoluteString,
            "https://octocorp.ghe.com:8443/login/device/code"
        )
        XCTAssertEqual(
            flow.accessTokenURL?.absoluteString,
            "https://octocorp.ghe.com:8443/login/oauth/access_token"
        )
    }

    func testDeviceFlowRejectsInvalidEnterpriseHostWithoutCrashing() {
        let flow = CopilotDeviceFlow(enterpriseHost: "foo bar")

        XCTAssertNil(flow.deviceCodeURL)
        XCTAssertNil(flow.accessTokenURL)
    }

    func testUsageURLUsesEnterpriseAPIHostAndPort() {
        XCTAssertEqual(
            CopilotEndpoint.usageURL(enterpriseHost: nil)?.absoluteString,
            "https://api.github.com/copilot_internal/user"
        )
        XCTAssertEqual(
            CopilotEndpoint.usageURL(enterpriseHost: "octocorp.ghe.com")?.absoluteString,
            "https://api.octocorp.ghe.com/copilot_internal/user"
        )
        XCTAssertEqual(
            CopilotEndpoint.usageURL(enterpriseHost: "octocorp.ghe.com:8443")?.absoluteString,
            "https://api.octocorp.ghe.com:8443/copilot_internal/user"
        )
    }
}
