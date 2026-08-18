# Set me up for Vibe Bar

**You are an AI coding agent. This document is addressed to you, not to a
human. Read it end to end, then do the work.**

Your job is to connect the agent you are running inside to Vibe Bar's local
MCP server, install the companion skill, and verify that both work. Report
back what you changed. Ask the user before writing to any file outside the
ones named here.

Vibe Bar is a macOS menu-bar app that tracks the user's AI subscription
quota, token usage, spend, provider status and local agent sessions. Its MCP
server exposes all of that read-only over a Unix domain socket in the user's
home directory. There is no network port, no API key, and no token — the
socket's file permissions are the access control, and it exists only while
the app is running.

---

## 0. Preconditions

Check these first and stop with a clear message if one fails.

1. **macOS.** The socket, the app and the binary path are all macOS-only.
2. **Vibe Bar is installed.** Expect the bundle at
   `/Applications/Vibe Bar.app`.

   ```sh
   ls -d "/Applications/Vibe Bar.app" 2>/dev/null \
     || echo "Vibe Bar is not installed in /Applications."
   ```

   If it is somewhere else, find the real path and use that bundle's
   `Contents/MacOS/VibeBar` everywhere below instead. If it is not installed
   at all, tell the user to install it from
   <https://github.com/AstroQore/vibe-bar> and stop.
3. **Vibe Bar is running.** The socket only exists while it is.

   ```sh
   ls -l ~/.vibebar/mcp.sock 2>/dev/null \
     || echo "Vibe Bar is not running, or its MCP server is switched off."
   ```

   If the socket is missing, ask the user to launch Vibe Bar and confirm
   Settings → MCP Server → “Enable the local MCP server” is on. You can still
   write the client configuration without the socket; verification in step 3
   will just have to wait.

Throughout this document, `VIBEBAR_BIN` means:

```
/Applications/Vibe Bar.app/Contents/MacOS/VibeBar
```

Note the space in `Vibe Bar.app` — quote the path everywhere.

---

## 1. Detect which client you are running in

Every client runs the same command; only the config file differs. Work out
which of these you are, in this order:

| You are | Tell-tale signs |
| --- | --- |
| **Claude Code** | The `claude` CLI is on `PATH`; `~/.claude/` exists; your system prompt calls you Claude Code. |
| **Codex CLI** | `~/.codex/config.toml` exists; the `codex` CLI is on `PATH`. |
| **Cursor** | You are running inside the Cursor editor; `~/.cursor/` exists. |
| **Something else** | None of the above. Use the generic stdio entry in §2.4. |

If you genuinely cannot tell, ask the user rather than writing three configs.

---

## 2. Configure the MCP server

### 2.1 Claude Code

Run:

```sh
claude mcp add --scope user vibebar -- "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar" --mcp-stdio
```

`--scope user` makes it available in every project. Use `--scope project` if
the user explicitly wants it only here.

### 2.2 Codex CLI

Append to `~/.codex/config.toml` (create the file if it does not exist; do
not disturb existing sections):

```toml
[mcp_servers.vibebar]
command = "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar"
args = ["--mcp-stdio"]
```

### 2.3 Cursor

Merge into `~/.cursor/mcp.json`. If the file already has an `mcpServers`
object, add the `vibebar` key to it rather than replacing the file:

```json
{
  "mcpServers": {
    "vibebar": {
      "command": "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar",
      "args": ["--mcp-stdio"]
    }
  }
}
```

### 2.4 Any other stdio MCP client

Register a stdio server whose command is `VIBEBAR_BIN` with the single
argument `--mcp-stdio`. As a JSON fragment for the client's own server map:

```json
"vibebar": {
  "command": "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar",
  "args": ["--mcp-stdio"]
}
```

Restart or reload the client if it does not pick up new servers live.

---

## 3. Verify

First, prove the bridge works at all — this needs no client restart:

```sh
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar" --mcp-stdio
```

You should see two JSON lines. The first carries
`"serverInfo":{"name":"vibebar",…}`; the second lists the tools, including
`quota.get`. If instead you see

```
Vibe Bar is not running (socket ~/.vibebar/mcp.sock not found). Launch "Vibe Bar.app" first.
```

then the app is not running — go back to §0.3.

