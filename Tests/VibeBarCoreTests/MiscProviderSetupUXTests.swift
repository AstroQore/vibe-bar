import XCTest
@testable import VibeBarCore

/// Covers the provider-setup diagnostics: the adapter messages that reach
/// the card, the shape checks on the credential fields, and the sentinel
/// check on a hand-pasted cookie header.
final class MiscProviderSetupUXTests: XCTestCase {

    // MARK: - QuotaError plumbing

    func testParseFailureSurfacesTheAdapterMessage() {
        let error = QuotaError.parseFailure("This account has no Coding Plan subscription.")
        XCTAssertEqual(error.userFacingMessage, "This account has no Coding Plan subscription.")
    }

    func testEmptyParseFailureFallsBackToTheGenericLine() {
        XCTAssertEqual(QuotaError.parseFailure("").userFacingMessage, "Response format changed")
    }

    func testCredentialRejectedIsACredentialStateAndKeepsItsMessage() {
        let error = QuotaError.credentialRejected("Key rejected — check the Access Key.")
        XCTAssertEqual(error.userFacingMessage, "Key rejected — check the Access Key.")
        XCTAssertTrue(error.isCredentialState)
        XCTAssertEqual(QuotaError.credentialRejected("").userFacingMessage, "Credential rejected")
    }

    func testExistingCredentialStateSemanticsAreUnchanged() {
        XCTAssertTrue(QuotaError.noCredential.isCredentialState)
        XCTAssertTrue(QuotaError.needsLogin.isCredentialState)
        XCTAssertFalse(QuotaError.parseFailure("x").isCredentialState)
        XCTAssertFalse(QuotaError.network("x").isCredentialState)
        XCTAssertFalse(QuotaError.rateLimited.isCredentialState)
        XCTAssertFalse(QuotaError.notImplemented.isCredentialState)
        XCTAssertFalse(QuotaError.unknown("x").isCredentialState)
    }

    // MARK: - Volcengine cross-references

