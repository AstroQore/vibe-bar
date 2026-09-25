import XCTest
@testable import VibeBarCore

/// Covers the silent OIDC refresh of `~/.grok/auth.json`: parsing the
/// refresh fields, the token-endpoint exchange, the write-back into a
/// temporary home, the adapter's fallbacks, and single-flight. Every
/// request is answered by `GrokRefreshStubURLProtocol`; nothing leaves
/// the process.
final class GrokOAuthRefreshTests: XCTestCase {
    private static let scope = "https://auth.x.ai::00000000-0000-4000-8000-000000000001"
    private static let clientID = "00000000-0000-4000-8000-0000000000c1"
    /// Frozen clock for the adapter: 2026-09-24T18:00:00Z.
    private static let fixedNow = Date(timeIntervalSince1970: 1_790_272_800)

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-grok-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok", isDirectory: true),
            withIntermediateDirectories: true
        )
        GrokRefreshStubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        GrokRefreshStubURLProtocol.reset()
    }

    // MARK: - Parsing

    func testParsesRefreshFieldsAndMicrosecondExpiry() throws {
        let creds = try GrokCredentialsStore.parse(data: Data(Self.authJSON(
            key: "old-bearer",
            refreshToken: "refresh-1",
            expiresAt: "2026-09-24T12:34:06.184521Z"
        ).utf8))
        XCTAssertEqual(creds.refreshToken, "refresh-1")
        XCTAssertEqual(creds.oidcClientID, Self.clientID)
        XCTAssertEqual(creds.oidcIssuer, "https://auth.x.ai")
        XCTAssertTrue(creds.canRefresh)
        let expiresAt = try XCTUnwrap(creds.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_790_253_246.184, accuracy: 0.01)
    }

    func testForeignIssuerIsNotRefreshable() throws {
        let json = Self.authJSON(key: "k", refreshToken: "r", expiresAt: "2020-01-01T00:00:00Z")
            .replacingOccurrences(of: "\"https://auth.x.ai\"", with: "\"https://issuer.example.com\"")
        XCTAssertFalse(try GrokCredentialsStore.parse(data: Data(json.utf8)).canRefresh)
    }

    func testFormatDateMatchesCLIShape() {
        let formatted = GrokCredentialsStore.formatDate(Date(timeIntervalSince1970: 1_790_253_246.5))
        XCTAssertEqual(formatted, "2026-09-24T12:34:06.500000Z")
    }

    // MARK: - Adapter: expired bearer is refreshed and written back

    func testExpiredBearerRefreshesWritesBackAndFetches() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: ["new-bearer"],
            tokenResponse: (200, #"{"access_token":"new-bearer","refresh_token":"refresh-2","expires_in":21600,"token_type":"Bearer"}"#)
        )

        let quota = try await makeAdapter().fetch(for: Self.account)
        XCTAssertEqual(quota.buckets.first?.usedPercent ?? -1, 42, accuracy: 0.01)

        let state = GrokRefreshStubURLProtocol.snapshot()
        XCTAssertEqual(state.tokenRequests.count, 1)
        let token = try XCTUnwrap(state.tokenRequests.first)
        XCTAssertEqual(token.url, GrokOAuthTokenRefresher.tokenEndpoint)
        XCTAssertEqual(token.method, "POST")
        XCTAssertEqual(token.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(token.form["grant_type"], "refresh_token")
        XCTAssertEqual(token.form["refresh_token"], "refresh-1")
        XCTAssertEqual(token.form["client_id"], Self.clientID)
        XCTAssertNil(token.form["scope"])
        XCTAssertFalse(state.billingBearers.contains("old-bearer"), "An expired bearer must not be spent")

        // Write-back: rotated token, new expiry, everything else intact.
        let root = try readAuthRoot()
        let entry = try XCTUnwrap(root[Self.scope] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "new-bearer")
        XCTAssertEqual(entry["refresh_token"] as? String, "refresh-2")
        XCTAssertEqual(entry["expires_at"] as? String, "2026-09-25T00:00:00.000000Z")
        XCTAssertEqual(entry["last_refresh"] as? String, "2026-09-24T18:00:00.000000Z")
        XCTAssertEqual(entry["email"] as? String, "user@example.com")
        XCTAssertEqual(entry["auth_mode"] as? String, "oidc")
        XCTAssertEqual(entry["oidc_client_id"] as? String, Self.clientID)
        XCTAssertEqual(entry["coding_data_retention_opt_out"] as? Bool, false)
        XCTAssertEqual(entry["create_time"] as? String, "2026-09-24T06:00:00.000000Z")
        let legacy = try XCTUnwrap(root["https://accounts.x.ai/sign-in"] as? [String: Any])
        XCTAssertEqual(legacy["key"] as? String, "legacy-token")

        let mode = try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: authURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["auth.json"], "The staging file must not be left behind")

        // The next load sees a fresh bearer and does not refresh again.
        let reloaded = try GrokCredentialsStore.load(homeDirectory: home.path)
        XCTAssertFalse(reloaded.expiresSoon(at: Self.fixedNow))
    }

    func testRefreshWithoutRotationKeepsRefreshToken() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "refresh-keep", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: ["new-bearer"],
            tokenResponse: (200, #"{"access_token":"new-bearer","expires_in":3600}"#)
        )

        _ = try await makeAdapter().fetch(for: Self.account)

        let entry = try XCTUnwrap(try readAuthRoot()[Self.scope] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "new-bearer")
        XCTAssertEqual(entry["refresh_token"] as? String, "refresh-keep")
        XCTAssertEqual(entry["expires_at"] as? String, "2026-09-24T19:00:00.000000Z")
    }

    func testBearerInsideLeewayIsRefreshedFirst() async throws {
        // 30 s before expiry is inside the 60 s leeway.
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T18:00:30.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: ["old-bearer", "new-bearer"],
            tokenResponse: (200, #"{"access_token":"new-bearer","expires_in":21600}"#)
        )

        _ = try await makeAdapter().fetch(for: Self.account)

        let state = GrokRefreshStubURLProtocol.snapshot()
        XCTAssertEqual(state.tokenRequests.count, 1)
        XCTAssertEqual(state.billingBearers, ["new-bearer"])
    }

    // MARK: - Adapter: refusal and fallbacks

    func testRejectedRefreshFallsBackToCookies() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "revoked", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: [],
            validCookie: "sso=web",
            tokenResponse: (400, #"{"error":"invalid_grant"}"#)
        )

        let quota = try await makeAdapter(cookie: "sso=web").fetch(for: Self.account)
        XCTAssertEqual(quota.buckets.first?.usedPercent ?? -1, 42, accuracy: 0.01)
        let entry = try XCTUnwrap(try readAuthRoot()[Self.scope] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "old-bearer", "A refused refresh must not touch auth.json")
    }

    func testRejectedRefreshWithoutCookiesNeedsLogin() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "revoked", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(validBearers: [], tokenResponse: (401, #"{"error":"invalid_client"}"#))

        await assertFetchThrows(.needsLogin)
    }

    func testRefreshOutageIsNetworkErrorNotNeedsLogin() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(validBearers: [], tokenResponse: (503, "unavailable"))

        do {
            _ = try await makeAdapter().fetch(for: Self.account)
            XCTFail("Expected a network error")
        } catch let error as QuotaError {
            guard case .network = error else { return XCTFail("Expected .network, got \(error)") }
        }
    }

    func testUnauthorizedBearerRefreshesOnceAndRetries() async throws {
        // Not expired by the clock, but the IdP already revoked it.
        try writeAuth(Self.authJSON(key: "revoked-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T23:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: ["new-bearer"],
            tokenResponse: (200, #"{"access_token":"new-bearer","refresh_token":"refresh-2","expires_in":21600}"#)
        )

        let quota = try await makeAdapter().fetch(for: Self.account)
        XCTAssertEqual(quota.buckets.first?.usedPercent ?? -1, 42, accuracy: 0.01)

        let state = GrokRefreshStubURLProtocol.snapshot()
        XCTAssertEqual(state.tokenRequests.count, 1)
        XCTAssertEqual(state.billingBearers, ["revoked-bearer", "new-bearer"])
    }

    func testFreshlyRefreshedBearerRefusedIsNotRefreshedAgain() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: [],
            tokenResponse: (200, #"{"access_token":"new-bearer","expires_in":21600}"#)
        )

        await assertFetchThrows(.needsLogin)
        XCTAssertEqual(GrokRefreshStubURLProtocol.snapshot().tokenRequests.count, 1)
    }

    func testExpiredLegacyEntryWithoutRefreshTokenIsUnchanged() async throws {
        try writeAuth("""
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "web_login",
            "expires_at": "2020-01-01T00:00:00Z"
          }
        }
        """)
        GrokRefreshStubURLProtocol.configure(validBearers: ["legacy-token"], tokenResponse: (200, "{}"))

        await assertFetchThrows(.noCredential)
        let state = GrokRefreshStubURLProtocol.snapshot()
        XCTAssertTrue(state.tokenRequests.isEmpty)
        XCTAssertTrue(state.billingBearers.isEmpty)
    }

    // MARK: - Refresher: single flight and options

    func testConcurrentRefreshesShareOneExchange() async throws {
        try writeAuth(Self.authJSON(key: "old-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T12:00:00.000000Z"))
        GrokRefreshStubURLProtocol.configure(
            validBearers: [],
            tokenResponse: (200, #"{"access_token":"new-bearer","refresh_token":"refresh-2","expires_in":21600}"#),
            tokenDelay: 0.3
        )
        let creds = try GrokCredentialsStore.load(homeDirectory: home.path)
        let refresher = GrokOAuthTokenRefresher()
        let session = Self.stubSession()
        let homePath = home.path

        async let a = refresher.refresh(creds, session: session, homeDirectory: homePath, now: { Self.fixedNow })
        async let b = refresher.refresh(creds, session: session, homeDirectory: homePath, now: { Self.fixedNow })
        let (first, second) = try await (a, b)

        XCTAssertEqual(first.accessToken, "new-bearer")
        XCTAssertEqual(second.accessToken, "new-bearer")
        XCTAssertEqual(GrokRefreshStubURLProtocol.snapshot().tokenRequests.count, 1)

        // A caller that loaded auth.json before the write-back still
        // holds the spent refresh token; it gets the same result rather
        // than a second exchange that rotation would refuse.
        let late = try await refresher.refresh(creds, session: session, homeDirectory: homePath, now: { Self.fixedNow })
        XCTAssertEqual(late.accessToken, "new-bearer")
        XCTAssertEqual(late.refreshToken, "refresh-2")
        XCTAssertEqual(GrokRefreshStubURLProtocol.snapshot().tokenRequests.count, 1)
    }

    func testGrokCLIOptionsAddScopeAndHeaders() async throws {
        GrokRefreshStubURLProtocol.configure(
            validBearers: [],
            tokenResponse: (200, #"{"access_token":"new-bearer","expires_in":21600}"#)
        )
        let creds = try GrokCredentialsStore.parse(data: Data(Self.authJSON(
            key: "old-bearer", refreshToken: "refresh-1", expiresAt: "2026-09-24T12:00:00.000000Z"
        ).utf8))
        let refresher = GrokOAuthTokenRefresher(options: .grokCLI)

        _ = try await refresher.refresh(creds, session: Self.stubSession(), homeDirectory: home.path, persist: false)

        let token = try XCTUnwrap(GrokRefreshStubURLProtocol.snapshot().tokenRequests.first)
        XCTAssertEqual(token.form["scope"], "grok-build")
        XCTAssertEqual(token.headers["x-grok-client-version"], "1.0.41")
        XCTAssertEqual(token.headers["x-grok-client-surface"], "grok-build")
    }

    func testWriteBackSkipsWhenCLIAlreadyRotated() throws {
        try writeAuth(Self.authJSON(key: "cli-bearer", refreshToken: "cli-refresh", expiresAt: "2026-09-25T00:00:00.000000Z"))
        let creds = try GrokCredentialsStore.load(homeDirectory: home.path)
            .refreshed(accessToken: "ours", refreshToken: "ours-refresh", expiresAt: Self.fixedNow)

        let outcome = try GrokCredentialsStore.writeRefreshed(
            creds,
            previousRefreshToken: "spent-refresh",
            now: Self.fixedNow,
            homeDirectory: home.path
        )

        XCTAssertEqual(outcome, .superseded)
        let entry = try XCTUnwrap(try readAuthRoot()[Self.scope] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "cli-bearer")
    }

    // MARK: - Helpers

    private static let account = AccountIdentity(
        id: "oauth-grok",
        tool: .grok,
        alias: "Grok",
        source: .oauthCLI,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    private var authURL: URL { GrokCredentialsStore.authFileURL(homeDirectory: home.path) }

    private func writeAuth(_ json: String) throws {
        try Data(json.utf8).write(to: authURL)
    }

    private func readAuthRoot() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any])
    }

    private func makeAdapter(cookie: String? = nil) -> GrokQuotaAdapter {
        GrokQuotaAdapter(
            session: Self.stubSession(),
            homeDirectory: home.path,
            now: { Self.fixedNow },
            cookieHeader: { cookie },
            refresher: GrokOAuthTokenRefresher()
        )
    }

    private func assertFetchThrows(
        _ expected: QuotaError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await makeAdapter().fetch(for: Self.account)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as QuotaError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected QuotaError, got \(error)", file: file, line: line)
        }
    }

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokRefreshStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func authJSON(key: String, refreshToken: String, expiresAt: String) -> String {
        """
        {
          "\(scope)": {
            "key": "\(key)",
            "auth_mode": "oidc",
            "create_time": "2026-09-24T06:00:00.000000Z",
            "expires_at": "\(expiresAt)",
            "refresh_token": "\(refreshToken)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "\(clientID)",
            "email": "user@example.com",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "user_id": "user-uuid",
            "team_id": "team-uuid",
            "principal_type": "user",
            "principal_id": "principal-uuid",
            "profile_image_asset_id": "asset-uuid",
            "coding_data_retention_opt_out": false
          },
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "session"
          }
        }
        """
    }
}

