import Darwin
import Foundation
import XCTest
@testable import VibeBarCore

/// End-to-end over a real Unix domain socket on a temporary path.
///
/// Nothing here touches the real home directory: `MCPSocketServer` creates the
/// directory its socket lives in rather than `~/.vibebar` unconditionally,
/// which is exactly what makes this test possible.
final class MCPSocketServerTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!
    private var socketServer: MCPSocketServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vbmcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
        XCTAssertLessThan(socketPath.utf8.count, 104, "The temp socket path must fit in sockaddr_un.")
    }

    override func tearDownWithError() throws {
        socketServer?.stop()
        socketServer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func startServer() throws -> MCPSocketServer {
        let server = MCPServer(dataSource: FakeMCPDataSource(), now: { FakeMCPDataSource.epoch })
        let socket = MCPSocketServer(server: server, socketPath: socketPath)
        try socket.start()
        socketServer = socket
        return socket
    }

    func testTheSocketIsCreatedPrivateAndRemovedOnStop() throws {
        let socket = try startServer()
        XCTAssertTrue(socket.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value & 0o777, 0o600, "The socket must not be readable by anyone else.")

        socket.stop()
        XCTAssertFalse(socket.isRunning)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "Quitting has to take the socket file with it."
        )
    }

    func testAStaleSocketFileDoesNotBlockStartup() throws {
        // What a crash leaves behind: a socket inode with nothing behind it.
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        let socket = try startServer()
        XCTAssertTrue(socket.isRunning)
        XCTAssertEqual(socket.status, .listening)
    }

    /// A second Vibe Bar — the usual case is a source build launched next to
    /// the installed app — must not unlink a socket that is being served. The
    /// file looks identical either way, so the check is a probe connect.
    func testASecondServerReportsAConflictInsteadOfStealingTheSocket() throws {
        let first = try startServer()
        XCTAssertEqual(first.status, .listening)

        let second = MCPSocketServer(
            server: MCPServer(dataSource: FakeMCPDataSource()),
            socketPath: socketPath
        )
        defer { second.stop() }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? MCPSocketError, .socketOwnedByAnotherInstance(socketPath))
        }
        XCTAssertEqual(second.status, .conflict)
        XCTAssertFalse(second.isRunning)

        // The point of the whole exercise: the first server is still there.
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }
        let pong = try client.request(MCPTestSupport.line(id: 7, method: "ping"))
        XCTAssertEqual(pong["id"]?.intValue, 7)
    }

    /// The conflicting server never bound, so stopping it must leave the live
    /// server's socket file alone.
    func testStoppingAConflictedServerDoesNotRemoveTheLiveSocket() throws {
        let first = try startServer()
        let second = MCPSocketServer(
            server: MCPServer(dataSource: FakeMCPDataSource()),
            socketPath: socketPath
        )
        XCTAssertThrowsError(try second.start())
        second.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(first.isRunning)
    }

    func testTheLivenessProbeReadsAStaleInodeAsFree() throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        XCTAssertFalse(MCPSocketServer.isAnyoneListening(atPath: socketPath))
        _ = try startServer()
        XCTAssertTrue(MCPSocketServer.isAnyoneListening(atPath: socketPath))
    }

    func testInitializeAndToolsListOverTheSocket() throws {
        _ = try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        let initialize = try client.request(MCPTestSupport.line(id: 1, method: "initialize"))
        XCTAssertEqual(initialize["id"]?.intValue, 1)
        XCTAssertEqual(initialize["result"]?["protocolVersion"]?.stringValue, "2025-06-18")

        // A notification in the middle of the stream must not consume a reply
        // slot; the next response has to be the tools/list one.
        try client.send(MCPTestSupport.line(id: nil, method: "notifications/initialized"))

        let tools = try client.request(MCPTestSupport.line(id: 2, method: "tools/list"))
        XCTAssertEqual(tools["id"]?.intValue, 2)
        let names = try XCTUnwrap(tools["result"]?["tools"]?.arrayValue)
            .compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("quota.get"), "\(names)")
    }

    /// A scripted client (`printf ... | VibeBar --mcp-stdio`) writes its
    /// requests, half-closes, and expects every answer before the server
    /// hangs up. Regression for the Dev.33 report where the replies were
    /// dropped because EOF closed the connection while they were in flight.
    func testRepliesInFlightAreDeliveredAfterThePeerHalfCloses() throws {
        _ = try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        try client.send(MCPTestSupport.line(id: 1, method: "initialize"))
        try client.send(MCPTestSupport.line(id: nil, method: "notifications/initialized"))
        try client.send(MCPTestSupport.line(id: 2, method: "tools/list"))
        client.halfClose()

        let first = try client.readLine()
        let second = try client.readLine()
        XCTAssertEqual(Set([first["id"]?.intValue, second["id"]?.intValue]), [1, 2])
        // …and then the server closes on its own.
        XCTAssertTrue(client.readUntilEOF(timeoutSeconds: 5))
    }

    func testAToolCallRoundTripsOverTheSocket() throws {
        _ = try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        let response = try client.request(MCPTestSupport.call(id: 3, tool: "quota.get"))
        let accounts = try XCTUnwrap(
            response["result"]?["structuredContent"]?["accounts"]?.arrayValue
        )
        XCTAssertEqual(accounts.count, 2)
    }

    func testTwoClientsAreServedIndependently() throws {
        _ = try startServer()
        let first = try MCPSocketTestClient(path: socketPath)
        let second = try MCPSocketTestClient(path: socketPath)
        defer {
            first.close()
            second.close()
        }
        let a = try first.request(MCPTestSupport.line(id: 10, method: "ping"))
        let b = try second.request(MCPTestSupport.line(id: 11, method: "ping"))
        XCTAssertEqual(a["id"]?.intValue, 10)
        XCTAssertEqual(b["id"]?.intValue, 11)
    }

    func testMalformedInputIsAnsweredRatherThanDroppingTheConnection() throws {
        _ = try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        let bad = try client.request(Data("{oops".utf8))
        XCTAssertEqual(bad["error"]?["code"]?.intValue, -32_700)

        let good = try client.request(MCPTestSupport.line(id: 4, method: "ping"))
        XCTAssertEqual(good["id"]?.intValue, 4, "The connection must survive a bad line.")
    }

    func testConnectionCountIsReported() throws {
        let socket = try startServer()
        XCTAssertEqual(socket.connectionCount, 0)
        let client = try MCPSocketTestClient(path: socketPath)
        _ = try client.request(MCPTestSupport.line(id: 1, method: "ping"))
        XCTAssertEqual(socket.connectionCount, 1)
        client.close()
    }

    func testAPathTooLongForSockaddrUnFailsClearly() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let socket = MCPSocketServer(
            server: MCPServer(dataSource: FakeMCPDataSource()),
            socketPath: long
        )
        XCTAssertThrowsError(try socket.start()) { error in
            XCTAssertEqual(error as? MCPSocketError, .pathTooLong(long))
        }
    }
}