    func testVolcengineEmptyUsagePointsAtTheAgentPlanCard() {
        let json = #"{"ResponseMetadata": {"RequestId": "r"}, "Result": {"QuotaUsage": []}}"#
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let quotaError = error as? QuotaError,
                  case .parseFailure(let message) = quotaError else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
            XCTAssertTrue(message.contains("no Coding Plan subscription"))
            XCTAssertTrue(message.contains("Volcengine Agent Plan card"))
            XCTAssertEqual(quotaError.userFacingMessage, message)
        }
    }

    func testVolcengineMissingResultAlsoPointsAtTheAgentPlanCard() {
        let json = #"{"ResponseMetadata": {"RequestId": "r"}}"#
        XCTAssertThrowsError(try VolcengineResponseParser.parseUsage(data: Data(json.utf8))) { error in
            guard let quotaError = error as? QuotaError,
                  case .parseFailure(let message) = quotaError else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
            XCTAssertEqual(message, VolcengineResponseParser.noCodingPlanMessage)
        }
    }

    func testTheTwoVolcengineCardsPointAtEachOther() {
        XCTAssertTrue(
            VolcengineResponseParser.noCodingPlanMessage.contains("Volcengine Agent Plan card")
        )
        XCTAssertTrue(
            VolcengineAgentPlanQuotaAdapter.noAgentPlanMessage.contains("Volcengine Coding Plan card")
        )
    }

    func testAgentPlanRejectionNamesTheAccessKeyNotALogin() {
        let message = VolcengineAgentPlanQuotaAdapter.rejectedKeyMessage
        XCTAssertTrue(message.contains("Access Key"))
        XCTAssertFalse(message.lowercased().contains("re-login"))
    }

    // MARK: - Kiro

    func testKiroMissingCLIExplainsHowToInstallIt() {
        XCTAssertTrue(KiroQuotaAdapter.cliNotFoundMessage.contains("kiro-cli"))
        XCTAssertTrue(KiroQuotaAdapter.cliNotFoundMessage.contains("kiro.dev"))
        XCTAssertEqual(
            QuotaError.parseFailure(KiroQuotaAdapter.cliNotFoundMessage).userFacingMessage,
            KiroQuotaAdapter.cliNotFoundMessage
        )
        // Both used to render as "No account found", which is what the
        // `.noCredential` mapping produced for a card the user had set up.
        XCTAssertNotEqual(
            QuotaError.parseFailure(KiroQuotaAdapter.cliFailedMessage).userFacingMessage,
            QuotaError.noCredential.userFacingMessage
        )
    }

    // MARK: - Z.ai region fallback

    func testZaiWithNoStoredRegionKeepsTheOtherHostAsAFallback() {
        let settings = ZaiSettings.resolve(environment: [:])
        XCTAssertEqual(settings.quotaURL, ZaiRegion.global.quotaURL)
        XCTAssertEqual(settings.fallbackQuotaURL, ZaiRegion.bigmodelCN.quotaURL)
    }

    func testZaiWithAnExplicitRegionHasNoFallback() {
        let settings = ZaiSettings.resolve(
            environment: [:],
            providerSettings: MiscProviderSettings(region: "bigmodel-cn")
        )
        XCTAssertEqual(settings.quotaURL, ZaiRegion.bigmodelCN.quotaURL)
        XCTAssertNil(settings.fallbackQuotaURL)
    }

    func testZaiEnvOverrideHasNoFallback() {
        let settings = ZaiSettings.resolve(environment: ["Z_AI_API_HOST": "https://zai.example.com"])
        XCTAssertNil(settings.fallbackQuotaURL)
    }

    /// The gap the Auto retry originally missed: the first host answers a
    /// perfectly good HTTP 200 whose envelope carries no limits, so nothing
    /// throws, the fetch "succeeds" with zero buckets, and the card renders
    /// "Not configured" without the other host ever being tried.
    func testAutoRetriesTheOtherHostWhenTheFirstReturnsNoBuckets() async throws {
        let settings = ZaiSettings(
            quotaURL: ZaiRegion.global.quotaURL,
            fallbackQuotaURL: ZaiRegion.bigmodelCN.quotaURL
        )
        let tried = Tried()

        let snapshot = try await ZaiQuotaAdapter.resolveSnapshot(settings: settings) { url in
            await tried.record(url)
            return url == ZaiRegion.bigmodelCN.quotaURL
                ? ZaiResponseParser.Snapshot(buckets: [Self.bucket], planName: "GLM Coding Plan")
                : ZaiResponseParser.Snapshot(buckets: [], planName: nil)
        }

        XCTAssertEqual(snapshot.buckets.map(\.id), ["zai.tokens"])
        let visited = await tried.urls
        XCTAssertEqual(visited, [ZaiRegion.global.quotaURL, ZaiRegion.bigmodelCN.quotaURL])
    }

    func testAHostThatAnswersWithBucketsIsAcceptedWithoutASecondCall() async throws {
        let settings = ZaiSettings(
            quotaURL: ZaiRegion.global.quotaURL,
            fallbackQuotaURL: ZaiRegion.bigmodelCN.quotaURL
        )
        let tried = Tried()

        _ = try await ZaiQuotaAdapter.resolveSnapshot(settings: settings) { url in
            await tried.record(url)
            return ZaiResponseParser.Snapshot(buckets: [Self.bucket], planName: nil)
        }

        let visited = await tried.urls
        XCTAssertEqual(visited, [ZaiRegion.global.quotaURL])
    }

    /// A pinned region has no fallback, so an empty answer is the answer.
    func testAPinnedRegionNeverTriesTheOtherHost() async throws {
        let settings = ZaiSettings(quotaURL: ZaiRegion.bigmodelCN.quotaURL)
        let tried = Tried()

        let snapshot = try await ZaiQuotaAdapter.resolveSnapshot(settings: settings) { url in
            await tried.record(url)
            return ZaiResponseParser.Snapshot(buckets: [], planName: nil)
        }

        XCTAssertTrue(snapshot.buckets.isEmpty)
        let visited = await tried.urls
        XCTAssertEqual(visited, [ZaiRegion.bigmodelCN.quotaURL])
    }

    /// Both hosts empty means the account really has no quota — keep the
    /// first host's answer rather than reporting the retry's.
    func testTwoEmptyHostsKeepTheFirstAnswer() async throws {
        let settings = ZaiSettings(
            quotaURL: ZaiRegion.global.quotaURL,
            fallbackQuotaURL: ZaiRegion.bigmodelCN.quotaURL
        )
        let snapshot = try await ZaiQuotaAdapter.resolveSnapshot(settings: settings) { _ in
            ZaiResponseParser.Snapshot(buckets: [], planName: "empty")
        }
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.planName, "empty")
    }

    /// A retry that throws must not replace a successful-but-empty first
    /// answer with the second host's error.
    func testAThrowingRetryDoesNotMaskTheFirstHostsAnswer() async throws {
        let settings = ZaiSettings(
            quotaURL: ZaiRegion.global.quotaURL,
            fallbackQuotaURL: ZaiRegion.bigmodelCN.quotaURL
        )
        let snapshot = try await ZaiQuotaAdapter.resolveSnapshot(settings: settings) { url in
            if url == ZaiRegion.bigmodelCN.quotaURL { throw QuotaError.rateLimited }
            return ZaiResponseParser.Snapshot(buckets: [], planName: "first")
        }
        XCTAssertEqual(snapshot.planName, "first")
    }

    func testAThrownWrongHostSignalStillRetries() async throws {
        let settings = ZaiSettings(
            quotaURL: ZaiRegion.global.quotaURL,
            fallbackQuotaURL: ZaiRegion.bigmodelCN.quotaURL
        )
        let snapshot = try await ZaiQuotaAdapter.resolveSnapshot(settings: settings) { url in
            if url == ZaiRegion.global.quotaURL {
                throw QuotaError.credentialRejected(ZaiQuotaAdapter.rejectedKeyMessage)
            }
            return ZaiResponseParser.Snapshot(buckets: [Self.bucket], planName: nil)
        }
        XCTAssertEqual(snapshot.buckets.map(\.id), ["zai.tokens"])
    }

    private static let bucket = QuotaBucket(
        id: "zai.tokens",
        title: "Tokens",
        shortLabel: "Tok",
        usedPercent: 12
    )

    /// Records the hosts a retry policy actually reached.
    private actor Tried {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    func testOnlyAmbiguousFailuresTriggerTheOtherHost() {
        XCTAssertTrue(ZaiQuotaAdapter.isWrongHostSignal(.credentialRejected("x")))
        XCTAssertTrue(ZaiQuotaAdapter.isWrongHostSignal(.needsLogin))
        XCTAssertTrue(ZaiQuotaAdapter.isWrongHostSignal(.parseFailure("Z.ai returned an empty body — …")))
        XCTAssertFalse(ZaiQuotaAdapter.isWrongHostSignal(.rateLimited))
        XCTAssertFalse(ZaiQuotaAdapter.isWrongHostSignal(.network("offline")))
        XCTAssertFalse(ZaiQuotaAdapter.isWrongHostSignal(.parseFailure("Z.ai response missing data envelope.")))
    }

    // MARK: - Credential field shape checks

    func testArkInferenceKeyIsRejectedByTheAgentPlanAccessKeyField() {
        let verdict = MiscCredentialFieldRules.check(
            tool: .volcengineAgentPlan,
            kind: .accessKeyID,
            value: "sk-0123456789abcdef"
        )
        XCTAssertFalse(verdict.allowsSave)
        let message = verdict.message ?? ""
        XCTAssertTrue(message.contains("Ark inference key"))
        XCTAssertTrue(message.contains("AKLT"))
    }

    func testWellFormedAccessKeyIDIsAccepted() {
        let verdict = MiscCredentialFieldRules.check(
            tool: .volcengineAgentPlan,
            kind: .accessKeyID,
            value: "AKLTexampleexampleexample"
        )
        XCTAssertEqual(verdict, .accepted)
    }

    func testUnrecognizedAccessKeyShapeWarnsButStillSaves() {
        let verdict = MiscCredentialFieldRules.check(
            tool: .volcengineAgentPlan,
            kind: .accessKeyID,
            value: "AKAPexampleexample"
        )
        XCTAssertTrue(verdict.allowsSave)
        XCTAssertNotNil(verdict.message)
    }

    func testSecretAccessKeyHasNoShapeRule() {
        XCTAssertEqual(
            MiscCredentialFieldRules.check(
                tool: .volcengineAgentPlan,
                kind: .secretAccessKey,
                value: "whatever-base64=="
            ),
            .accepted
        )
    }

    func testApiKeyPrefixWarnings() {
        XCTAssertEqual(
            MiscCredentialFieldRules.check(tool: .warp, kind: .apiKey, value: "wk-abc"),
            .accepted
        )
        XCTAssertTrue(
            MiscCredentialFieldRules.check(tool: .warp, kind: .apiKey, value: "abc").allowsSave
        )
        XCTAssertNotNil(
            MiscCredentialFieldRules.check(tool: .warp, kind: .apiKey, value: "abc").message
        )

        XCTAssertEqual(
            MiscCredentialFieldRules.check(tool: .openRouter, kind: .apiKey, value: "sk-or-v1-abc"),
            .accepted
        )
        XCTAssertNotNil(
            MiscCredentialFieldRules.check(tool: .openRouter, kind: .apiKey, value: "sk-abc").message
        )

        XCTAssertEqual(
            MiscCredentialFieldRules.check(tool: .minimax, kind: .apiKey, value: "sk-cp-abc"),
            .accepted
        )
        XCTAssertNotNil(
            MiscCredentialFieldRules.check(tool: .minimax, kind: .apiKey, value: "eyJhbGciOi").message
        )

        // Z.ai issues `zai-…`; open.bigmodel.cn issues `<id>.<secret>`.
        XCTAssertEqual(
            MiscCredentialFieldRules.check(tool: .zai, kind: .apiKey, value: "zai-abc"),
            .accepted
        )
        XCTAssertEqual(
            MiscCredentialFieldRules.check(tool: .zai, kind: .apiKey, value: "abc123.def456"),
            .accepted
        )
        XCTAssertNotNil(
            MiscCredentialFieldRules.check(tool: .zai, kind: .apiKey, value: "abc123").message
        )
    }

    func testProvidersWithoutARuleAreNeverBlocked() {
        for tool in [ToolType.kilo, .kimi, .iflytek, .baiduQianfan, .copilot] {
            XCTAssertEqual(
                MiscCredentialFieldRules.check(tool: tool, kind: .apiKey, value: "anything"),
                .accepted,
                "\(tool.rawValue) should have no shape rule"
            )
        }
    }

    func testEmptyValueIsNeverRejected() {
        XCTAssertEqual(
            MiscCredentialFieldRules.check(tool: .volcengineAgentPlan, kind: .accessKeyID, value: "   "),
            .accepted
        )
    }

    // MARK: - Manual cookie sentinels

    func testVolcengineCookieWithoutCsrfTokenIsRejected() {
        let message = MiscManualCookieRules.rejectionMessage(
            for: .volcengine,
            header: "AccountID=1; cna=abc"
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("csrfToken") ?? false)
        XCTAssertTrue(message?.contains("Ark console") ?? false)
    }

    func testVolcengineCookieWithCsrfTokenIsAccepted() {
        XCTAssertNil(
            MiscManualCookieRules.rejectionMessage(
                for: .volcengine,
                header: "csrfToken=abc; AccountID=1"
            )
        )
    }

    func testTencentNeedsBothSkeyAndUin() {
        XCTAssertNotNil(
            MiscManualCookieRules.rejectionMessage(for: .tencentHunyuan, header: "skey=abc")
        )
        XCTAssertNotNil(
            MiscManualCookieRules.rejectionMessage(for: .tencentTokenPlan, header: "uin=o123")
        )
        XCTAssertNil(
            MiscManualCookieRules.rejectionMessage(
                for: .tencentTokenPlan,
                header: "skey=abc; uin=o123"
            )
        )
    }

    func testEmptyCookieValueDoesNotCountAsPresent() {
        XCTAssertNotNil(
            MiscManualCookieRules.rejectionMessage(for: .volcengine, header: "csrfToken=; cna=abc")
        )
    }

    func testOllamaNeedsARecognizedSessionCookie() {
        XCTAssertNotNil(
            MiscManualCookieRules.rejectionMessage(for: .ollama, header: "ph_phc_x=1")
        )
        XCTAssertNil(
            MiscManualCookieRules.rejectionMessage(for: .ollama, header: "session=abc")
        )
        XCTAssertNil(
            MiscManualCookieRules.rejectionMessage(
                for: .ollama,
                header: "next-auth.session-token=abc"
            )
        )
    }

    /// Alibaba, Baidu and iFlytek stitch identity from HttpOnly tickets
    /// with no single load-bearing name, so a paste there must not be
    /// second-guessed.
    func testProvidersWithoutASentinelAcceptAnyHeader() {
        for tool in [ToolType.alibaba, .alibabaTokenPlan, .baiduQianfan, .iflytek] {
            XCTAssertTrue(MiscManualCookieRules.requiredCookieNames(for: tool).isEmpty)
            XCTAssertNil(MiscManualCookieRules.rejectionMessage(for: tool, header: "anything=1"))
        }
    }
}
