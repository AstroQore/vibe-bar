import XCTest
@testable import VibeBarCore

/// `QuotaError` payloads are a mix of copy Vibe Bar wrote and text lifted
/// verbatim out of a provider response — `WarpResponseParser` builds a
/// `.parseFailure` straight from GraphQL `errors[].message`. Since the
/// payload started reaching the card, it also started reaching two sinks
/// that leave this machine: a public `os_log` line and the MCP projection
/// an agent reads. Both have to be redacted, and the agent-facing one has
/// to stay useful while it is.
final class QuotaErrorRedactionTests: XCTestCase {
    /// Synthetic throughout: a documented example address and a JWT-shaped
    /// string that is not a credential for anything.
    private let leakyDiagnostic =
        "Warp GraphQL: user quota-user@example.com rejected, session eyJhbGciOiJIUzI1NiJ9xxxxx"

    // MARK: - Log projection

    func testLogProjectionMasksAnEmailAndATokenFromAProviderPayload() {
        let logged = QuotaError.parseFailure(leakyDiagnostic).logSafeMessage
        XCTAssertFalse(logged.contains("quota-user@example.com"))
        XCTAssertFalse(logged.contains("eyJhbGciOiJIUzI1NiJ9xxxxx"))
        XCTAssertTrue(logged.contains("***"))
    }

    func testLogProjectionCoversEveryPayloadCarryingCase() {
        for error: QuotaError in [
            .parseFailure(leakyDiagnostic),
            .network(leakyDiagnostic),
            .unknown(leakyDiagnostic),
            .credentialRejected(leakyDiagnostic)
        ] {
            XCTAssertFalse(
                error.logSafeMessage.contains("eyJhbGciOiJIUzI1NiJ9xxxxx"),
                "\(error) leaked a token into the log projection"
            )
        }
    }

    func testCuratedMessagesWithoutSecretsSurviveTheLogProjection() {
        let error = QuotaError.parseFailure(VolcengineResponseParser.noCodingPlanMessage)
        XCTAssertTrue(error.logSafeMessage.contains("no Coding Plan subscription"))
        XCTAssertTrue(error.logSafeMessage.contains("Volcengine Agent Plan card"))
    }

    // MARK: - Agent projection

    func testAgentProjectionMasksAnEmailAndAToken() {
        let projected = QuotaError.parseFailure(leakyDiagnostic).agentFacingMessage
        XCTAssertFalse(projected.contains("quota-user@example.com"))
        XCTAssertFalse(projected.contains("eyJhbGciOiJIUzI1NiJ9xxxxx"))
    }

    /// The agent still has to be able to act on the message, so the
    /// redactor that feeds it must not flatten ordinary hostnames the way
    /// the log redactor does.
    func testAgentProjectionKeepsTheActionableHalfOfACuratedMessage() {
        let error = QuotaError.credentialRejected(
            "The imported Volcengine cookies have no csrfToken. Open the Ark console once in your browser (console.volcengine.com/ark), then re-import."
        )
        XCTAssertTrue(error.agentFacingMessage.contains("console.volcengine.com"))
        XCTAssertTrue(error.agentFacingMessage.contains("csrfToken"))
    }

    func testAgentProjectionCapsARunawayProviderPayload() {
        let flood = String(repeating: "stack frame. ", count: 200)
        let projected = QuotaError.network(flood).agentFacingMessage
        XCTAssertLessThanOrEqual(
            projected.count,
            ProviderDiagnosticRedactor.defaultMaxLength + 1
        )
        XCTAssertTrue(projected.hasSuffix("…"))
    }

    // MARK: - The MCP DTO uses the agent projection

    func testMCPAccountProjectionDoesNotShipTheRawProviderPayload() {
        let quota = AccountQuota(
            accountId: "misc-warp",
            tool: .warp,
            buckets: [],
            plan: nil,
            email: "quota-user@example.com",
            queriedAt: Date(timeIntervalSince1970: 1_786_968_000)
        )
        let dto = MCPQuotaAccountDTO(
            quota: quota,
            lastUpdated: nil,
            lastAttempted: nil,
            inFlight: false,
            error: .parseFailure(leakyDiagnostic)
        )

        let error = dto.error ?? ""
        XCTAssertFalse(error.isEmpty)
        XCTAssertFalse(error.contains("quota-user@example.com"))
        XCTAssertFalse(error.contains("eyJhbGciOiJIUzI1NiJ9xxxxx"))
        // The account's own email was already masked; the one inside the
        // diagnostic must not sneak past on a different route.
        XCTAssertFalse((dto.email ?? "").contains("quota-user@example.com"))
    }

    // MARK: - Redaction at construction, for the named example

    func testWarpRedactsGraphQLErrorsBeforeTheyBecomeAQuotaError() {
        let body = """
        {"errors": [{"message": "denied for quota-user@example.com token eyJhbGciOiJIUzI1NiJ9xxxxx"}]}
        """
        XCTAssertThrowsError(try WarpResponseParser.parse(data: Data(body.utf8), now: Date())) { error in
            guard let quotaError = error as? QuotaError,
                  case .parseFailure(let message) = quotaError else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
            XCTAssertFalse(message.contains("quota-user@example.com"))
            XCTAssertFalse(message.contains("eyJhbGciOiJIUzI1NiJ9xxxxx"))
        }
    }

    // MARK: - Redactor behaviour

    func testRedactorMasksAddressesAndOpaqueRunsButKeepsWords() {
        let redacted = ProviderDiagnosticRedactor.redact(
            "quota-user@example.com asked api.z.ai for a plan and got AKLTaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertFalse(redacted.contains("quota-user@example.com"))
        XCTAssertFalse(redacted.contains("AKLTaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertTrue(redacted.contains("api.z.ai"))
        XCTAssertTrue(redacted.contains("asked"))
    }

    func testRedactorCollapsesNewlines() {
        XCTAssertFalse(ProviderDiagnosticRedactor.redact("first\nsecond").contains("\n"))
    }
}