Then verify through the client itself: list your MCP tools, confirm
`vibebar` appears with `quota.get` among them, and call `quota.get` **once**.
Report the user's actual remaining quota back to them as proof it worked.

---

## 4. Install the companion skill

The skill teaches an agent which tool answers which question and, more
importantly, the naming rules that keep the answers correct. Install it.

The skill lives in this repository at
`docs/agent-setup/skill/vibe-bar/`. Fetch it from

```
https://raw.githubusercontent.com/AstroQore/vibe-bar/main/docs/agent-setup/skill/vibe-bar/SKILL.md
```

**Preferred: let Vibe Bar manage it.** Vibe Bar has a Skills manager
(Workbench → Skills) that keeps one copy in `~/.agents/skills/` and projects
it into each agent's own skills directory. If the user already uses it, tell
them to add the skill there instead of copying files yourself, and skip the
rest of this section.

**Otherwise, install by hand:**

1. Write the skill to the shared location:
   `~/.agents/skills/vibe-bar/SKILL.md`.
2. Also place it in your own client's skills directory, if it has one:

   | Client | Skills directory |
   | --- | --- |
   | Claude Code | `~/.claude/skills/vibe-bar/` |
   | Codex CLI | `~/.codex/skills/vibe-bar/` |
   | Gemini CLI | `~/.gemini/skills/vibe-bar/` |
   | Grok | `~/.grok/skills/vibe-bar/` |
   | Hermes | `~/.hermes/skills/vibe-bar/` |
   | OpenCode | `~/.config/opencode/skills/vibe-bar/` |
   | AntiGravity | `~/.gemini/config/skills/vibe-bar/` |

   Cursor has no managed skills directory in this list. Rely on the MCP
   server's own `vibebar://naming-spec` and `vibebar://tools` resources
   there — read them at the start of any Vibe Bar question.

3. Create only the directories you need, one component at a time. Do not
   touch anything else under `~/.agents/` or the client directories.

---

## 5. What not to do

- **Do not expose the socket.** Never proxy `~/.vibebar/mcp.sock` over TCP,
  SSH, a tunnel, or a network MCP gateway. It is unauthenticated by design
  because it is unreachable by design.
- **Do not relax its permissions.** It is mode 0600 inside a 0700 directory.
  Leave it that way.
- **Do not paste credentials anywhere.** Vibe Bar reads the user's provider
  cookies and tokens itself and never exposes them over MCP. If any step
  seems to want an API key, you have misread it — there is no key.
- **Do not poll.** `quota.get` is a cache read and cheap; `quota.refresh`
  calls the providers. Refresh at most once every few minutes, and prefer the
  default (stale-only) form over `force: true`. Forced refreshes are
  rate-limited to one every 20 seconds and can be switched off entirely.
- **Do not write to `~/.vibebar/`.** It is the app's own state.
- **Do not create a launch agent** or otherwise try to keep the socket alive
  when Vibe Bar is quit. "Not running" is a correct answer.

---

## 6. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Vibe Bar is not running (socket … not found)` | The app is quit, or Settings → MCP Server is off. Launch it and re-check the toggle. |
| The client shows the server as failed at startup | It launched before Vibe Bar did. Restart the client, or just retry — the bridge is spawned per session. |
| `command not found` / the server never starts | The path is wrong or unquoted. `Vibe Bar.app` contains a space; the whole path must be one quoted argument. |
| Tools list is empty | You connected to something else. Confirm `serverInfo.name` is `vibebar`. |
| `sessions.search` returns nothing | The session index has not been built. Ask the user to open Vibe Bar's Workbench → Sessions once. Body search additionally needs session body indexing enabled in Settings. |
| `cost.snapshot` reports zeros with `privacyModeEnabled: true` | The user turned cost tracking off in Settings → Cost Data. Report that, not "you spent nothing". |
| `quota.refresh` returns `triggered: false` | Either nothing was stale (the normal, good case) or refreshing from agents is switched off in Settings → MCP Server. The message says which. |
| A cost total looks too low | Check `unpricedRequests`. A model with no rate card contributes 0; `pricing.effective` shows what is priced. |

---

## 7. When you are done

Tell the user, in one short message:

- which client you configured and which file you edited,
- that verification succeeded, with one real number from `quota.get` as
  evidence,
- where the skill was installed,
- and that the connection only works while Vibe Bar is running.
