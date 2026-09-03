import Foundation

/// Session discovery, parsing, indexing, deletion and the MCP transport were
/// extracted into `agent-session-kit`. Re-exporting the package means every
/// call site inside `VibeBarCore` and `VibeBarApp` keeps referring to
/// `Harness`, `SessionSummary`, `MCPJSON` and friends without an extra
/// import, exactly as when those types were declared here.
///
/// The rest of this file is the seam: the package takes explicit paths and
/// explicit configuration everywhere Vibe Bar used to bake in a default, so
/// the host-shaped defaults live here instead of in the library.
@_exported import AgentSessionKit

// MARK: - CostUsageScanner primitives that became package utilities

/// The cost scanner still owns *pricing* and *ledger* concerns, but the file
/// walking and the harness recognition it shares with the session adapters
/// are now the package's. These forwarders keep both call sites and their
/// tests on the name they have always used.
extension CostUsageScanner {
    /// Linear-time JSONL walk. See `JSONLLineScanner.forEachLine`.
    @discardableResult
    static func forEachJSONLLine(in file: URL, _ body: (Data) -> Void) -> Bool {
        JSONLLineScanner.forEachLine(in: file, body)
    }

    static var claudeCoworkDirectoryName: String { ClaudeCoworkPaths.directoryName }

    static func claudeCoworkRoot(homeDirectory: String) -> URL {
        ClaudeCoworkPaths.root(homeDirectory: homeDirectory)
    }

    static func collectClaudeCoworkJSONL(under root: URL) -> [URL] {
        ClaudeCoworkPaths.collectJSONL(under: root)
    }

    static func claudeHarness(file: URL) -> Harness {
        ClaudeCoworkPaths.harness(forFile: file)
    }

    static var chatgptWorkOriginator: String { CodexOriginator.chatgptWork }

    static func codexHarness(originator: String?) -> Harness {
        CodexOriginator.harness(originator: originator)
    }
}

/// AntiGravity's `gen_metadata` blob reader. The package names it for what it
/// reads rather than for the Vibe Bar service that first needed it.
public typealias AntigravitySessionReader = AntigravityGenMetadataReader

// MARK: - MCP transport

/// `MCPServer` is Vibe Bar's dispatch; `MCPSocketServer` and `MCPStdioBridge`
/// are the package's transports, and this is the one line that joins them.
extension MCPServer: MCPLineHandler {}

extension MCPSocketServer {
    /// `~/.vibebar/mcp.sock`. The package deliberately has no default — it
    /// will not pick a path under someone else's home — so the location Vibe
    /// Bar documents in `AGENTS.md` § 5.1 is named here.
    public static var defaultSocketPath: String {
        VibeBarLocalStore.baseDirectory.appendingPathComponent("mcp.sock").path
    }

    /// Bind Vibe Bar's dispatch to a socket.
    ///
    /// Only the app's own directory is created (and forced to 0700). A custom
    /// path — tests, the documented `VIBEBAR_MCP_SOCKET` override — must
    /// already have its directory, because chmod-ing someone else's is not
    /// this server's business.
    ///
    /// `idleTimeout` is passed through because the package cannot choose one:
    /// it does not know whether its host's clients respawn after an EOF. Vibe
    /// Bar does — see `MCPController.clientIdleTimeout`.
    public convenience init(
        server: MCPServer,
        socketPath: String = MCPSocketServer.defaultSocketPath,
        idleTimeout: TimeInterval? = MCPSocketServer.defaultIdleTimeout
    ) {
        self.init(
            handler: server,
            socketPath: socketPath,
            idleTimeout: idleTimeout,
            ensureDirectory: {
                guard socketPath == MCPSocketServer.defaultSocketPath else { return }
                try VibeBarLocalStore.ensureBaseDirectory()
            }
        )
    }
}

extension MCPStdioBridge {
    /// The argv token every MCP client config carries, and the environment
    /// override that lets a second build (or a test) point at a temporary
    /// socket. Both are Vibe Bar's published vocabulary — see `AGENTS.md`
    /// § 5.1 and `docs/agent-setup/` — so they are pinned here rather than
    /// left to a call site.
    public static let commandLineFlag = "--mcp-stdio"

    public static let socketPathEnvironmentKey = "VIBEBAR_MCP_SOCKET"

    public static var config: MCPStdioBridgeConfig {
        MCPStdioBridgeConfig(
            flag: commandLineFlag,
            envKey: socketPathEnvironmentKey,
            defaultSocketPath: MCPSocketServer.defaultSocketPath,
            notRunningMessage: { path in MCPStdioBridge.notRunningMessage(for: path) }
        )
    }

    public static func isRequested(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        isRequested(config, arguments: arguments)
    }

    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        socketPath(config, environment: environment)
    }

    public static func run(
        socketPath path: String,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        run(config, socketPath: path, input: input, output: output, standardError: standardError)
    }

    /// The default socket is spelled with a tilde because that is how the
    /// user knows it; a custom one is printed literally, because abbreviating
    /// a path the caller chose would only obscure the mistake.
    static func notRunningMessage(for path: String) -> String {
        let display = path == MCPSocketServer.defaultSocketPath ? "~/.vibebar/mcp.sock" : path
        return "Vibe Bar is not running (socket \(display) not found). Launch \"Vibe Bar.app\" first."
    }
}
