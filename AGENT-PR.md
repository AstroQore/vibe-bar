# Pull Request Guide for Agents

Read this if you are an AI coding agent (Claude Code, Codex, Cursor, Aider,
etc.) and you have been asked to contribute changes back to Vibe Bar via a
pull request. Pair this with [AGENT-DEPLOY.md](AGENT-DEPLOY.md) for the
build commands and with [CONTRIBUTING.md](CONTRIBUTING.md) for the
human-facing version of the same rules.

## Repository

- Upstream: `AstroQore/vibe-bar` on GitHub.
- Default branch: `main`.
- License: AGPL-3.0-only. Any contribution is licensed under AGPL-3.0.

## End-to-end PR workflow

```sh
# 1. Branch from main
git checkout main
git pull --ff-only
git checkout -b <short-topic-branch-name>

# 2. Make your change. Keep edits scoped to the topic.

# 3. Verify locally — all of these must pass before pushing.
swift build
swift test
./Scripts/build_app.sh release
codesign -d --entitlements - ".build/Vibe Bar.app"

# 4. Commit with your own identity.
git add <files>
git commit -m "<imperative subject line>"

# 5. Push the branch.
git push -u origin <short-topic-branch-name>

# 6. Open the PR.
gh pr create --base main \
  --title "<imperative subject line>" \
  --body  "$(cat <<'EOF'
## Summary
- <one-line bullet>
- <another bullet>

## Test plan
- [ ] swift test
- [ ] ./Scripts/build_app.sh release
- [ ] manual smoke test (describe what you clicked / observed)
EOF
)"
```

## Commit identity

Use your own git identity. There is no shared maintainer alias.

If you do not want your personal email in the public log, configure
GitHub's privacy email (`<id>+<login>@users.noreply.github.com`) for this
repo only:

```sh
git config --local user.name  "Your GitHub Name"
git config --local user.email "<id>+<login>@users.noreply.github.com"
```

`Co-Authored-By:` trailers are welcome when more than one human or agent
contributed materially to a commit.

## Commit message style

Match what `git log` shows on `main`:

- Subject line is imperative, ≤ 70 characters, no trailing period.
- No type prefixes (`feat:`, `fix:`, `chore:`). Just write the change.
- Body wraps at ~72 chars, explains *why* and any non-obvious *how*. Skip
  the body for trivial changes.
- Mention `Co-Authored-By:` trailers at the end if you collaborated.

Example:

```
Tint provider brand icons via SwiftUI color scheme

ProviderBrandIconView passed NSColor.labelColor without an NSAppearance,
so the dynamic color resolved against whatever appearance happened to
be current when the off-screen NSImage rendered. Forward the matching
.darkAqua / .aqua appearance so labelColor resolves correctly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Required local checks before pushing

| Check                                                         | Why it must pass                                  |
| ------------------------------------------------------------- | ------------------------------------------------- |
| `swift build`                                                 | Compiles cleanly under Swift 6.2 / macOS 26.      |
| `swift test`                                                  | Core logic regressions are blocked.               |
| `./Scripts/build_app.sh release`                              | The user-facing bundle still assembles.           |
| `codesign -d --entitlements - ".build/Vibe Bar.app"`          | Sandbox + network + home-relative entitlements still present. |

If you cannot run one of these (no macOS host, no Xcode, etc.), say so
explicitly in the PR description instead of skipping the checkbox.

## What is not allowed in commits

These are source-content rules. They apply regardless of who you commit
as.

- Real OAuth tokens, real session cookies, real organization UUIDs, real
  account IDs, real email addresses anywhere in source, tests, fixtures,
  or log strings.
- `/Users/<name>` paths or machine hostnames in fixtures, examples, or
  output. Use `/Users/example/...` and synthetic JWTs.
- Logging raw credentials or email addresses. Route through
  `SafeLog.sanitize` and `EmailMasker`.
- Dropping the app sandbox in `Resources/VibeBar.entitlements`. If you
  need new file access, add a narrow temporary exception.
- Folding `mini_window_geometry.json` back into `AppSettings`. The split
  is intentional — every settings write fans out to every Combine
  subscriber.

## Code organization (so your PR lands in the right place)

- `Sources/VibeBarCore/` — heavy logic. Parsers, storage, privacy
  helpers, adapters, cost/usage scanners, pricing. Pure Swift, testable,
  no AppKit/SwiftUI imports.
- `Sources/VibeBarApp/` — AppKit/SwiftUI glue. Status item, popover,
  mini window, settings UI. Thin layer over Core.
- `Tests/VibeBarCoreTests/` — `swift test` target. Add a test next to the
  area you changed.
- `Resources/` — `Info.plist`, entitlements, app icon, README assets.
- `Scripts/build_app.sh` — release packaging.

If your change adds heavy logic in `VibeBarApp`, that's usually a sign it
should live in `VibeBarCore` instead.

## Implementation rules that have bitten people

- **JSONL scanning must be O(n).** See
  `CostUsageScanner.forEachJSONLLine`. Use a moving cursor, not
  `removeSubrange`.
- **Avoid `TimelineView(.periodic(...))` in deep view trees** that may be
  eagerly instantiated. Scope live timers to the visible surface.
- **New persistent state** goes through `VibeBarLocalStore` and lives
  under `~/.vibebar/`. Do not write to `~/` directly from new code.
- **Bundle ID** is `com.astroqore.VibeBar`. For a release, bump
  `CFBundleShortVersionString` and `CFBundleVersion` in
  `Resources/Info.plist`.

## After the PR is open

- CI may run additional checks. Address any failures.
- A maintainer may request changes. Push follow-up commits to the same
  branch — do not force-push unless asked, and never force-push `main`.
- Squash vs. merge is the maintainer's call; structure your commits so
  either works.

## When in doubt

`CONTRIBUTING.md` is the human-facing version of this guide and wins on
any conflict. Update this file if you find it has drifted.
