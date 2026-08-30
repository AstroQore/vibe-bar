import Darwin
import Foundation
import VibeBarCore

// A broken pipe must surface as an EPIPE error on the write that hit it,
// never as a process-killing signal. The MCP socket server and the stdio
// bridge both write to peers that can vanish at any moment — an agent
// session disconnecting mid-reply killed the whole app with SIGPIPE after
// hours of uptime (launchd: "exited due to SIGPIPE, sent by VibeBar"), and
// a SIGPIPE death leaves no crash report to find. First thing the process
// does, before the bridge fork-off below and before AppKit.
signal(SIGPIPE, SIG_IGN)

// `--mcp-stdio` must never touch AppKit: MCP clients spawn this binary as a
// plain child process — sometimes inside a sandbox (Codex's managed sandbox
// aborted with SIGABRT when NSApplication came up) — and all it has to do is
// pump stdin/stdout to the running app's socket. Decide that here, before
// SwiftUI's `App.main()` brings up NSApplication, the Dock, or any window.
if MCPStdioBridge.isRequested() {
    exit(MCPStdioBridge.run(socketPath: MCPStdioBridge.socketPath()))
}

// Demo mode redirects the home directory for the whole process, so it has to
// be decided before the first store is opened — which is before AppKit.
do {
    try DemoMode.bootstrap()
} catch {
    FileHandle.standardError.write(Data("vibebar: \(error)\n".utf8))
    exit(2)
}

VibeBarApp.main()