/// Answers the token endpoint, the billing RPC, and the two enrichment
/// calls. A bearer or cookie in the configured valid set gets a 42 %
/// weekly snapshot; anything else gets 401.
private final class GrokRefreshStubURLProtocol: URLProtocol {
    struct TokenRequest {
        var url: URL?
        var method: String?
        var contentType: String?
        var headers: [String: String]
        var form: [String: String]
    }

    struct State {
        var validBearers: Set<String> = []
        var validCookie: String?
        var tokenResponse: (Int, String) = (500, "")
        var tokenDelay: TimeInterval = 0
        var tokenRequests: [TokenRequest] = []
        var billingBearers: [String] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset() {
        lock.withLock { state = State() }
    }

    static func configure(
        validBearers: Set<String>,
        validCookie: String? = nil,
        tokenResponse: (Int, String),
        tokenDelay: TimeInterval = 0
    ) {
        lock.withLock {
            state.validBearers = validBearers
            state.validCookie = validCookie
            state.tokenResponse = tokenResponse
            state.tokenDelay = tokenDelay
        }
    }

    static func snapshot() -> State {
        lock.withLock { state }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url.host == "auth.x.ai" {
            let body = Self.body(of: request)
            let form = Self.parseForm(body)
            var headers: [String: String] = [:]
            for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key.lowercased()] = value }
            let (status, payload, delay) = Self.lock.withLock { () -> (Int, String, TimeInterval) in
                Self.state.tokenRequests.append(TokenRequest(
                    url: url,
                    method: request.httpMethod,
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    headers: headers,
                    form: form
                ))
                return (Self.state.tokenResponse.0, Self.state.tokenResponse.1, Self.state.tokenDelay)
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            respond(status: status, contentType: "application/json", body: Data(payload.utf8))
            return
        }

        let bearer = request.value(forHTTPHeaderField: "Authorization")
            .map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        let cookie = request.value(forHTTPHeaderField: "Cookie")
        let isBilling = url.path.hasSuffix("GetGrokCreditsConfig")
        let authorized = Self.lock.withLock { () -> Bool in
            if isBilling, let bearer { Self.state.billingBearers.append(bearer) }
            if let bearer { return Self.state.validBearers.contains(bearer) }
            if let cookie { return cookie == Self.state.validCookie }
            return false
        }
        guard authorized else {
            respond(status: 401, contentType: "text/plain", body: Data("unauthorized".utf8))
            return
        }
        if isBilling {
            respond(status: 200, contentType: "application/grpc-web+proto", body: Self.billingFrame())
        } else {
            respond(status: 404, contentType: "text/plain", body: Data())
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, contentType: String, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseForm(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    /// One gRPC-web data frame: fixed32 used-percent 42, varint reset.
    private static func billingFrame() -> Data {
        var payload = Data([0x0D])
        var bits = Float(42).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        payload.append(0x10)
        var value: UInt64 = 1_800_000_000
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            payload.append(byte)
        } while value != 0
        var frame = Data([0x00])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}
