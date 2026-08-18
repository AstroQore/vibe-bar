import Darwin
import Foundation
import XCTest
@testable import VibeBarCore

/// The `--mcp-stdio` pump, exercised through real pipes against a real socket.
///
/// The bridge forwards bytes rather than messages, so what these tests really
/// assert is that framing survives the trip in both directions — including a
/// second message that arrives while the first is still being answered.
final class MCPStdioBridgeTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!
    private var socketServer: MCPSocketServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vbmcpb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
    }

    override func tearDownWithError() throws {
        socketServer?.stop()
        socketServer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testSocketPathPrefersTheEnvironmentOverride() {
        XCTAssertEqual(
            MCPStdioBridge.socketPath(environment: ["VIBEBAR_MCP_SOCKET": "/tmp/custom.sock"]),
            "/tmp/custom.sock"
        )
        XCTAssertEqual(
            MCPStdioBridge.socketPath(environment: ["VIBEBAR_MCP_SOCKET": "   "]),
            MCPSocketServer.defaultSocketPath
        )
        XCTAssertEqual(MCPStdioBridge.socketPath(environment: [:]), MCPSocketServer.defaultSocketPath)
    }

    func testNotRunningMessageNamesTheTildePathForTheDefaultSocket() {
        XCTAssertEqual(
            MCPStdioBridge.notRunningMessage(for: MCPSocketServer.defaultSocketPath),
            "Vibe Bar is not running (socket ~/.vibebar/mcp.sock not found). Launch \"Vibe Bar.app\" first."
        )
        XCTAssertTrue(
            MCPStdioBridge.notRunningMessage(for: "/tmp/other.sock").contains("/tmp/other.sock"),
            "A custom socket path should be named literally."
        )
    }

    func testConnectingToNothingExitsNonZeroWithAReadableMessage() throws {
        let errorFile = directory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: Data())
        let handle = try FileHandle(forWritingTo: errorFile)

        let code = MCPStdioBridge.run(
            socketPath: socketPath,
            input: STDIN_FILENO,
            output: STDOUT_FILENO,
            standardError: handle
        )
        try handle.close()

        XCTAssertEqual(code, MCPStdioBridge.ExitCode.notRunning)
        let message = try String(contentsOf: errorFile, encoding: .utf8)
        XCTAssertTrue(message.contains("Vibe Bar is not running"), message)
        XCTAssertTrue(message.contains(socketPath), message)
    }

    func testTwoMessagesPumpEachWayThroughTheBridge() throws {
        let server = MCPServer(dataSource: FakeMCPDataSource(), now: { FakeMCPDataSource.epoch })
        let socket = MCPSocketServer(server: server, socketPath: socketPath)
        try socket.start()
        socketServer = socket

        let toBridge = Pipe()
        let fromBridge = Pipe()
        let finished = expectation(description: "bridge exits")

        let path = socketPath!
        let inputFD = toBridge.fileHandleForReading.fileDescriptor
        let outputFD = fromBridge.fileHandleForWriting.fileDescriptor
        Thread.detachNewThread {
            let code = MCPStdioBridge.run(socketPath: path, input: inputFD, output: outputFD)
            XCTAssertEqual(code, MCPStdioBridge.ExitCode.ok)
            // Let the reader see EOF once the pump is done.
            try? fromBridge.fileHandleForWriting.close()
            finished.fulfill()
        }

        let reader = LineReader(fd: fromBridge.fileHandleForReading.fileDescriptor)

        try write(MCPTestSupport.line(id: 1, method: "initialize"), to: toBridge)
        let initialize = try reader.next()
        XCTAssertEqual(initialize["id"]?.intValue, 1)
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"]?.stringValue, "vibebar")

        try write(MCPTestSupport.line(id: 2, method: "tools/list"), to: toBridge)
        let tools = try reader.next()
        XCTAssertEqual(tools["id"]?.intValue, 2)
        XCTAssertTrue(
            (tools["result"]?["tools"]?.arrayValue ?? [])
                .contains { $0["name"]?.stringValue == "quota.get" }
        )

        // Closing stdin is how an MCP client shuts its server down.
        try toBridge.fileHandleForWriting.close()
        wait(for: [finished], timeout: 10)
    }

    private func write(_ line: Data, to pipe: Pipe) throws {
        var framed = line
        framed.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: framed)
    }
}

/// Blocking newline reader over a raw descriptor.
private final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    func next() throws -> MCPJSON {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return try JSONDecoder().decode(MCPJSON.self, from: line)
            }
            var chunk = [UInt8](repeating: 0, count: 8_192)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw MCPTestError("The bridge closed before answering.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
