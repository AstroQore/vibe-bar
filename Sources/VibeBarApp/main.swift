import Darwin
import Foundation
import VibeBarCore

// `--mcp-stdio` must never touch AppKit: MCP clients spawn this binary as a
// plain child process — sometimes inside a sandbox (Codex's managed sandbox
// aborted with SIGABRT when NSApplication came up) — and all it has to do is
// pump stdin/stdout to the running app's socket. Decide that here, before
// SwiftUI's `App.main()` brings up NSApplication, the Dock, or any window.
if CommandLine.arguments.dropFirst().contains(MCPStdioBridge.commandLineFlag) {
    exit(MCPStdioBridge.run(socketPath: MCPStdioBridge.socketPath()))
}

VibeBarApp.main()
