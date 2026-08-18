import Darwin
import Dispatch
import Foundation

public enum MCPSocketError: Error, Sendable, Equatable {
    /// `sockaddr_un.sun_path` is 104 bytes on macOS. A home directory deep
    /// enough to overflow it is rare but not impossible, and the failure mode
    /// without this check is a silently truncated path.
    case pathTooLong(String)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case staleSocketNotRemovable(String)
    /// Something is already answering on this path — almost always a second
    /// copy of Vibe Bar (a source build alongside the installed one).
    case socketOwnedByAnotherInstance(String)

    public var message: String {
        switch self {
        case let .pathTooLong(path):
            return "The socket path is too long for a Unix domain socket: \(path)"
        case let .socketCreationFailed(code):
            return "Creating the MCP socket failed (errno \(code))."
        case let .bindFailed(code):
            return "Binding the MCP socket failed (errno \(code))."
        case let .listenFailed(code):
            return "Listening on the MCP socket failed (errno \(code))."
        case let .staleSocketNotRemovable(path):
            return "A stale MCP socket at \(path) could not be removed."
        case let .socketOwnedByAnotherInstance(path):
            return "Another instance of Vibe Bar already owns the MCP socket at \(path). "
                + "Quit the other copy — agents are still being served by it."
        }
    }
}

/// What the listener is doing, for the Settings pane.
public enum MCPSocketServerStatus: String, Sendable, Equatable {
    case stopped
    case listening
    /// Another live server holds the path, so this one deliberately did not
    /// bind: unlinking a socket someone is answering on would silently cut
    /// every agent attached to the other instance.
    case conflict
}

/// A newline-delimited JSON-RPC listener on a Unix domain socket.
///
/// **No TCP, no port, no token.** The socket lives at `~/.vibebar/mcp.sock`
/// with mode 0600 inside a 0700 directory, so the filesystem is the whole
/// authentication story: a process that can open it is already running as the
/// user, and a token file would only add a secret to leak. Nothing is ever
/// bound to a network interface.
///
/// This is POSIX rather than `Network.framework` on purpose. `NWListener`
/// can carry `NWEndpoint.unix`, but it owns the socket file's creation, which
/// makes the "unlink the stale one, bind under a tight umask, chmod" sequence
/// that guarantees 0600 impossible to state directly.
public final class MCPSocketServer: @unchecked Sendable {
    /// Framing cap. A single JSON-RPC line larger than this is a client bug,
    /// and buffering it would let one connection grow without bound.
    public static let maximumLineBytes = 4 * 1024 * 1024
    /// Concurrent clients. Two agents plus a stray bridge is the realistic
    /// peak; the cap exists so a runaway client cannot exhaust descriptors.
    public static let maximumConnections = 16

    public let socketPath: String

    private let server: MCPServer
    private let acceptQueue = DispatchQueue(label: "com.astroqore.VibeBar.mcp.accept")
    private let stateLock = NSLock()

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var didBindSocketFile = false
    private var statusValue: MCPSocketServerStatus = .stopped

    /// Called on the accept queue whenever a client connects or disconnects,
    /// with the live connection count. The Settings pane uses it to show
    /// whether anything is attached without polling.
    public var onConnectionChange: (@Sendable (Int, Date) -> Void)?

    public init(server: MCPServer, socketPath: String = MCPSocketServer.defaultSocketPath) {
        self.server = server
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public static var defaultSocketPath: String {
        VibeBarLocalStore.baseDirectory.appendingPathComponent("mcp.sock").path
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenFD >= 0
    }

    /// `.conflict` outlives the failed `start()` on purpose: it is the one
    /// failure the user can act on, and the Settings pane reads it to say who
    /// actually owns the socket.
    public var status: MCPSocketServerStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statusValue
    }

