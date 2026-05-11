import XCTest
@testable import VibeBarCore

final class VisibleSecretRedactorTests: XCTestCase {
    func testRedactsCredentialShapedVisibleText() {
        XCTAssertEqual(
            VisibleSecretRedactor.redact("Authorization: Bearer sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789"),
            VisibleSecretRedactor.placeholder
        )
        XCTAssertEqual(
            VisibleSecretRedactor.redact("api_key=sk-cp-abcdefghijklmnopqrstuvwxyz0123456789"),
            "api_key=\(VisibleSecretRedactor.placeholder)"
        )
        XCTAssertEqual(
            VisibleSecretRedactor.redact("sk-or-v1-ca5...3fa"),
            VisibleSecretRedactor.placeholder
        )
        XCTAssertEqual(
            VisibleSecretRedactor.redact("Cookie: sessionKey=sk-ant-abcdefghijklmnopqrstuvwxyz; other=value"),
            VisibleSecretRedactor.placeholder
        )
        XCTAssertTrue(VisibleSecretRedactor.looksSensitive("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturepart"))
    }

    func testQuotaAndAccountPlanDropVisibleSecrets() {
        let bucket = QuotaBucket(
            id: "secret",
            title: "sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789",
            shortLabel: "Bearer sk-cp-abcdefghijklmnopqrstuvwxyz",
            usedPercent: 10,
            groupTitle: "access_token=abcdef0123456789"
        )
        XCTAssertEqual(bucket.title, VisibleSecretRedactor.placeholder)
        XCTAssertEqual(bucket.shortLabel, VisibleSecretRedactor.placeholder)
        XCTAssertEqual(bucket.groupTitle, "access_token=\(VisibleSecretRedactor.placeholder)")

        let quota = AccountQuota(
            accountId: "openrouter",
            tool: .openRouter,
            buckets: [bucket],
            plan: "sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789"
        )
        XCTAssertNil(quota.plan)
    }
}
