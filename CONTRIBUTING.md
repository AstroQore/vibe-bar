# Contributing to Vibe Bar

Thanks for helping improve Vibe Bar. The project is a native macOS menu-bar app
for Codex and Claude Code users, so changes should keep that workflow clear,
private, and fast.

## Commit Identity

Use your own git identity — there is no shared maintainer alias. If you want
to keep your personal email out of the public log, configure GitHub's
privacy email (`<id>+<login>@users.noreply.github.com`) for this repo:

```sh
git config --local user.name  "Your GitHub Name"
git config --local user.email "<id>+<login>@users.noreply.github.com"
```

Do not commit personal emails, machine hostnames, internal handles, or
`/Users/<name>` paths inside source files, fixtures, or logs — that's a
source-content rule, not a commit-author rule.

## Development Setup

Vibe Bar is a Swift package with two main targets:

- `VibeBarCore`: parsers, storage, privacy helpers, adapters, and usage logic.
- `VibeBarApp`: AppKit/SwiftUI menu-bar app, windows, and UI glue.

Before opening a pull request, run:

```sh
swift build
swift test
./Scripts/build_app.sh release
codesign -d --entitlements - ".build/Vibe Bar.app"
```

Vibe Bar runs **unsandboxed** so the misc-providers feature can read
browser cookies and probe AntiGravity. The codesign output should be
an empty `<dict/>` plist with no `com.apple.security.app-sandbox` key.
See `AGENTS.md` § 6 for the full reasoning.

## Privacy Rules

- Do not commit real tokens, cookies, JWTs, organization IDs, account IDs, or
  email addresses.
- Do not add `/Users/<name>` paths. Use `/Users/example/...` in fixtures and
  documentation when a home path is needed.
- Do not log raw credentials or email addresses. Use `SafeLog.sanitize` and
  `EmailMasker`.
- New persistent state should go through `VibeBarLocalStore` and live under
  `~/.vibebar/`.
- Vibe Bar runs unsandboxed by design (see `AGENTS.md` § 6), but treat
  the user's filesystem with the same discipline a sandboxed app would:
  read only the credential / cookie / config files you actually need,
  never write outside `~/.vibebar/`, and never log raw secrets.

## Implementation Notes

- Keep heavy logic in `VibeBarCore`; keep UI glue in `VibeBarApp`.
- JSONL scanning must stay linear. Use the moving-cursor style from
  `CostUsageScanner.forEachJSONLLine`.
- Avoid deep `TimelineView(.periodic(...))` trees. Scope live timers to visible
  UI surfaces.
- Keep mini-window geometry in `mini_window_geometry.json` instead of folding it
  into `AppSettings`.
