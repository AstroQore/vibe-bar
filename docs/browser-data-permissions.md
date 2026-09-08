# Browser data access on macOS

Settings > Permissions overview collects browser data, Keychain metadata,
Terminal/iTerm automation and login-item status in one place. The browser
check is also available in Misc Providers and the setup assistant. Run **Check access** for the browser, open **Files & Folders**,
then return and check again. The check runs inside Vibe Bar and only opens
cookie files and reads/discards one byte. It does not decrypt, import or log
cookies, and does not query or modify the TCC database.

The displayed result is a point-in-time file-read result, not an authoritative
TCC permission status. Missing data, denied access, other I/O failures, and
partial access to multiple profiles remain distinct. A readable file does not
prove a valid web session or permission to decrypt it using Keychain.

## macOS 27 changes

Apple's [macOS 27 Beta 8 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
state that:

- Cross-team app container access is denied by default instead of displaying
  an authorization prompt; users manage it in Privacy & Security (161835690).
- XProtect can also restrict app data commonly targeted by malware (178668601).
- Processes without a bundle ID cannot receive individual container grants
  in Files & Folders (184660124). Vibe Bar has a bundle ID, so this alone does
  not diagnose a failed Vibe Bar grant.
- Apps can no longer access the local TCC database directly (90775556).

After removing an entry, run the check from the intended Vibe Bar app copy so
macOS sees a new access attempt. A new prompt or reappearing row is controlled
by macOS and is not guaranteed. Opening System Settings alone does not request
access. If a grant still fails, quit other Vibe Bar copies, launch the intended
copy, and repeat the check. The view shows the running app path to identify it.

Full Disk Access is a broader, user-controlled fallback, not a requirement of
the checker. It covers other protected files too. Quit and reopen the app after
changing it; remove the grant when no longer needed. It does not repair an
unstable signing identity.

## Keeping permissions across builds

Vibe Bar's default build is ad-hoc signed. Its designated requirement is tied
to a code hash that can change when the app is rebuilt. Apple's
[DTS guidance](https://developer.apple.com/forums/thread/125438) explicitly warns
that ad-hoc signing causes TCC problems. This explains potential grant loss
across builds, but does not prove why an unchanged running build's toggle
would switch off. That symptom needs separate macOS diagnostics.

For distributed updates, use the same Developer ID signing identity, bundle
identifier, and installation location. The existing build and release scripts
accept `VIBEBAR_CODESIGN_IDENTITY`; the release workflow supports certificate
import and notarization as documented in [RELEASING.md](../RELEASING.md).
Changing from ad-hoc to certificate signing requires a fresh user grant.

For local-only builds, a fixed self-signed **Code Signing** certificate is a
candidate when no Apple signing certificate is available. Apple's
[Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
describes creating one in Keychain Access > Certificate Assistant. Apple
explains that it can establish continuity between versions, but that is not
a guarantee of macOS 27's new app-data permission behavior. Do not mark this
as a proven persistence fix until granting access once and testing both an
app relaunch and a differently built app signed with that same certificate.

Use that certificate through `VIBEBAR_CODESIGN_IDENTITY` on **every** local
build. Installing an ad-hoc-signed upstream update changes identity again.
Self-signing is not Developer ID notarization and does not remove Gatekeeper
requirements. Preserve the certificate/private key securely; never commit
it, disable system protections, or substitute an identifier-only designated
requirement that other signers could impersonate.

## Automatic cookie recovery

When the existing automatic browser-cookie recovery setting is enabled,
failed cookie-backed misc-provider slots trigger one silent browser re-read
on every refresh. The shared importer no longer imposes a six-hour retry
cooldown, and failures are not limited to login errors. Changed headers are
retried once; unchanged headers do not spend another network request. An
empty saved-cookie list gets one recovery attempt before reporting missing
credentials. Recovery honors the selected browsers, source mode and adapter
session filter. Pasted cookies remain user-owned, and Keychain denial gates
still prevent repeated prompts. A failed recovery does not recurse.

The overview's Automation check uses
[AEDeterminePermissionToAutomateTarget](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomatet)
with `askUserIfNeeded: false`, and only for an already-running terminal app.
Login item state comes from
[SMAppService.status](https://developer.apple.com/documentation/servicemanagement/smappservice).
Keychain checks request metadata only, never password data. Each result is
labelled accordingly rather than treating metadata visibility as permission
to decrypt a browser cookie store.

## Studio and Overview changes in this update

The Studio uses one rounded selection outline for popover cards, preset mini
cells, free-canvas elements and menu-bar groups. Popover navigation is live;
choosing an editable tab also changes the Studio's active page. Tabs without a
module layout can be previewed without leaving editing controls pointed at a
hidden page.

Double-click a preset mini label or a free-canvas text element to edit it in
place. Return commits, Escape cancels. Preset mini labels use the existing
per-mode label overrides; custom text and component labels stay in the canvas
layout. Free placement adds nearby edge/center snapping, visible alignment
guides and animated grid snapping. The custom palette includes the seven
built-in mini renderers (regular ring, compact bar, ledger, strip, tile, focus,
rail), alongside the five basic elements.

Overview offers Company (default), SubProvider and Model group card boundaries.
The default keeps the original company module identities. Finer cards reuse the
original bucket rows and keep their quota, forecast, reset and freshness data;
Daily/Weekly windows of a model remain together. Grok Bot stays separate from
Cursor. A model heading immediately following a SubProvider header has no
leading divider; later groups retain their separators.
