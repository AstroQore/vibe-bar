# Agent Library Core

The Core service manages selected user-wide MCP definitions and global
instruction files. It performs no server execution, discovery handshake,
automatic sync, repository scan or instruction execution.

Its public entry point is:

```swift
let library = try AgentLibraryService(homeDirectory: syntheticHomeURL)
let inventory = await library.mcpInventory()
let instructions = await library.instructionInventory()
```

The caller must inject a home. Tests inject temporary synthetic homes;
there is no implicit real-home default in this service. The host chooses
when to read a real home and expose a mutation to the user.

## Fixed paths and formats

| Target | MCP file | Global instruction file |
| --- | --- | --- |
| Codex | `.codex/config.toml`, `mcp_servers` tables | `.codex/AGENTS.md` |
| Claude Code | `.claude.json`, `mcpServers` | `.claude/CLAUDE.md` |
| Cursor | `.cursor/mcp.json`, `mcpServers` | No verified file; unsupported |
| Gemini CLI | `.gemini/settings.json`, `mcpServers` | `.gemini/GEMINI.md` |
| Grok Build | `.grok/config.toml`, `mcp_servers` tables | Uses Claude compatibility; no separate file |

The canonical shared instruction file is `.agents/AGENTS.md`.
Codex's non-empty `.codex/AGENTS.override.md` is reported as a higher
priority override and is never silently replaced.

These paths are relative to the injected home. Environment overrides,
project files and other locations are outside this implementation.
Symlinks may resolve only to known files in the same resource allowlist.
Instruction links cannot lead to MCP configuration files. Directory links,
loops, destinations outside the home and arbitrary in-home files are refused.

## Inventory and explicit editing

`mcpInventory()` returns file status/revision and definition summaries.
Summaries contain target, transport, redacted descriptive counts, same-name
peers, equal-content peers and projection ownership. Commands, arguments,
environment values, endpoints, headers and unknown-field values are absent.
The display name is redacted; `operationName` is an opaque lookup token
accepted by read, share and delete. It is not a server name for creation.

`readMCPDefinition(target:name:expectedRevision:)` is an explicit editing
operation. Its returned `AgentMCPDefinition` is Codable and contains the
canonical transport fields plus the original native `rawFields`.
These values may contain credentials and belong only in the selected
editor or source-copy operation. They must not be logged, projected into
normal inventory, sent to a model or included in diagnostics.

Standard fields are edited through `command`, `args`, `environment`,
`url`, `headers` and `transport`. Unknown native fields remain in
`rawFields`. JSON integers retain signed/unsigned 64-bit types instead of
being converted through Double. Unrecognized TOML expressions are opaque:
same-target edits preserve them; changing or migrating them is refused.

The preserving TOML editor regenerates only assignments in the selected
server's table group. Other tables, comments and multiline global
instructions remain unchanged. It does not pretend to be a complete TOML
implementation: ambiguous tables, unsupported MCP inline-table layouts,
unsupported expressions and malformed selected definitions return errors.

## Mutations and sharing

Public operations:

- `saveMCPDefinition(target:definition:expectedRevision:replaceExisting:)`
- `deleteMCPDefinition(target:name:expectedRevision:)`
- `shareMCPDefinition(source:name:sourceRevision:targets:)`
- `readInstruction(id:expectedRevision:)`
- `saveInstruction(id:text:expectedRevision:)`
- `linkCanonicalInstructions(targets:)`
- `removeInstructionProjection(target:expectedRevision:)`
- `restoreBackup(id:expectedRevision:)`

Revisions identify current file content and any leaf symlink chain.
A missing file has revision `missing`. A mutation re-reads and compares
the expected revision, preserves a private backup, checks the baseline
again, and atomically replaces the selected file. Writes never execute the
configured server command or contact its URL. Unselected targets stay intact.

