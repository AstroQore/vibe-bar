# Third-Party Notices

Vibe Bar is licensed under the GNU Affero General Public License v3.0 only.
This document records the upstream projects whose code is adapted by Vibe Bar,
the packages it directly includes, and the projects acknowledged as design or
interoperability references.

## Adapted implementations

### CodexBar

- Project: [steipete/CodexBar](https://github.com/steipete/CodexBar)
- Relationship: Vibe Bar adapts or reimplements selected browser-cookie and
  Keychain utilities, provider behaviors, and AntiGravity local-probe logic
  with reference to CodexBar. Individual source files retain focused
  `Ported from`, `Modeled after`, or equivalent attribution where applicable.
- License: [MIT](Resources/ThirdPartyLicenses/CodexBar.txt)
  ([upstream](https://github.com/steipete/CodexBar/blob/main/LICENSE))
- Copyright: Copyright (c) 2026 Peter Steinberger

The complete copyright and permission notice covering the adapted CodexBar
portions is included in this repository at the local license link above.

## In-house packages

### agent-session-kit

- Project:
  [AstroQore/agent-session-kit](https://github.com/AstroQore/agent-session-kit)
- Relationship: maintained by AstroQore, the same organization that
  maintains Vibe Bar. Extracted from this repository, and developed as a
  standalone public package with its own changelog, semver tags, and
  releases.
- Use in Vibe Bar: local coding-agent session discovery, parsing, the
  full-text session index, session deletion planning, harness naming, and
  the local MCP Unix-socket / stdio transport.
- How it is consumed: pinned to an exact tag in `Package.swift` and linked
  statically into `Vibe Bar.app`'s executable — there is no separate
  framework or dylib in the bundle. The version compiled into a build is
  `AgentSessionKitInfo.version`, shown in Settings › System › Components.
- License: AGPL-3.0-only — the same license as Vibe Bar, so no separate
  notice file is bundled.
- Third-party code: none. The package has no dependencies of its own.

## Direct dependencies

### SweetCookieKit 0.4.0 or later compatible releases

- Project: [steipete/SweetCookieKit](https://github.com/steipete/SweetCookieKit)
- Use in Vibe Bar: local Safari, Chromium, and Firefox cookie access.
- License: [MIT](Resources/ThirdPartyLicenses/SweetCookieKit.txt)
  ([upstream](https://github.com/steipete/SweetCookieKit/blob/0.4.0/LICENSE))

### Sparkle 2.9.4

- Project: [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)
- Use in Vibe Bar: signed application update discovery and installation.
- License:
  [Sparkle license and external component notices](Resources/ThirdPartyLicenses/Sparkle.txt)
  ([upstream](https://github.com/sparkle-project/Sparkle/blob/2.9.4/LICENSE))

Dependency versions are declared in `Package.swift`. The complete license
texts and bundled-component notices are stored under
`Resources/ThirdPartyLicenses/`. `Scripts/build_app.sh` packages that directory
and this notice in `Vibe Bar.app/Contents/Resources/` so binary distributions
carry the required notices.

## Reference projects not bundled by these relationships

- [CC Switch](https://github.com/farion1231/cc-switch) — reference and
  interoperability target for unified Skills management. License:
  [MIT](https://github.com/farion1231/cc-switch/blob/main/LICENSE).
- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — ecosystem
  reference for multi-provider CLI account and quota workflows. Vibe Bar does
  not embed, launch, or require CLIProxyAPI. License:
  [MIT](https://github.com/router-for-me/CLIProxyAPI/blob/main/LICENSE).
- [ccusage](https://github.com/ccusage/ccusage) — reference for local token and
  session-cost parsing and pricing semantics. License:
  [MIT](https://github.com/ccusage/ccusage/blob/main/LICENSE).

All project names and trademarks belong to their respective owners. Listing a
project here does not imply affiliation, sponsorship, or endorsement.
