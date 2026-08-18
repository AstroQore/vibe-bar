import Darwin
import Foundation

/// The `--mcp-stdio` mode: the same app binary, run as a plain stdio MCP
/// server that forwards to the running app's socket.
///
/// MCP clients spawn a command and speak newline-delimited JSON-RPC over its
/// stdin/stdout. Vibe Bar's own transport is the same framing over a Unix
/// socket, so this is a byte pump rather than a protocol bridge — no parsing,
/// no reframing, and therefore nothing that can corrupt a message it did not
/// understand.
///
/// One command configures every client:
///
/// ```
/// /Applications/Vibe Bar.app/Contents/MacOS/VibeBar --mcp-stdio
/// ```
///
/// The process installs no status item, opens no window, and touches nothing
/// under `~/.vibebar` except the socket it connects to.
public enum MCPStdioBridge {
    public static let commandLineFlag = "--mcp-stdio"

    /// Test and diagnostic override for the socket path. The smoke test in
    /// `Tests/` uses it to point a spawned bridge at a temporary socket
    /// instead of the real one; it is documented rather than hidden because a
    /// second Vibe Bar build is exactly the case that needs it.
    public static let socketPathEnvironmentKey = "VIBEBAR_MCP_SOCKET"

    public enum ExitCode {
        public static let ok: Int32 = 0
        /// Nothing was listening — almost always "the app is not running".
        public static let notRunning: Int32 = 1
    }

    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment[socketPathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return MCPSocketServer.defaultSocketPath
    }

    /// Connect, pump both directions, return an exit code.
    ///
    /// Returns when either side closes: stdin closing is the client shutting
    /// the server down, and the socket closing is Vibe Bar quitting. Both are
    /// ordinary ends of a session, so both exit zero — only a failure to
    /// connect at all is an error worth a non-zero code.
    public static func run(
        socketPath path: String,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        guard let socketFD = connect(to: path) else {
            standardError.write(Data((notRunningMessage(for: path) + "\n").utf8))
            return ExitCode.notRunning
        }

        // stdin runs on its own thread with blocking reads. A DispatchSource
        // would work too, but stdin here is a pipe owned by the MCP client and
        // a plain blocking read is both simpler and impossible to get subtly
        // wrong around partial reads.
        let upstreamFinished = DispatchSemaphore(value: 0)
        let thread = Thread {
            pump(from: input, to: socketFD)
            // Half-close so the app sees EOF and releases the connection while
            // still being able to flush whatever it was mid-reply on.
            shutdown(socketFD, SHUT_WR)
            upstreamFinished.signal()
        }
        thread.name = "com.astroqore.VibeBar.mcp.stdio"
        thread.start()

        pump(from: socketFD, to: output)
        // The socket closed. Do not wait on the stdin thread: it is parked in
        // a blocking read the client may never end, and the process exiting is
        // what the client is waiting for.
        close(socketFD)
        return ExitCode.ok
    }

    static func notRunningMessage(for path: String) -> String {
        let display = path == MCPSocketServer.defaultSocketPath ? "~/.vibebar/mcp.sock" : path
        return "Vibe Bar is not running (socket \(display) not found). Launch \"Vibe Bar.app\" first."
    }

    // MARK: - Plumbing

    private static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Copy bytes until the source ends. Byte-for-byte: the newline framing
    /// travels inside the stream, so nothing here needs to know where a
    /// message starts.
    private static func pump(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count > 0 {
                guard writeAll(chunk, count: count, to: destination) else { return }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            return
        }
    }

    private static func writeAll(_ bytes: [UInt8], count: Int, to destination: Int32) -> Bool {
        var offset = 0
        while offset < count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(destination, base + offset, count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EINTR { continue }
            return false
        }
        return true
    }
}
