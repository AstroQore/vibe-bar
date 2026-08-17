import Foundation
import XCTest
@testable import VibeBarCore

/// The fetcher retries `.fallback` once when a learned recipe stops working.
/// That retry is only worth a round trip when the learned recipe describes a
/// *different* request.
final class GeminiWebRecipeRetryTests: XCTestCase {
    override func tearDown() {
        GeminiRecipeStubURLProtocol.handler = nil
        GeminiRecipeStubURLProtocol.postedRPCIDs.reset()
        super.tearDown()
    }

    func testLearnedFallbackContractIsNotReplayedAsItsOwnFallback() async {
        let session = makeStubbedSession()
        let learned = GeminiWebUsageRecipe(
            rpcID: GeminiWebUsageRecipe.fallback.rpcID,
            argument: GeminiWebUsageRecipe.fallback.argument,
            learnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fetcher = GeminiWebQuotaFetcher(
            session: session,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            recipeProvider: { learned }
        )

        await XCTAssertThrowsErrorAsync(
            try await fetcher.fetch(cookieHeader: "__Secure-1PSID=synthetic")
        )

        XCTAssertEqual(
            GeminiRecipeStubURLProtocol.postedRPCIDs.values,
            [GeminiWebUsageRecipe.fallback.rpcID]
        )
    }

    func testGenuinelyRotatedRecipeStillRetriesTheKnownContract() async {
        let session = makeStubbedSession()
        let learned = GeminiWebUsageRecipe(
            rpcID: "rotatedQuotaRPC",
            argument: "[]",
            learnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fetcher = GeminiWebQuotaFetcher(
            session: session,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            recipeProvider: { learned }
        )

        await XCTAssertThrowsErrorAsync(
            try await fetcher.fetch(cookieHeader: "__Secure-1PSID=synthetic")
        )

        XCTAssertEqual(
            GeminiRecipeStubURLProtocol.postedRPCIDs.values,
            ["rotatedQuotaRPC", GeminiWebUsageRecipe.fallback.rpcID]
        )
    }

    /// The `.needsLogin` self-heal spends at most one extra attempt per hour
    /// per account, so a genuinely dead cookie cannot turn every refresh into
    /// two round trips.
    func testForcedReimportGateAllowsOneRetryPerIntervalPerAccount() {
        let gate = GeminiForcedReimportGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(gate.consume(accountId: "a", now: start, interval: 3_600))
        XCTAssertFalse(gate.consume(accountId: "a", now: start.addingTimeInterval(60), interval: 3_600))
        XCTAssertFalse(gate.consume(accountId: "a", now: start.addingTimeInterval(3_599), interval: 3_600))
        XCTAssertTrue(gate.consume(accountId: "a", now: start.addingTimeInterval(3_600), interval: 3_600))
        // Independent budgets: one dead account must not block another.
        XCTAssertTrue(gate.consume(accountId: "b", now: start.addingTimeInterval(60), interval: 3_600))
    }

    // MARK: - Helpers

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiRecipeStubURLProtocol.self]
        GeminiRecipeStubURLProtocol.postedRPCIDs.reset()
        GeminiRecipeStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "GET" {
                return (
                    response,
                    Data(#"<script>window.WIZ_global_data={"SNlM0e":"synthetic-xsrf"};</script>"#.utf8)
                )
            }
            let rpcID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "rpcids" }?
                .value ?? ""
            GeminiRecipeStubURLProtocol.postedRPCIDs.append(rpcID)
            // A 200 that carries no usable payload — the shape that sends the
            // fetcher into its stale-recipe retry.
            return (response, Data(#")]}'\n[["wrb.fr","unrelated","[]",null]]"#.utf8))
        }
        return URLSession(configuration: config)
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected the stubbed payload to fail parsing", file: file, line: line)
        } catch {
            // Expected — both recipes fail against this stub.
        }
    }
}

private final class RPCIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.withLock { recorded }
    }

    func append(_ rpcID: String) {
        lock.withLock { recorded.append(rpcID) }
    }

    func reset() {
        lock.withLock { recorded.removeAll() }
    }
}

private final class GeminiRecipeStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    static let postedRPCIDs = RPCIDRecorder()

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
