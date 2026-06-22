import XCTest
@testable import VibeBarCore

final class VolcengineAgentPlanAdapterTests: XCTestCase {
    func testEnvironmentCredentialsRequireBothKeys() {
        XCTAssertNil(VolcengineAgentPlanQuotaAdapter.credentialsFromEnvironment(["VOLC_ACCESSKEY": "ak-only"]))
        XCTAssertNil(VolcengineAgentPlanQuotaAdapter.credentialsFromEnvironment(["VOLC_SECRETKEY": "sk-only"]))
        XCTAssertNil(VolcengineAgentPlanQuotaAdapter.credentialsFromEnvironment([:]))
    }

    func testEnvironmentCredentialsPrimaryNamesAreTrimmed() {
        let creds = VolcengineAgentPlanQuotaAdapter.credentialsFromEnvironment([
            "VOLC_ACCESSKEY": "  AKLT-demo  ",
            "VOLC_SECRETKEY": "  sk-demo  "
        ])
        XCTAssertEqual(creds?.accessKeyID, "AKLT-demo")
        XCTAssertEqual(creds?.secretAccessKey, "sk-demo")
    }

    func testEnvironmentCredentialsAcceptVolcengineAliasNames() {
        let creds = VolcengineAgentPlanQuotaAdapter.credentialsFromEnvironment([
            "VOLCENGINE_ACCESS_KEY": "AKLT-alias",
            "VOLCENGINE_SECRET_KEY": "sk-alias"
        ])
        XCTAssertEqual(creds?.accessKeyID, "AKLT-alias")
        XCTAssertEqual(creds?.secretAccessKey, "sk-alias")
    }
}