Sharing takes target revisions captured when the user selects them.
An existing different same-name definition is a conflict. A definition
previously shared by this service can be updated when its current content
still matches the last owned write fingerprint. A user or another tool's
change withdraws that permission. A pre-existing equal definition is reused
without claiming ownership.

An actual direct MCP edit or deletion persistently revokes the incoming
receipt for the selected target/name before changing its native configuration.
Recreating the definition or returning to its former values does not restore
that permission. Editing a source keeps the outgoing receipts for its other
destinations, so unchanged Library-owned copies can still be updated.
A whole-config backup restore conservatively revokes every incoming MCP
receipt for that target; other targets and their native files stay intact.
Restoring an instruction projection leaf similarly withdraws its own receipt,
without withdrawing permissions for other leaves or shared-source edits.

Invalid input, conflicts and stale revisions fail before revocation. If
revocation cannot be persisted, the native mutation is aborted. If a later
backup, revision check or native write fails, the withdrawn permission stays
withdrawn and the operation reports failure; it does not roll back over a
concurrent native-file change. Shared writes use the same withdrawal order
and publish new ownership only after a successful native write, using freshly
read receipts rather than resurrecting an earlier snapshot.

MCP projection receipts store source, target, name and content fingerprint
under `.vibebar/agent_library/mcp_projections.json`; they contain no command,
environment or header payload. Conversion uses native fields: Codex
`http_headers`, Grok/Claude/Cursor `headers`, Gemini HTTP `httpUrl`,
Gemini SSE `url`, and explicit `type = "sse"` for Grok. Codex SSE is
refused. Grok's confirmed server-name rules apply to new definitions and
sharing; invalid existing rows remain readable and deletable.

Equal-semantics fields `enabled`, `startup_timeout_sec` and
`tool_timeout_sec` can move between Codex and Grok. Explicit
`enabled = false` is refused for targets without a verified equivalent;
`enabled = true` may map to their default. Other target-specific metadata
has no assumed meaning and cannot be silently dropped during conversion.

Selected targets are processed individually. Results report changed targets,
unchanged targets, per-target error codes and backups. A partial failure
does not masquerade as an all-target success.

## Instruction source and ownership

Inventory exposes logical and resolved paths without executing or
interpreting the text. Editing a selected valid link edits its displayed
shared source, affecting every agent that reads that source, while retaining
the link. Canonical text can be created when its revision is `missing`.

Existing links to the canonical source are reused without acquiring
ownership. A canonical file already pointing to an agent's own source is
also reused; a reverse link would create a cycle. Different pre-existing
text or a different shared-source link remains a conflict.

New canonical projections receive a private receipt and backup. Only a
completed owned projection whose destination is unchanged can be revoked.
Revocation restores the prior file, or removes a leaf originally missing,
without deleting the shared source. A changed projection is refused.

Backups and receipts live under `.vibebar/agent_library`, with private
directories and `0600` files. Restoration is explicit, revision guarded
and limited to original catalog paths. Backups may contain sensitive
configuration and are never normal inventory data.

## Sources and boundaries

Magpie Library was consulted as a design reference for separate resource
types and native formats. Its MIT-licensed implementation was not copied
into this Swift service: [Magpie](https://github.com/yetone/magpie).

Native contracts checked on 2026-09-30:

- [Grok MCP configuration](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/07-mcp-servers.md):
  user TOML, native header fields, SSE type, name rules and enabled behavior.
  HTTP/SSE encoding was also checked using a synthetic project fixture.
- [Cursor SDK configuration](https://cursor.com/docs/sdk/typescript) and
  [native MCP settings](https://prod.cursor.com/help/customization/mcp):
  URL/header definitions, with SDK transport declarations preserved.
- [Codex global instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md):
  non-empty override precedence.

No network handshake was performed. `AgentLibraryError` provides stable
internal codes; the UI supplies localized copy. This Core patch changes no
UI hierarchy, Skills behavior, RTK integration or live credentials.
