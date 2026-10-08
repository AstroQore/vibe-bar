# Agent Library

The Workbench's Library occupies the existing Skills navigation position.
Its three tabs manage Skills, MCP servers, and AGENTS.md resources.

The design was informed by [Magpie's Library](https://github.com/yetone/magpie/tree/4f01baa65f23bf610df4ee849f0b3848d459174b/internal/library):
show the resource source, agent assignments, and the ownership of each change.
Vibe Bar applies those ideas to its shared skills root and native configuration
files, with its existing Workbench layout.

## Skills

Managed skills retain the existing install, import, update, copy, native
activation, and backup actions. Repository source badges open the repository.

Discovered shared entries are read from `~/.agents/skills` on every visible
inventory refresh, even when the registry already contains skills. They
include real directories and valid directory symlinks. A linked entry shows
both its shared path and its resolved source, with a bounded SKILL.md preview
and Finder reveal actions. The source tree is not recursively hashed.

Discovery does not add entries to `skills.json`, copy source files, create
projections, or adopt ownership. Only an explicit user action does. Adopt link
(on the row, or the linked section of Import Existing) records the link and a
receipt — its target string, resolved directory, and that directory's
device/inode — and changes nothing on disk. A link whose source lies inside,
or contains, a folder Vibe Bar writes (the shared root or a harness skills
folder) is not adoptable: its row says the link is managed elsewhere. Projections are created only when
the user then switches a harness on, and only inside the allowlisted skills
folders: always a symlink to `~/.agents/skills/<name>`, never a copy. The
external folder is never written, recursively hashed, or copied, unless the
user explicitly converts the skill to a copy (confirmed, and bounded by the
archive budget). Broken links, link cycles, missing SKILL.md, and unreadable
or oversized sources remain visible with their current state. An existing
owned registry record whose directory became a symlink is shown once through
this read-only inventory and can be adopted as a link; until then its target
does not acquire update, replace, or uninstall actions.

An adopted link is managed like any other skill: per-harness toggles, bulk
actions, and native switches. Its row menu adds Reveal Source, Re-confirm
Source, Convert to Copy, and Unlink, which replaces Uninstall: it removes the
link's projections, its native per-skill switches, and the link itself (only
while it still points where the receipt says), and backs up the link's target
string rather than the folder. When the receipt stops matching — the link was
re-pointed, broken, replaced by a folder, or removed — every write is refused
and the entry returns to the read-only inventory as "Source changed", with
Re-confirm Source (once the link is readable again) and, where the recorded
link is still the one on disk or is gone, Unlink. Re-confirming and converting
keep the skill's name: native switches are keyed by name, so a linked folder
whose SKILL.md now names a different skill is unlinked and adopted again
rather than renamed in place. The copies sheet lists a
linked skill's other copies without comparing any of them.

Availability and header counts use the same native settings and current
projection evidence. A harness that reads the shared root can see a discovered
skill without an extra link; a native disable is reported separately. Bulk
operations select managed registry entries, adopted links included. Import
Existing is the explicit action for bringing supported real shared directories
under management, and lists shared links for adoption, unchecked by default.

## MCP servers

The inventory names the source configuration file, transport, and agents with
the same configuration. It displays redacted metadata rather than arguments,
environment values, or headers. Merely sharing a name does not mean two
agents have the same definition.

Add and Edit use a form for the name, target agent, transport, command or URL,
arguments, environment, and headers. Arrays and maps use local JSON fields.
Unknown provider fields remain in the private editing snapshot and are
preserved; internal fields are never exposed as user-editable settings.
Definitions whose canonical field types cannot be interpreted safely are
read-only in the editor.

Sharing selects individual target agents. The dialog captures their revisions
when it opens, and Core verifies those revisions before applying changes.
Conflicts, unsupported conversion, and changed targets produce actionable
messages. Configuration is separate from network health: opening Library
does not start a command or perform an MCP handshake.

## AGENTS.md

The shared source is `~/.agents/AGENTS.md`. A missing source opens an empty
creation draft that can be saved before linking agents to it. The inventory
and editor show logical and resolved paths plus the agents sharing that
resolved source. Editing through an agent link therefore visibly identifies
the shared file that changes.

Codex override precedence is shown when an active AGENTS.override.md exists.
Unsupported global instruction targets are reported explicitly. Linking uses
Core's conflict and revision checks. Existing user links are reused without
being claimed; Remove Link is available for projections owned by Vibe Bar and
restores their backed-up prior state.

Every mutation is an explicit user action through AgentLibraryService. The
Core format mappings, backups, receipts, and write boundaries are documented
in [agent-library-core.md](agent-library-core.md). Automated verification and
review demos use synthetic homes, including synthetic linked skill sources.
