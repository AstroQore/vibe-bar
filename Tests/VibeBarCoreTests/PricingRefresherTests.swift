import XCTest
@testable import VibeBarCore

/// Exercises `PricingRefresher` against a stubbed URLProtocol so we
/// can assert behavior on the happy path (200 → cache written),
/// freshness short-circuit (cache present + within window → skipped),
/// schema mismatch (unknown version → rejected), and network failure
/// (left cache untouched).
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

    func testSuccessfulFetchWritesCache() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let dataSet = PricingDataSet(
            schemaVersion: 1,
            updatedAt: "2026-06-01",
            calculationVersion: 5,
            providers: PricingHardcoded.fallback.providers
        )
        let body = try JSONEncoder().encode(dataSet)

        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, body)
        }

        let outcome = await PricingRefresher.refresh(
            homeDirectory: home.path,
            session: makeStubbedSession(),
            force: true
        )
        XCTAssertEqual(outcome, .fetched)

        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: home.path)
        let read = try Data(contentsOf: cacheURL)
        let decoded = try JSONDecoder().decode(PricingDataSet.self, from: read)
        XCTAssertEqual(decoded.updatedAt, "2026-06-01")
    }

    func testSchemaMismatchRejectsBadPayload() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let bad = PricingDataSet(
            schemaVersion: 999,
            updatedAt: "future",
            calculationVersion: 5,
            providers: PricingHardcoded.fallback.providers
        )
        let body = try JSONEncoder().encode(bad)
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
        XCTAssertEqual(outcome, .schemaMismatch)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: PricingResolver.cacheFileURL(homeDirectory: home.path).path),
            "Cache should not be written when schemaVersion mismatches"
        )
    }

    func testOversizedPayloadIsRejected() async throws {
        let home = try makeTempHome()
        defer { cleanup(home) }

        let oversize = Data(repeating: 0x20, count: PricingDataSet.maxBytes + 1)
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
