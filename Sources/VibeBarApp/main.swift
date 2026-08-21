import Darwin
import Foundation
import VibeBarCore

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
