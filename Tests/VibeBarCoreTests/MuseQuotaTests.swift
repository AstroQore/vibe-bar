import XCTest
@testable import VibeBarCore

/// Meta AI · Muse Code quota: the `/muse-code/key` response, the CLI login
/// split between `auth.json` and the Keychain, and the adapter between them.
/// Every fixture is synthetic — `user@example.com`, placeholder tokens.
final class MuseResponseParserTests: XCTestCase {
    private let fullResponse = #"""
    {
      "api_key": "LLM|0000000000000000|synthetic-key-never-read",
      "base_url": "https://api.meta.ai/v1",
      "is_subs_active": true,
      "user_email": "user@example.com",
      "subs_tier_id": "1",
      "subs_tier_name": "Muse Code High Usage",
      "subs_usage": {
        "window": { "used_percent": 12, "window_duration_mins": 300, "resets_at": 1789607748 },
        "weekly": { "used_percent": 3.5, "resets_at": 1789948800 },
        "tier": "1"
      }
    }
    """#

    func testParsesBothWindowsAndTheTier() throws {
        let snapshot = try MuseResponseParser.parse(data: Data(fullResponse.utf8))

        XCTAssertEqual(snapshot.buckets.map(\.id), ["five_hour", "weekly"])
        let fiveHour = snapshot.buckets[0]
        XCTAssertEqual(fiveHour.usedPercent, 12)
        XCTAssertEqual(fiveHour.rawWindowSeconds, 18_000)
        XCTAssertEqual(fiveHour.resetAt, Date(timeIntervalSince1970: 1_789_607_748))
        let weekly = snapshot.buckets[1]
        XCTAssertEqual(weekly.usedPercent, 3.5)
        XCTAssertEqual(weekly.rawWindowSeconds, 604_800)
        XCTAssertEqual(weekly.resetAt, Date(timeIntervalSince1970: 1_789_948_800))
        XCTAssertEqual(snapshot.tierName, "Muse Code High Usage")
        XCTAssertEqual(snapshot.email, "user@example.com")
        XCTAssertEqual(snapshot.isSubscriptionActive, true)
    }

    /// The response hands back the account's API key. The parser names only
    /// the fields it keeps, so the key has no path into a bucket, a plan, or
    /// anything else that is cached or shown.
    func testTheAPIKeyReachesNothingTheParserReturns() throws {
        let snapshot = try MuseResponseParser.parse(data: Data(fullResponse.utf8))
        let rendered = String(describing: snapshot)
        XCTAssertFalse(rendered.contains("synthetic-key-never-read"))
        XCTAssertFalse(rendered.contains("LLM|"))
    }

    func testAWindowOtherThanFiveHoursKeepsItsOwnLength() throws {
        let json = #"{"subs_usage":{"window":{"used_percent":40,"window_duration_mins":480,"resets_at":1789607748}}}"#
        let snapshot = try MuseResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.buckets.map(\.id), ["8h_window", "weekly"])
        XCTAssertEqual(snapshot.buckets.first?.rawWindowSeconds, 28_800)
    }

    func testAnIdleWeekIsZeroWithNoResetRatherThanMissing() throws {
        let json = #"{"subs_usage":{"window":{"used_percent":0,"window_duration_mins":300,"resets_at":1789607748}}}"#
        let snapshot = try MuseResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.buckets.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(snapshot.buckets[1].usedPercent, 0)
        XCTAssertNil(snapshot.buckets[1].resetAt)
        XCTAssertNil(snapshot.tierName)
    }

    /// Captured from the live endpoint: once both windows lapse with nothing
    /// spent, an active subscription reports `subs_usage: null`. That is an
    /// idle account, not a broken response.
    func testAnActiveSubscriptionWithNoUsageReportsTwoIdleWindows() throws {
        let json = #"{"api_key":"LLM|synthetic","is_subs_active":true,"subs_tier_name":"Muse Code High Usage","subs_usage":null}"#
        let snapshot = try MuseResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.buckets.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(snapshot.buckets.map(\.usedPercent), [0, 0])
        XCTAssertEqual(snapshot.buckets.map(\.rawWindowSeconds), [18_000, 604_800])
        XCTAssertTrue(snapshot.buckets.allSatisfy { $0.resetAt == nil })
        XCTAssertEqual(snapshot.tierName, "Muse Code High Usage")
    }

    func testAnInactiveSubscriptionSaysSo() {
        let json = #"{"is_subs_active":false,"subs_usage":null}"#
        XCTAssertThrowsError(try MuseResponseParser.parse(data: Data(json.utf8))) { error in
            guard case let QuotaError.parseFailure(message) = error else {
                return XCTFail("expected parseFailure, got \(error)")
            }
            XCTAssertTrue(message.contains("subscription"))
        }
    }

    func testNonJSONIsAParseFailure() {
        XCTAssertThrowsError(try MuseResponseParser.parse(data: Data("<html>".utf8)))
    }
}

final class MuseCredentialReaderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarMuseCredentialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeAuthFile(_ json: String) throws {
        let url = MuseCredentialReader.authFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private let keychainAuthFile = #"""
    {"schema_version":1,"providers":{"meta":{"mechanism":"oauth","storage":"keychain",
    "obtained_via":"device_code","api_base_url":"https://api.meta.ai/v1",
    "user_full_name":"Example User","user_email":"user@example.com"}}}
    """#

    func testTheAuthFileLivesUnderDotConfig() {
        XCTAssertEqual(
            MuseCredentialReader.authFileURL(homeDirectory: "/Users/example").path,
            "/Users/example/.config/muse/auth.json"
        )
    }

    func testNoAuthFileMeansNoLogin() {
        XCTAssertFalse(MuseCredentialReader.hasLogin(homeDirectory: home.path))
        XCTAssertThrowsError(try MuseCredentialReader.load(homeDirectory: home.path) { "unused" }) { error in
            XCTAssertEqual(error as? QuotaError, .noCredential)
        }
    }

    func testTheTokenComesFromTheKeychainPayload() throws {
        try writeAuthFile(keychainAuthFile)
        let credential = try MuseCredentialReader.load(homeDirectory: home.path) {
            #"{"secret_schema_version":1,"api_key":"LLM|synthetic","access_token":"dca:synthetic-token"}"#
        }
        XCTAssertEqual(credential.accessToken, "dca:synthetic-token")
        XCTAssertEqual(credential.email, "user@example.com")
        XCTAssertEqual(credential.fullName, "Example User")
    }

    func testAKeychainThatWillNotAnswerWithoutAPromptIsReportedAsSuch() throws {
        try writeAuthFile(keychainAuthFile)
        XCTAssertThrowsError(
            try MuseCredentialReader.load(homeDirectory: home.path) {
                throw KeychainStore.KeychainError.interactionNotAllowed
            }
        ) { error in
            XCTAssertEqual(error as? KeychainStore.KeychainError, .interactionNotAllowed)
        }
    }

    func testAMissingKeychainItemMeansTheLoginIsGone() throws {
        try writeAuthFile(keychainAuthFile)
        XCTAssertThrowsError(
            try MuseCredentialReader.load(homeDirectory: home.path) {
                throw KeychainStore.KeychainError.itemNotFound
            }
        ) { error in
            XCTAssertEqual(error as? QuotaError, .needsLogin)
        }
    }

    func testAPayloadWithoutAnAccessTokenNeedsLogin() {
        XCTAssertThrowsError(try MuseCredentialReader.decodeSecret(#"{"api_key":"LLM|synthetic"}"#)) { error in
            XCTAssertEqual(error as? QuotaError, .needsLogin)
        }
    }

    func testAFileBackedLoginCarriesItsTokenInline() throws {
        try writeAuthFile(#"""
        {"providers":{"meta":{"mechanism":"oauth","storage":"file","access_token":"dca:inline-token"}}}
        """#)
        let credential = try MuseCredentialReader.load(homeDirectory: home.path) {
            XCTFail("a file-backed login must not touch the Keychain")
            return ""
        }
        XCTAssertEqual(credential.accessToken, "dca:inline-token")
    }
}

final class MuseQuotaAdapterTests: XCTestCase {
    private let account = AccountIdentity(id: "oauth-muse", tool: .muse, source: .oauthCLI)
    private let credential = MuseCredential(accessToken: "dca:synthetic-token", email: "user@example.com", fullName: nil)

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MuseStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MuseStubURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(status: Int, body: String) {
        MuseStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    func testTheRequestIsTheCLIsOwnKeyCall() throws {
        let request = MuseQuotaAdapter.makeRequest(token: "dca:synthetic-token")
        XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/muse-code/key")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dca:synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-version"), "1.0.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpShouldHandleCookies, false)
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }

    func testASuccessfulFetchBecomesTheQuota() async throws {
        respond(status: 200, body: #"""
        {"api_key":"LLM|synthetic","subs_tier_name":"Muse Code High Usage","user_email":"user@example.com",
         "subs_usage":{"window":{"used_percent":20,"window_duration_mins":300,"resets_at":1789607748},
                       "weekly":{"used_percent":7,"resets_at":1789948800}}}
        """#)
        let now = Date(timeIntervalSince1970: 1_789_600_000)
        let credential = self.credential
        let adapter = MuseQuotaAdapter(session: session(), now: { now }, credential: { credential })

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.tool, .muse)
        XCTAssertEqual(quota.accountId, "oauth-muse")
        XCTAssertEqual(quota.buckets.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(quota.plan, "Muse Code High Usage")
        XCTAssertEqual(quota.email, "user@example.com")
        XCTAssertEqual(quota.queriedAt, now)
    }

    func testARejectedTokenNeedsLogin() async {
        respond(status: 401, body: "{}")
        let credential = self.credential
        let adapter = MuseQuotaAdapter(session: session(), credential: { credential })
        await assertFetchThrows(adapter, .needsLogin)
    }

    func testThrottlingIsRateLimited() async {
        respond(status: 429, body: "{}")
        let credential = self.credential
        let adapter = MuseQuotaAdapter(session: session(), credential: { credential })
        await assertFetchThrows(adapter, .rateLimited)
    }

    func testAServerErrorIsANetworkError() async {
        respond(status: 503, body: "{}")
        let credential = self.credential
        let adapter = MuseQuotaAdapter(session: session(), credential: { credential })
        await assertFetchThrows(adapter, .network("server 503"))
    }

    /// Until macOS has been told Vibe Bar may read the CLI's Keychain item,
    /// the card has to say where to allow it — never "sign in again".
    func testAKeychainAwaitingPermissionPointsAtTheSettingsPage() async {
        let adapter = MuseQuotaAdapter(session: session(), credential: {
            throw KeychainStore.KeychainError.interactionNotAllowed
        })
        await assertFetchThrows(adapter, .credentialRejected(L10n.Quota.Muse.keychainAccessNeeded))
    }

    func testNoLoginIsNoCredential() async {
        let adapter = MuseQuotaAdapter(session: session(), credential: { throw QuotaError.noCredential })
        await assertFetchThrows(adapter, .noCredential)
    }

    private func assertFetchThrows(
        _ adapter: MuseQuotaAdapter,
        _ expected: QuotaError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await adapter.fetch(for: account)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? QuotaError, expected, file: file, line: line)
        }
    }
}

private final class MuseStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
