import XCTest
@testable import VibeBarCore

final class ComponentVersionTests: XCTestCase {
    func testParsesBareAndPrefixedTags() {
        XCTAssertEqual(ComponentVersion("0.3.0"), ComponentVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(ComponentVersion("v1.2.3"), ComponentVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(ComponentVersion("  0.3.0\n"), ComponentVersion(major: 0, minor: 3, patch: 0))
        // Build metadata does not participate in precedence.
        XCTAssertEqual(ComponentVersion("0.3.0+deadbeef"), ComponentVersion(major: 0, minor: 3, patch: 0))
    }

    func testRejectsAnythingThatIsNotThreeNumbers() {
        for bad in ["", "1", "1.2", "1.2.3.4", "1.2.x", "one.two.three", "1.2.-3", "v", "1.2.3-"] {
            XCTAssertNil(ComponentVersion(bad), bad)
        }
    }

    func testOrdersByMajorThenMinorThenPatch() {
        let ascending = ["0.1.0", "0.2.0", "0.2.1", "0.3.0", "0.10.0", "1.0.0", "1.0.1", "2.0.0"]
            .map { ComponentVersion($0)! }
        for (lower, higher) in zip(ascending, ascending.dropFirst()) {
            XCTAssertLessThan(lower, higher, "\(lower) should precede \(higher)")
        }
        // The one a string comparison gets wrong.
        XCTAssertLessThan(ComponentVersion("0.9.0")!, ComponentVersion("0.10.0")!)
    }

    func testAPreReleasePrecedesItsRelease() {
        XCTAssertLessThan(ComponentVersion("0.4.0-rc.1")!, ComponentVersion("0.4.0")!)
        XCTAssertLessThan(ComponentVersion("0.4.0-rc.1")!, ComponentVersion("0.4.0-rc.2")!)
        XCTAssertLessThan(ComponentVersion("0.4.0-alpha")!, ComponentVersion("0.4.0-beta")!)
        // Numeric identifiers rank below alphanumeric ones (semver § 11.4.3).
        XCTAssertLessThan(ComponentVersion("0.4.0-1")!, ComponentVersion("0.4.0-alpha")!)
        // A pre-release of a higher version still wins on the numbers.
        XCTAssertLessThan(ComponentVersion("0.3.0")!, ComponentVersion("0.4.0-rc.1")!)
    }

    func testDescriptionRoundTrips() {
        XCTAssertEqual(ComponentVersion("0.3.0")!.description, "0.3.0")
        XCTAssertEqual(ComponentVersion("v0.4.0-rc.1")!.description, "0.4.0-rc.1")
    }
}

final class ComponentUpdateStatusTests: XCTestCase {
    func testEqualVersionsReadAsUpToDate() {
        let status = ComponentUpdateChecker.status(bundled: "0.3.0", latest: "0.3.0")
        XCTAssertEqual(status, .upToDate(bundled: "0.3.0"))
        XCTAssertEqual(status.message, "Up to date (0.3.0)")
        XCTAssertNil(status.releaseNotesURL)
    }

    /// The sentence that must never imply an in-place update: the kit is
    /// linked statically, so a newer release arrives with the next build.
    func testANewerReleaseShipsWithTheNextBuild() {
        let status = ComponentUpdateChecker.status(bundled: "0.3.0", latest: "0.4.0")
        XCTAssertEqual(
            status,
            .updateAvailable(
                bundled: "0.3.0",
                latest: "0.4.0",
                releaseNotesURL: URL(string: "https://github.com/AstroQore/agent-session-kit/releases/tag/0.4.0")!
            )
        )
        XCTAssertEqual(
            status.message,
            "Newer kit 0.4.0 available — ships with the next Vibe Bar build"
        )
        XCTAssertEqual(
            status.releaseNotesURL?.absoluteString,
            "https://github.com/AstroQore/agent-session-kit/releases/tag/0.4.0"
        )
        XCTAssertFalse(status.message.lowercased().contains("install"))
        XCTAssertFalse(status.message.lowercased().contains("download"))
        XCTAssertFalse(status.message.lowercased().contains("update now"))
    }

    /// Normal between a kit merge and its tag, or while developing against
    /// an unreleased kit through `swift package edit`.
    func testABundledVersionAheadOfTheNewestReleaseSaysSo() {
        let status = ComponentUpdateChecker.status(bundled: "0.4.0", latest: "0.3.0")
        XCTAssertEqual(status, .aheadOfLatestRelease(bundled: "0.4.0", latest: "0.3.0"))
        XCTAssertEqual(status.message, "Bundled 0.4.0 is ahead of the newest release (0.3.0)")
    }

    func testAnUnparseableTagIsAFailureRatherThanAQuietUpToDate() {
        let status = ComponentUpdateChecker.status(bundled: "0.3.0", latest: "latest")
        XCTAssertTrue(status.isFailure)
        XCTAssertEqual(status.message, "Could not check for kit updates: unrecognised tag")
    }

    /// The version actually compiled into this build is what the row shows,
    /// and it has to be readable as a version.
    func testTheBundledKitVersionIsAVersion() {
        XCTAssertNotNil(ComponentVersion(AgentSessionKitInfo.version))
        XCTAssertEqual(
            AgentSessionKitInfo.bundledReleaseNotesURL.absoluteString,
            "https://github.com/AstroQore/agent-session-kit/releases/tag/\(AgentSessionKitInfo.version)"
        )
    }
}

final class ComponentUpdateCheckerTests: XCTestCase {
    override func tearDown() {
        KitReleaseStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeChecker(
        cacheLifetime: TimeInterval = ComponentUpdateChecker.defaultCacheLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ComponentUpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KitReleaseStubURLProtocol.self]
        return ComponentUpdateChecker(
            session: URLSession(configuration: config),
            endpoint: URL(string: "https://api.github.test/repos/AstroQore/agent-session-kit/releases/latest")!,
            cacheLifetime: cacheLifetime,
            now: now
        )
    }

    func testReadsTheTagOutOfAReleasePayload() async throws {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "VibeBar")
            // Unauthenticated, always.
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpShouldHandleCookies, false)
            return (Self.ok(request), Data(#"""
            {"tag_name":"0.4.0","name":"agent-session-kit 0.4.0","draft":false,
             "prerelease":false,"html_url":"https://github.com/AstroQore/agent-session-kit/releases/tag/0.4.0",
             "body":"notes","assets":[]}
            """#.utf8))
        }
        let version = try await makeChecker().latestKitVersion()
        XCTAssertEqual(version, "0.4.0")
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 1)
    }

    func testNormalisesAVPrefixedTag() async throws {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            (Self.ok(request), Data(#"{"tag_name":"v1.0.0"}"#.utf8))
        }
        let version = try await makeChecker().latestKitVersion()
        XCTAssertEqual(version, "1.0.0")
    }

    func testARepositoryWithNoPublishedReleaseIsItsOwnReason() async {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            (Self.status(404, request), Data(#"{"message":"Not Found"}"#.utf8))
        }
        let status = await makeChecker().checkAgentSessionKit()
        XCTAssertEqual(status, .failed(reason: "no published release yet"))
    }

    func testAnErrorStatusIsReportedWithItsCode() async {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            (Self.status(503, request), Data())
        }
        let status = await makeChecker().checkAgentSessionKit()
        XCTAssertEqual(status, .failed(reason: "GitHub answered HTTP 503"))
    }

    func testGarbageAndMissingFieldsAreRefusedRatherThanGuessed() async {
        for body in ["not json", "{}", #"{"tag_name":"nightly"}"#, "[]"] {
            KitReleaseStubURLProtocol.reset()
            KitReleaseStubURLProtocol.handler = { request in
                (Self.ok(request), Data(body.utf8))
            }
            let status = await makeChecker().checkAgentSessionKit()
            XCTAssertTrue(status.isFailure, body)
        }
    }

    /// Six hours in memory, so pressing the button twice in a session costs
    /// one request — and `force` is what the button actually passes.
    func testTheAnswerIsCachedAndForceBypassesIt() async {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            (Self.ok(request), Data(#"{"tag_name":"0.4.0"}"#.utf8))
        }
        let checker = makeChecker()
        _ = await checker.checkAgentSessionKit(force: true)
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 1)
        _ = await checker.checkAgentSessionKit()
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 1, "a fresh answer should not refetch")
        _ = await checker.checkAgentSessionKit(force: true)
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 2)
    }

    func testTheCacheExpires() async {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            (Self.ok(request), Data(#"{"tag_name":"0.4.0"}"#.utf8))
        }
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let checker = makeChecker(cacheLifetime: 6 * 60 * 60, now: { clock.now })
        _ = await checker.checkAgentSessionKit()
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 1)
        clock.advance(by: 5 * 60 * 60)
        _ = await checker.checkAgentSessionKit()
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 1)
        let cachedWhileFresh = await checker.cachedAgentSessionKitStatus()
        XCTAssertNotNil(cachedWhileFresh)
        clock.advance(by: 2 * 60 * 60)
        let cachedWhenStale = await checker.cachedAgentSessionKitStatus()
        XCTAssertNil(cachedWhenStale, "a stale answer is not an answer")
        _ = await checker.checkAgentSessionKit()
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 2)
    }

    /// A flaky network must not lock the row for six hours.
    func testFailuresAreNotCached() async {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.handler = { request in
            (Self.status(500, request), Data())
        }
        let checker = makeChecker()
        let first = await checker.checkAgentSessionKit()
        XCTAssertTrue(first.isFailure)
        let cachedAfterFailure = await checker.cachedAgentSessionKitStatus()
        XCTAssertNil(cachedAfterFailure)
        _ = await checker.checkAgentSessionKit()
        XCTAssertEqual(KitReleaseStubURLProtocol.requestCount.value, 2)
    }

    /// Nothing on this path should ever be able to hand a caller a status
    /// that claims to be up to date when the request never landed.
    func testATransportFailureIsAFailureLine() async {
        KitReleaseStubURLProtocol.reset()
        KitReleaseStubURLProtocol.error = URLError(.notConnectedToInternet)
        let status = await makeChecker().checkAgentSessionKit()
        XCTAssertTrue(status.isFailure)
        XCTAssertTrue(status.message.hasPrefix("Could not check for kit updates:"), status.message)
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse { status(200, request) }

    private static func status(_ code: Int, _ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

/// A tiny settable clock, so the six-hour cache is tested by arithmetic
/// rather than by waiting.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

private final class KitReleaseStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var error: Error?
    static let requestCount = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            count = 0
        }
    }

    static func reset() {
        handler = nil
        error = nil
        requestCount.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.increment()
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