// MARK: - A blocking client, just for tests

/// The smallest possible newline-delimited JSON-RPC client. Blocking on
/// purpose: a test that has to poll is a test that flakes.
final class MCPSocketTestClient {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else {
            throw MCPTestError("Socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: bytes, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { throw MCPTestError("socket() failed: \(errno)") }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(handle)
            throw MCPTestError("connect() failed: \(errno)")
        }
        // A wedged server must fail the test rather than hang the suite.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        self.fd = handle
    }

    func close() {
        Darwin.close(fd)
    }

    /// Signal EOF to the server while keeping our read side open.
    func halfClose() {
        Darwin.shutdown(fd, SHUT_WR)
    }

    /// True when the server closes the connection within the timeout.
    func readUntilEOF(timeoutSeconds: Int) -> Bool {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return true }
            if count < 0 { return false }
        }
    }

    func send(_ line: Data) throws {
        var framed = line
        framed.append(0x0A)
        var offset = 0
        while offset < framed.count {
            let written = framed.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base + offset, raw.count - offset)
            }
            guard written > 0 else { throw MCPTestError("write() failed: \(errno)") }
            offset += written
        }
    }

    func request(_ line: Data) throws -> MCPJSON {
        try send(line)
        return try readLine()
    }

    func readLine() throws -> MCPJSON {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return try JSONDecoder().decode(MCPJSON.self, from: line)
            }
            var chunk = [UInt8](repeating: 0, count: 8_192)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw MCPTestError("The server closed before answering.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
