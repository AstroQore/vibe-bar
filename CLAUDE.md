# CLAUDE.md

Auto-loaded by Claude Code at the start of every session in this
repository. The full operating manual for AI agents — including the
canonical project layout, build/test/package/install flow, sandbox
rule, PR workflow, and release checklist — is in
[AGENTS.md](AGENTS.md). Read it whenever you are about to:

- Touch any code, resource, or script in this repo.
- Build, sign, or smoke-test the `.app` bundle.
- Open a pull request against `AstroQore/vibe-bar`.
- Cut a release.
- Investigate a "the app launches but everything is empty" report.

`AGENTS.md` is self-contained and authoritative. The companion docs
([AGENT-DEPLOY.md](AGENT-DEPLOY.md), [AGENT-PR.md](AGENT-PR.md),
[CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[README.md](README.md), [README.zh-CN.md](README.zh-CN.md)) are focused
or human-facing subsets — `AGENTS.md` is the version Claude should
default to.

## Project at a glance

- **What it is.** A native macOS menu-bar app for Codex and Claude Code
  users. Pure Swift package, sandboxed, distributed as source. No
  Xcode workspace, no installer, no notarized release, no production
  server.
- **Targets.** `VibeBarApp` (AppKit/SwiftUI executable) and
  `VibeBarCore` (pure-Swift testable library). Heavy logic lives in
  Core; UI glue in App.
- **Build output.** `.build/Vibe Bar.app` (literal space in the name).
  Optional install location: `/Applications/Vibe Bar.app`.
- **License.** AGPL-3.0-only. Bundle ID `com.astroqore.VibeBar`.
- **Persistence.** Real user home: `~/.vibebar/`. Keychain holds Claude
  session cookies and the resolved Claude organization ID.
- **Toolchain.** macOS 26 (Tahoe) or newer, Xcode 26 / Swift 6.2.

## Critical rules for Claude

These five rules cause silent failures or public-repo accidents if
ignored. The full reasoning and grep recipes live in `AGENTS.md`.

1. **Sandbox home directory.** Any path under the real user home
   (`~/.codex/`, `~/.claude/`, `~/.config/claude/`, `~/.vibebar/`) must
   resolve through
   `Sources/VibeBarCore/Utilities/RealHomeDirectory.swift`. Never
   `NSHomeDirectory()`, `FileManager.default.homeDirectoryForCurrentUser`,
   `NSHomeDirectoryForUser`, `URL.homeDirectory`, or `getenv("HOME")` —
   every one of those is rewritten by the sandbox and silently breaks
   the app. See `AGENTS.md` § 6.
2. **No secrets or personal paths in source.** No real OAuth tokens,
   real session cookies, real organization UUIDs, real account IDs,
   real email addresses, `/Users/<name>` paths, or machine hostnames in
   source, tests, fixtures, or log strings. Use `/Users/example/...`
   and synthetic JWTs. Route credential or email logging through
   `SafeLog.sanitize` / `EmailMasker`.
3. **Never drop the app sandbox.** If new file access is required, add
   a narrow `home-relative-path` temporary exception in
   `Resources/VibeBar.entitlements`. Re-verify entitlements after
   building with
   `codesign -d --entitlements - ".build/Vibe Bar.app"`.
4. **Verification before completion.** Before claiming a change works,
   run all four:

   ```sh
   swift build
   swift test
   ./Scripts/build_app.sh release
   codesign -d --entitlements - ".build/Vibe Bar.app"
   ```

   Then `open ".build/Vibe Bar.app"` and confirm
   `~/Library/Containers/com.astroqore.VibeBar/Data/` did not gain a
   shadow `.codex/`, `.claude/`, or `.vibebar/` tree.
5. **Use AQ's GitHub privacy email identity.** This repo's local git
   config is already set; do not overwrite it with a personal mailbox.
   Match the existing log style: imperative subject ≤ 70 chars, no
   `feat:`/`fix:`/`chore:` prefixes, optional `Co-Authored-By:`
   trailer. Never force-push `main`.

## Heavy lifting

For maintenance flows that AQ owns on his Mac (sync → change → build →
test → sign → smoke-test → optional install → commit → push to
`AstroQore/vibe-bar`), there is a dedicated maintainer skill
`vibe-bar-maintainer`. Invoke it whenever the work is "AQ asked me to
maintain Vibe Bar." For one-off contributor work (e.g. a guest agent
opening a PR), `AGENTS.md` plus this file are sufficient.
