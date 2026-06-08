import XCTest
@testable import VibeBarCore

/// Exercises `PricingRefresher` against a stubbed URLProtocol so we
/// can assert behavior on the happy path (200 → LiteLLM transformed →
/// cache written), freshness short-circuit (cache present + within
/// window → skipped), unusable payload (not LiteLLM → rejected),
/// oversized download, and network failure (left cache untouched).
final class PricingRefresherTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data?))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let responder = StubURLProtocol.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let (response, data) = responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarPricingRefresherTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testFreshCacheSkipsNetwork() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        // Write a fresh cache.
        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dataSet = PricingHardcoded.fallback
        try JSONEncoder().encode(dataSet).write(to: cacheURL)

        StubURLProtocol.responder = { _ in
            XCTFail("Network should not be hit when cache is fresh")
            return (HTTPURLResponse(), nil)
        }

        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            interval: 86_400
        )
        XCTAssertEqual(outcome, .skippedFresh)
    }

    func testSuccessfulFetchTransformsLiteLLMAndWritesCache() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        // A trimmed LiteLLM-shaped payload: a frontier Claude model with
        // an explicit fast multiplier, a Codex model whose fast tier comes
        // from our override table, and a spec stub with no cost fields.
        let body = Data("""
        {
          "claude-opus-4-8": {
            "input_cost_per_token": 5e-6, "output_cost_per_token": 2.5e-5,
            "cache_creation_input_token_cost": 6.25e-6,
            "cache_read_input_token_cost": 5e-7,
            "max_input_tokens": 1000000,
            "provider_specific_entry": {"fast": 2.0}
          },
          "gpt-5.5": {
            "input_cost_per_token": 5e-6, "output_cost_per_token": 3e-5,
            "cache_read_input_token_cost": 5e-7
          },
          "sample_spec": {"max_input_tokens": "max input tokens, if the provider specifies it"}
        }
        """.utf8)

        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, body)
        }

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let expectedDate: String = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: now)
        }()

        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            force: true,
            now: now
        )
        XCTAssertEqual(outcome, .fetched)

        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: home.path)
        let decoded = try JSONDecoder().decode(PricingDataSet.self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(decoded.schemaVersion, PricingDataSet.currentSchemaVersion)
        XCTAssertEqual(decoded.updatedAt, expectedDate)
        XCTAssertEqual(decoded.calculationVersion, PricingHardcoded.fallback.calculationVersion)
        // LiteLLM's fast multiplier survives the round-trip…
        XCTAssertEqual(decoded.providers.claude.models["claude-opus-4-8"]?.fastMultiplier, 2.0)
        XCTAssertEqual(decoded.providers.claude.models["claude-opus-4-8"]?.input ?? 0, 5e-6, accuracy: 1e-12)
        // …and the Codex fast multiplier is filled from the override table.
        XCTAssertEqual(decoded.providers.codex.models["gpt-5.5"]?.fastMultiplier, 2.5)
        // Overlay preserves base-only providers LiteLLM never ships.
        XCTAssertNotNil(decoded.providers.antigravity.models["antigravity-default"])
    }

    func testUnusablePayloadIsRejected() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        // Valid JSON, but not a LiteLLM price map (no priceable models).
        let body = Data(#"{"note":"this is not litellm","models":[]}"#.utf8)
        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, body)
        }

        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            force: true
        )
        XCTAssertEqual(outcome, .parseFailure)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: PricingResolver.cacheFileURL(homeDirectory: home.path).path),
            "Cache should not be written when the payload isn't usable LiteLLM data"
        )
    }

    func testOversizedDownloadIsRejected() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let oversize = Data(repeating: 0x20, count: PricingRefresher.maxFetchBytes + 1)
        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, oversize)
        }

        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            force: true
        )
        XCTAssertEqual(outcome, .oversized)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: PricingResolver.cacheFileURL(homeDirectory: home.path).path)
        )
    }

    func testNetworkFailureLeavesCacheIntact() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        // Seed existing cache.
        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed = try JSONEncoder().encode(PricingHardcoded.fallback)
        try seed.write(to: cacheURL)

        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 500,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, nil)
        }

        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            force: true
        )
        XCTAssertEqual(outcome, .networkFailure)

        // Cache file is untouched.
        let read = try Data(contentsOf: cacheURL)
        XCTAssertEqual(read, seed)
    }

    func testNotModifiedTouchesCacheMtime() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed = try JSONEncoder().encode(PricingHardcoded.fallback)
        try seed.write(to: cacheURL)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: cacheURL.path
        )

        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 304,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (response, nil)
        }

        let now = Date()
        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            force: true,
            now: now
        )
        XCTAssertEqual(outcome, .unchanged)

        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let newModDate = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertGreaterThan(newModDate, oldDate)
    }
}
