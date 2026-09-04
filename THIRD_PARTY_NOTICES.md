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

### vibe-bar-i18n

- Project:
  [AstroQore/vibe-bar-i18n](https://github.com/AstroQore/vibe-bar-i18n)
- Use: every user-facing string, in every language the app ships, as a
  Swift package (`VibeBarLocalization`) pinned to an exact tag in
  `Package.swift`. The catalogue is shared with the cross-platform client.
- License: MIT (in-house; a permissive catalogue is a normal dependency of
  a copyleft app, and a translator should not have to reason about copyleft
  to contribute a language).

## Bundled assets

### Lobe Icons

- Project: [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons)
- Use in Vibe Bar: `Resources/ProviderIcons/ProviderIcon-googleai.svg` is
  Google's four-segment G taken from that project's `icons/google.svg`, with
  the viewBox cropped to the mark and the brand colours dropped because the
  renderer tints the shape. No other provider icon comes from this project.
- License: [MIT](Resources/ThirdPartyLicenses/LobeIcons.txt)
  ([upstream](https://github.com/lobehub/lobe-icons/blob/master/LICENSE))
- Copyright: Copyright (c) 2023 LobeHub

Brand marks in `Resources/ProviderIcons/` remain the trademarks of their
respective owners; Vibe Bar draws them to identify the service a quota belongs
to, and the license above covers only the copied vector artwork.

## Direct dependencies

### SweetCookieKit 0.5.2

- Project: [steipete/SweetCookieKit](https://github.com/steipete/SweetCookieKit)
- Use in Vibe Bar: local Safari, Chromium, and Firefox cookie access, plus
  exact-field Chromium localStorage reads for browser-backed credentials.
- License: [MIT](Resources/ThirdPartyLicenses/SweetCookieKit.txt)
  ([upstream](https://github.com/steipete/SweetCookieKit/blob/v0.5.2/LICENSE))

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