    public var connectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connections.count
    }

    // MARK: - Lifecycle

    public func start() throws {
        stateLock.lock()
        let alreadyRunning = listenFD >= 0
        stateLock.unlock()
        guard !alreadyRunning else { return }

        // One byte is reserved for the terminating NUL. Checked before
        // anything touches the filesystem, so an unusable path fails as
        // itself rather than as whatever the first syscall happened to hit.
        guard var address = Self.unixAddress(for: socketPath) else {
            throw MCPSocketError.pathTooLong(socketPath)
        }

        // Only the app's own directory is created (and forced to 0700). A
        // custom path — tests, the documented `VIBEBAR_MCP_SOCKET` override —
        // must already have its directory, because chmod-ing someone else's
        // is not this server's business.
        if socketPath == Self.defaultSocketPath {
            try VibeBarLocalStore.ensureBaseDirectory()
        }

        // A socket file left behind by a crash refuses `bind` with EADDRINUSE
        // forever, so it has to go — but a *live* server's socket looks
        // identical on disk, and unlinking that one would leave the other
        // instance accepting on an inode no client can reach any more. Ask
        // first: a connect that succeeds means someone is answering.
        if FileManager.default.fileExists(atPath: socketPath) {
            guard !Self.isAnyoneListening(atPath: socketPath) else {
                stateLock.lock()
                statusValue = .conflict
                stateLock.unlock()
                SafeLog.warn(
                    "MCP server did not start: \(SafeLog.sanitize(socketPath)) is served by another instance."
                )
                throw MCPSocketError.socketOwnedByAnotherInstance(socketPath)
            }
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                throw MCPSocketError.staleSocketNotRemovable(socketPath)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.socketCreationFailed(errno) }

        // The window between `bind` (which creates the file) and `chmod` is
        // the only moment the socket could be group/other-accessible, so the
        // umask closes it and the chmod makes the final mode explicit rather
        // than umask-dependent.
        let previousMask = umask(0o177)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw MCPSocketError.bindFailed(code)
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
            throw MCPSocketError.listenFailed(code)
        }

        Self.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }

        stateLock.lock()
        listenFD = fd
        acceptSource = source
        didBindSocketFile = true
        statusValue = .listening
        stateLock.unlock()

        source.resume()
        SafeLog.info("MCP server listening on \(SafeLog.sanitize(socketPath))")
    }

    public func stop() {
        stateLock.lock()
        let source = acceptSource
        let openConnections = Array(connections.values)
        let shouldUnlink = didBindSocketFile
        acceptSource = nil
        connections = [:]
        listenFD = -1
        didBindSocketFile = false
        statusValue = .stopped
        stateLock.unlock()

        source?.cancel()
        for connection in openConnections { connection.close() }
        // Only remove a socket file this instance actually created: a `stop`
        // during a failed start must not delete a healthy server's socket.
        if shouldUnlink {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    // MARK: - Accept

    private func acceptPending() {
        while true {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(currentListenFD(), &address, &length)
            guard clientFD >= 0 else {
                // EAGAIN/EWOULDBLOCK simply means the backlog drained.
                return
            }
            guard connectionCount < Self.maximumConnections else {
                close(clientFD)
                SafeLog.warn("MCP server refused a connection: too many clients.")
                continue
            }
            Self.setNonBlocking(clientFD)
            open(clientFD: clientFD)
        }
    }

    private func currentListenFD() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenFD
    }

    private func open(clientFD: Int32) {
        let connection = Connection(fd: clientFD, server: server)
        connection.onClose = { [weak self] closed in
            guard let self else { return }
            self.stateLock.lock()
            self.connections.removeValue(forKey: ObjectIdentifier(closed))
            let remaining = self.connections.count
            self.stateLock.unlock()
            self.onConnectionChange?(remaining, Date())
        }

        stateLock.lock()
        connections[ObjectIdentifier(connection)] = connection
        let count = connections.count
        stateLock.unlock()

        connection.resume()
        onConnectionChange?(count, Date())
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    // MARK: - Address + liveness

    /// `nil` when the path cannot fit in `sun_path`.
    private static func unixAddress(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: bytes, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Is a server actually accepting on this path?
    ///
    /// The filesystem cannot answer this — a socket inode looks the same
    /// whether its server is alive or was killed — so ask the kernel with a
    /// throwaway connect. `ECONNREFUSED` (nobody is listening) and `ENOENT`
    /// (the file went away underneath us) both mean the inode is stale and
    /// safe to unlink; a completed handshake means it is not.
    ///
    /// Non-blocking, because an `AF_UNIX` connect against a server whose
    /// backlog is full parks until a slot opens, and a busy peer is still a
    /// live peer — `poll` bounds that wait.
    static func isAnyoneListening(atPath path: String, timeoutMilliseconds: Int32 = 250) -> Bool {
        guard var address = unixAddress(for: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return false }
        var pending: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 else { return false }
        return pending == 0
    }
}

// MARK: - One client

/// One accepted client: a read source that reframes bytes into lines, and a
/// serial queue that both parses and writes, so replies from concurrent
/// handler tasks can never interleave mid-line.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let server: MCPServer
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var isClosed = false

    var onClose: (@Sendable (Connection) -> Void)?

    init(fd: Int32, server: MCPServer) {
        self.fd = fd
        self.server = server
        self.queue = DispatchQueue(label: "com.astroqore.VibeBar.mcp.connection.\(fd)")
    }

    func resume() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    func close() {
        queue.async { [weak self] in self?.closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        source?.cancel()
        source = nil
        buffer = Data()
        onClose?(self)
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if !drainLines() { return }
                continue
            }
            if count == 0 {
                // Orderly shutdown by the peer.
                closeOnQueue()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            closeOnQueue()
            return
        }
    }

    /// Returns false when the connection was closed while draining.
    private func drainLines() -> Bool {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            dispatch(line: line)
            if isClosed { return false }
        }
        if buffer.count > MCPSocketServer.maximumLineBytes {
            // Never parsed, so there is no id to answer under; say so once and
            // hang up rather than buffering the rest of whatever this is.
            write(
                MCPResponse(
                    id: .null,
                    error: .invalidRequest(
                        "A single JSON-RPC line may not exceed \(MCPSocketServer.maximumLineBytes) bytes."
                    )
                ).framed()
            )
            closeOnQueue()
            return false
        }
        return true
    }

    private func dispatch(line: Data) {
        let server = self.server
        Task { [weak self] in
            guard let reply = await server.handle(line: line) else { return }
            self?.queue.async { [weak self] in self?.write(reply) }
        }
    }

    private func write(_ data: Data) {
        guard !isClosed else { return }
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base, raw.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // The client stopped reading. Wait briefly for room rather
                // than spinning; a client that never drains gets hung up on.
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 5_000) > 0 { continue }
                closeOnQueue()
                return
            }
            closeOnQueue()
            return
        }
    }
}
