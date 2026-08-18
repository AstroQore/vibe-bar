import Foundation

/// The client-side setup lines, in one place.
///
/// Settings' copy buttons and `docs/agent-setup/prompt.md` have to agree
/// exactly — a doc that drifts from the button is how someone ends up with a
/// half-configured client — so the strings live here rather than being typed
/// twice. Every client gets the same command; only the file format differs.
public enum MCPClientConfig {
    /// Where an installed Vibe Bar keeps its executable. Used when the running
    /// bundle cannot report its own path (a `swift run` build has no bundle).
    public static let canonicalExecutablePath = "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar"

    /// The one line a user pastes into any agent to have it configure itself.
    /// Kept verbatim in `MCPSettingsSection` and in the README.
    public static let agentSetupPrompt =
        "Fetch and execute the appropriate instructions to set me up for Vibe Bar from "
        + "https://raw.githubusercontent.com/AstroQore/vibe-bar/main/docs/agent-setup/prompt.md"

    public static let serverName = "vibebar"

    /// `claude mcp add` needs the `--` separator, and the executable path
    /// contains a space, so it has to stay quoted.
    public static func claudeCodeCommand(executablePath: String = canonicalExecutablePath) -> String {
        "claude mcp add --scope user \(serverName) -- \"\(executablePath)\" \(MCPStdioBridge.commandLineFlag)"
    }

    /// A `[mcp_servers.…]` block for `~/.codex/config.toml`.
    public static func codexTOML(executablePath: String = canonicalExecutablePath) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(executablePath)"
        args = ["\(MCPStdioBridge.commandLineFlag)"]
        """
    }

    /// `~/.cursor/mcp.json`.
    public static func cursorJSON(executablePath: String = canonicalExecutablePath) -> String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "command": "\(executablePath)",
              "args": ["\(MCPStdioBridge.commandLineFlag)"]
            }
          }
        }
        """
    }

    /// The `mcpServers` entry on its own, for a client whose config file this
    /// has to be merged into rather than replace.
    public static func genericJSON(executablePath: String = canonicalExecutablePath) -> String {
        """
        "\(serverName)": {
          "command": "\(executablePath)",
          "args": ["\(MCPStdioBridge.commandLineFlag)"]
        }
        """
    }
}
