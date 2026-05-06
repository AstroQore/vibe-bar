# Contributing to Vibe Bar

Thanks for helping improve Vibe Bar. The project is a native macOS menu-bar app
for Codex and Claude Code users, so changes should keep that workflow clear,
private, and fast.

## Commit Identity

Direct commits in this repository must use the shared maintainer identity:

```sh
git config --local user.name  "Vibe Bar Maintainers"
git config --local user.email "noreply@github.com"
```

Use `Co-Authored-By:` trailers in commit messages if you want explicit personal
attribution. Do not publish personal emails, machine hostnames, internal handles,
or local user paths through commit metadata or fixtures.

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

The codesign output should still include the app sandbox, network client access,
and home-relative-path entitlements used by the app.

## Privacy Rules

- Do not commit real tokens, cookies, JWTs, organization IDs, account IDs, or
  email addresses.
- Do not add `/Users/<name>` paths. Use `/Users/example/...` in fixtures and
  documentation when a home path is needed.
- Do not log raw credentials or email addresses. Use `SafeLog.sanitize` and
  `EmailMasker`.
- New persistent state should go through `VibeBarLocalStore` and live under
  `~/.vibebar/`.
- Keep the app sandboxed. Add narrow temporary exceptions only when they are
  required for a specific file access path.

## Implementation Notes

- Keep heavy logic in `VibeBarCore`; keep UI glue in `VibeBarApp`.
- JSONL scanning must stay linear. Use the moving-cursor style from
  `CostUsageScanner.forEachJSONLLine`.
- Avoid deep `TimelineView(.periodic(...))` trees. Scope live timers to visible
  UI surfaces.
- Keep mini-window geometry in `mini_window_geometry.json` instead of folding it
  into `AppSettings`.
