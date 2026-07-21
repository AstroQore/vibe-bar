import XCTest
@testable import VibeBarCore

/// Tests the `WIZ_global_data.SNlM0e` XSRF token extractor used by
/// `GeminiWebQuotaFetcher` to authenticate against the live quota
/// endpoint. The 2026-05-23 spike confirmed Google ships the token
/// inline in the SSR HTML of `https://gemini.google.com/usage?pli=1`
/// under that exact key name.
final class GeminiWebXsrfExtractionTests: XCTestCase {
    override func tearDown() {
        GeminiWebStubURLProtocol.reset()
        super.tearDown()
    }

    func testExtractTokenFromCanonicalWizGlobalData() throws {
        let html = """
        <html><head><script>
        window.WIZ_global_data = {"SNlM0e":"AOOh0PsyntheticTokenValueXYZ","FdrFJe":"12345"};
        </script></head><body></body></html>
        """
        let token = try GeminiWebQuotaFetcher.extractXsrfToken(from: html)
        XCTAssertEqual(token, "AOOh0PsyntheticTokenValueXYZ")
    }

    func testExtractTokenWithExtraWhitespaceAroundColon() throws {
        // Some Google internal builders pretty-print the inline blob —
        // the regex must tolerate whitespace around the `:`.
        let html = "<script>WIZ_global_data = {\"SNlM0e\"  :   \"tok-1\"}</script>"
        let token = try GeminiWebQuotaFetcher.extractXsrfToken(from: html)
        XCTAssertEqual(token, "tok-1")
    }

    func testExtractTokenPicksFirstSNlM0eIfMultiplePresent() throws {
        // If, for any reason, the page ships two SNlM0e literals, the
        // first one wins — that's the one the upstream Angular code
        // also reads at boot time.
        let html = "<script>{\"SNlM0e\":\"first-token\"} ... {\"SNlM0e\":\"second-token\"}</script>"
        let token = try GeminiWebQuotaFetcher.extractXsrfToken(from: html)
        XCTAssertEqual(token, "first-token")
    }

    func testMissingTokenSurfaceAsNeedsLogin() {
        // A logged-out shell strips WIZ_global_data entirely. The
        // extractor must distinguish that case as `.needsLogin`
        // rather than `.parseFailure` so the UI can prompt the
        // user to re-import cookies instead of pretending the
        // wire shape changed.
        let html = "<html><body>Sign in to Gemini</body></html>"
        XCTAssertThrowsError(try GeminiWebQuotaFetcher.extractXsrfToken(from: html)) { error in
            guard case QuotaError.needsLogin = error else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }

    func testFetchUsesCurrentQuotaRPCContract() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiWebStubURLProtocol.self]
        let session = URLSession(configuration: config)

        GeminiWebStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": request.httpMethod == "POST" ? "application/json" : "text/html"]
            )!

            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/usage")
                return (
                    response,
                    Data(#"<script>window.WIZ_global_data={"SNlM0e":"synthetic-xsrf"};</script>"#.utf8)
                )
            }

            XCTAssertEqual(request.httpMethod, "POST")
            let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queryItems?.first(where: { $0.name == "rpcids" })?.value, GeminiWebQuotaFetcher.quotaRPCId)
            XCTAssertEqual(queryItems?.first(where: { $0.name == "source-path" })?.value, "/usage")

            let body = String(data: try Self.requestBody(request), encoding: .utf8) ?? ""
            var form = URLComponents()
            form.percentEncodedQuery = body
            let formItems = form.queryItems ?? []
            XCTAssertEqual(
                formItems.first(where: { $0.name == "f.req" })?.value,
                #"[[["ESY5D","[[[\"bard_activity_enabled\"]]]",null,"generic"]]]"#
            )
            XCTAssertEqual(formItems.first(where: { $0.name == "at" })?.value, "synthetic-xsrf")

            return (response, Self.wireFormat(inner: "[6,[[1,0,1,[[1779469511,0]]],[1,0,2,[[1780074311,0]]]],false]"))
        }

        let snapshot = try await GeminiWebQuotaFetcher(session: session).fetch(
            cookieHeader: "__Secure-1PSID=synthetic"
        )

        XCTAssertEqual(snapshot.planName, "Ultra")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(snapshot.buckets.map(\.usedPercent), [0, 0])
    }

    private static func wireFormat(inner: String) -> Data {
        let escapedInner = inner
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let entry = #"[["wrb.fr","\#(GeminiWebQuotaFetcher.quotaRPCId)","\#(escapedInner)",null,null,null,"generic"]]"#
        return Data(")]}'\\n\(entry.utf8.count)\\n\(entry)\\n".utf8)
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class GeminiWebStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

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
