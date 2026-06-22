import XCTest
import Foundation
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

    /// Regression: `GetAFPUsage` must be signed against the OpenTOP
    /// management gateway (`open.volcengineapi.com`). Sending it to the Ark
    /// inference host (`ark.cn-beijing.volces.com`) returns HTTP 401 — that
    /// was the original AK/SK bug.
    func testSignedRequestTargetsOpenAPIManagementHost() {
        let adapter = VolcengineAgentPlanQuotaAdapter()
        let credentials = VolcengineAgentPlanQuotaAdapter.APICredentials(
            accessKeyID: "AKLTtest", secretAccessKey: "sk-test"
        )
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 22
        components.hour = 8
        components.minute = 49
        components.second = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let request = adapter.makeSignedRequest(credentials: credentials, date: date)

        XCTAssertEqual(request.url?.host, "open.volcengineapi.com")
        XCTAssertNotEqual(request.url?.host, "ark.cn-beijing.volces.com")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.query, "Action=GetAFPUsage&Version=2024-01-01")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Content-Sha256"),
            VolcengineSignerV4.sha256Hex(Data("{}".utf8))
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Date"))
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(
            authorization.contains("Credential=AKLTtest/20260622/cn-beijing/ark/request"),
            "unexpected Authorization: \(authorization)"
        )
        XCTAssertTrue(
            authorization.contains("SignedHeaders=host;x-content-sha256;x-date"),
            "unexpected Authorization: \(authorization)"
        )
    }
}
