import XCTest
@testable import VibeBarCore

/// Protocol-level behaviour: framing, dispatch, and the error codes a client
/// distinguishes on.
final class MCPJSONRPCTests: XCTestCase {
    private func makeServer() -> (MCPServer, FakeMCPDataSource) {
        let source = FakeMCPDataSource()
        let server = MCPServer(dataSource: source, now: { FakeMCPDataSource.epoch })
        return (server, source)
    }

    func testInitializeReportsProtocolVersionAndServerInfo() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.line(id: 1, method: "initialize"))
        )
        XCTAssertEqual(response["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(response["id"]?.intValue, 1)
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, "vibebar")
        XCTAssertEqual(result["serverInfo"]?["version"]?.stringValue, "9.9.9 (42)")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertNotNil(result["capabilities"]?["resources"])
    }

    func testInitializedNotificationProducesNoOutput() async {
        let (server, _) = makeServer()
        let reply = await server.handle(
            line: MCPTestSupport.line(id: nil, method: "notifications/initialized")
        )
        XCTAssertNil(reply, "A notification must never be answered.")
    }

    func testPingAnswersAnEmptyResult() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.line(id: 2, method: "ping"))
        )
        XCTAssertEqual(response["result"], .object([:]))
    }

    func testToolsListCarriesEveryToolWithASchema() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.line(id: 3, method: "tools/list"))
        )
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(
            names.sorted(),
            [
                "cost.history", "cost.snapshot", "pricing.effective", "quota.get", "quota.refresh",
                "sessions.list", "sessions.search", "skills.install", "status.get", "usage.requests",
                "usage.summary", "usage.trend"
            ]
        )
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object", "\(tool)")
            XCTAssertFalse(tool["description"]?.stringValue?.isEmpty ?? true, "\(tool)")
        }
    }

    func testResourcesListAndRead() async throws {
        let (server, _) = makeServer()
        let list = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.line(id: 4, method: "resources/list"))
        )
        let uris = try XCTUnwrap(list["result"]?["resources"]?.arrayValue)
            .compactMap { $0["uri"]?.stringValue }
        XCTAssertEqual(uris.sorted(), ["vibebar://naming-spec", "vibebar://tools"])

        let read = try MCPTestSupport.decode(
            await server.handle(
                line: MCPTestSupport.line(
                    id: 5,
                    method: "resources/read",
                    params: .object(["uri": .string("vibebar://naming-spec")])
                )
            )
        )
        let contents = try XCTUnwrap(read["result"]?["contents"]?.arrayValue?.first)
        XCTAssertEqual(contents["mimeType"]?.stringValue, "text/markdown")
        XCTAssertTrue(contents["text"]?.stringValue?.contains("two orthogonal axes") ?? false)
    }

    func testUnknownResourceIsInvalidParams() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(
                line: MCPTestSupport.line(
                    id: 6,
                    method: "resources/read",
                    params: .object(["uri": .string("vibebar://nope")])
                )
            )
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    func testUnknownMethodIsMethodNotFound() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.line(id: 7, method: "sampling/createMessage"))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_601)
        XCTAssertEqual(response["id"]?.intValue, 7)
    }

    func testMalformedJSONIsParseError() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: Data("{ this is not json".utf8))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_700)
        XCTAssertEqual(response["id"], .null)
    }

    func testJSONThatIsNotARequestIsInvalidRequest() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: Data(#"{"jsonrpc":"2.0","id":9}"#.utf8))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_600)
    }

    func testWrongJSONRPCVersionIsRejected() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: Data(#"{"jsonrpc":"1.0","id":9,"method":"ping"}"#.utf8))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_600)
    }

    func testUnknownToolIsInvalidParams() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(id: 10, tool: "quota.everything"))
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
    }

    func testUnknownArgumentIsRejectedRatherThanIgnored() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(
                line: MCPTestSupport.call(
                    id: 11,
                    tool: "quota.get",
                    arguments: .object(["provider": .string("claude")])
                )
            )
        )
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32_602)
        XCTAssertTrue(response["error"]?["message"]?.stringValue?.contains("'provider'") ?? false)
    }

    func testBadEnumValueNamesTheAcceptedOnes() async throws {
        let (server, _) = makeServer()
        let response = try MCPTestSupport.decode(
            await server.handle(
                line: MCPTestSupport.call(
                    id: 12,
                    tool: "quota.get",
                    arguments: .object(["tools": .array([.string("anthropic")])])
                )
            )
        )
        let message = try XCTUnwrap(response["error"]?["message"]?.stringValue)
        XCTAssertTrue(message.contains("'anthropic'"))
        XCTAssertTrue(message.contains("'claude'"))
    }

    /// A tool that ran and failed reports through `isError`, not through a
    /// JSON-RPC error — the model has to be able to read the reason.
    func testToolFailureIsAnIsErrorResultNotAnRPCError() async throws {
        let (server, source) = makeServer()
        source.ledgerAvailable = false
        let response = try MCPTestSupport.decode(
            await server.handle(line: MCPTestSupport.call(id: 13, tool: "usage.summary"))
        )
        XCTAssertNil(response["error"])
        XCTAssertTrue(MCPTestSupport.isError(response))
        XCTAssertTrue(MCPTestSupport.errorText(response)?.contains("usage ledger") ?? false)
    }

    func testResponseIDMirrorsAStringID() async throws {
        let (server, _) = makeServer()
        let line = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
        let response = try MCPTestSupport.decode(await server.handle(line: line))
        XCTAssertEqual(response["id"]?.stringValue, "abc")
    }
}
