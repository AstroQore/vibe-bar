import XCTest
@testable import VibeBarCore

/// skills.sh is a third-party index whose schema is not ours, so the tests are
/// mostly about tolerance: unknown keys, a missing `name`, an install count
/// that arrives as a string. The one strict rule is `source` — it becomes a
/// download URL, so a row that cannot produce a valid `owner/repo` is dropped.
final class SkillsSearchClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> SkillsSearchClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return SkillsSearchClient(session: URLSession(configuration: configuration))
    }

    private func stub(query: String, limit: Int = SkillsSearchClient.defaultLimit, body: Data, status: Int = 200) {
        let url = SkillsSearchClient.searchURL(query: query, limit: limit)!
        StubURLProtocol.replies[url.absoluteString] = .init(statusCode: status, body: body)
    }

    func testBuildsAnEncodedSearchURL() throws {
        let url = try XCTUnwrap(SkillsSearchClient.searchURL(query: "pdf tools & more", limit: 5))
        XCTAssertEqual(url.host, "skills.sh")
        XCTAssertEqual(url.path, "/api/search")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("q=pdf%20tools%20%26%20more") || query.contains("q=pdf+tools+%26+more"), query)
        XCTAssertTrue(query.contains("limit=5"))

        // Out-of-range limits are clamped rather than sent through.
        XCTAssertTrue(SkillsSearchClient.searchURL(query: "x", limit: 0)!.query!.contains("limit=1"))
        XCTAssertTrue(SkillsSearchClient.searchURL(query: "x", limit: 5_000)!.query!.contains("limit=100"))
    }

    func testParsesACannedResponse() async throws {
        let body = Data("""
        {
          "query": "pdf",
          "count": 3,
          "skills": [
            {"id": "pdf", "name": "PDF Tools", "installs": 4210, "source": "anthropics/skills"},
            {"skillId": "docx", "installs": "77", "source": "ComposioHQ/awesome-claude-skills@master"},
            {"id": "brand-new", "name": "Brand New", "source": "JimLiu/baoyu-skills", "unknownKey": {"a": 1}}
          ]
        }
        """.utf8)
        stub(query: "pdf", body: body)

        let results = try await makeClient().search("pdf")

        XCTAssertEqual(results.map(\.name), ["PDF Tools", "docx", "Brand New"])
        XCTAssertEqual(results[0].installs, 4_210)
        XCTAssertEqual(results[0].repo, SkillRepoRef("anthropics/skills"))
        XCTAssertEqual(results[1].installs, 77, "An install count sent as a string is still a number")
        XCTAssertEqual(results[1].repo.branch, "master")
        XCTAssertNil(results[2].installs)
    }

    func testDropsRowsWhoseSourceIsUnusable() async throws {
        let body = Data("""
        {
          "skills": [
            {"name": "good", "source": "acme/skills"},
            {"name": "no source"},
            {"name": "bad slug", "source": "not-a-repo"},
            {"name": "too deep", "source": "a/b/c"},
            {"name": "traversal", "source": "a/../b"},
            {"name": "url", "source": "https://github.com/acme/skills"},
            {"name": "", "source": "acme/other"},
            "not even an object",
            {"source": "acme/nameless"}
          ]
        }
        """.utf8)
        stub(query: "junk", body: body)

        let results = try await makeClient().search("junk")

        XCTAssertEqual(results.map(\.name), ["good"])
    }

    func testTreatsAResponseWithoutSkillsAsEmpty() async throws {
        stub(query: "none", body: Data(#"{"query":"none","count":0}"#.utf8))
        let results = try await makeClient().search("none")
        XCTAssertTrue(results.isEmpty)
    }

    func testRejectsAnOversizedResponse() async {
        var body = Data(#"{"skills":[{"name":"x","source":"a/b"}],"padding":""#.utf8)
        body.append(Data(repeating: 0x20, count: SkillsSearchClient.maxResponseBytes + 1))
        body.append(Data(#""}"#.utf8))
        stub(query: "big", body: body)

        do {
            _ = try await makeClient().search("big")
            XCTFail("Expected the response cap to reject this")
        } catch {
            XCTAssertEqual(
                error as? HTTPResponseLimit.BoundedError,
                .responseTooLarge(limit: SkillsSearchClient.maxResponseBytes)
            )
        }
    }

    func testReportsAnHTTPFailure() async {
        stub(query: "boom", body: Data(), status: 503)
        do {
            _ = try await makeClient().search("boom")
            XCTFail("Expected httpStatus")
        } catch {
            XCTAssertEqual(error as? SkillsSearchError, .httpStatus(503))
        }
    }

    func testRejectsAnEmptyQueryWithoutHittingTheNetwork() async {
        do {
            _ = try await makeClient().search("   \n ")
            XCTFail("Expected emptyQuery")
        } catch {
            XCTAssertEqual(error as? SkillsSearchError, .emptyQuery)
        }
        XCTAssertTrue(StubURLProtocol.requested.isEmpty)
    }

    func testReportsAMalformedBody() async {
        stub(query: "garbage", body: Data("<html>not json</html>".utf8))
        do {
            _ = try await makeClient().search("garbage")
            XCTFail("Expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? SkillsSearchError, .malformedResponse)
        }
    }
}
