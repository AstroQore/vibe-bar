# Notch Island — Design Proposal

Status: **proposal, not scheduled**. Nothing in this document is
implemented. It exists so the idea can be evaluated and, if accepted,
built in phases without re-deriving the constraints.

## Motivation

The menu bar is out of room. Every status item on a notched MacBook
competes for the strip between the notch and the right edge; macOS hides
whatever does not fit behind the notch, and Control Center's per-app
allow-list (see AGENTS.md § 11 and `MenuBarBlockWatchdog`) can hide items
for reasons that have nothing to do with width. AQ wants to show more
quota at a glance than one status item can carry, without opening the
popover or keeping the mini window on screen.

[open-vibe-island](https://github.com/Octane0411/open-vibe-island) shows
a native answer: a borderless, non-activating `NSPanel` pinned to the
notch, drawn as a black surface that visually merges with the notch,
with "wings" flanking it that hold live content, and a hover/click
expansion into a larger panel below. This proposal adapts that shape to
Vibe Bar's data and design language.

## Goals

- Show a configurable set of quota gauges (the same catalog the mini
  window and the menu bar draw from) next to the notch, always visible,
  without consuming status-item space.
- Coexist with the existing status item and popover; nothing here
  replaces them.
- Expand on hover/click into a richer surface (the mini window's
  three-tier strip: company → SubProvider → gauges), and collapse when
  the pointer leaves.
- Configurable: on/off, which display(s), which fields, wing width,
  hover delay, pinned/unpinned.

## Non-goals

- Agent hooks, permission approvals, "jump back to terminal" — that is
  open-vibe-island's product, not Vibe Bar's.
- Replacing the mini window. The mini window is a movable, resizable
  panel the user positions; the island is fixed to the notch.
- Any change to quota / usage semantics. The island is a fourth surface
  over the same data.

## Where it sits: three options considered

### A. On the notch, wings left and right (recommended)

A single panel centred on the notch, `leftWing + notchWidth + rightWing`
wide and exactly `safeAreaInsets.top` tall in the closed state. The
middle is opaque black and disappears against the physical notch; each
wing draws a few compact ring gauges. It uses space that is *already*
unusable by the menu bar (the notch itself) plus a small, fixed strip on
one or both sides.

Which side matters. The **right** of the notch is where macOS packs
status items, and in the very overflow scenario that motivates this
feature they run right up to the notch — an opaque right wing would
paint over them (`ignoresMouseEvents` only passes clicks through, it
does not stop the wing from covering the item). The **left** of the
notch is the frontmost app's menu-title band, which for most apps ends
well short of the notch. So the defaults are `leftWing = 88`,
`rightWing = 0`; the right wing is opt-in for people whose status-item
strip is short. The controller additionally shrinks or hides a wing
when it can see that the band is occupied: for the right side by
measuring our own status item's frame (`NSStatusItem.button.window`),
for the left side — where the frontmost app's menu extent is not
observable without the Accessibility API — by keeping the default
width conservative and letting the user set it.

- Pros: does not touch the status-item strip by default; wing width is
  deterministic; looks intentional on a notched Mac; the same panel
  expands downward.
- Cons: the left wing can still overlap an unusually long app menu bar;
  that is a user-visible setting, not a hidden heuristic. On a
  non-notched external display there is nothing to hide behind —
  open-vibe-island falls back to a top-centre pill (a fake notch),
  which is a taste decision. Default here: **disabled on non-notched
  displays**, with an opt-in "top-centre pill" mode.

### B. Left of the notch only, in the app-menu gap

Occupy the empty part of the menu-bar band between the frontmost app's
last menu title and the notch. This is what AQ described.

- Pros: does not touch the notch's centre; on a wide-menu app the gap is
  still usually 100–300pt.
- Cons: the frontmost app owns that band. Menu titles vary per app and
  per localisation, so the island would have to measure the app's menu
  extent through the Accessibility API (`AXMenuBar` of the frontmost
  process) and shrink or hide when it would overlap. That is a live,
  per-app-switch measurement, it needs Accessibility permission, and it
  is exactly the fragile category of code this repo tries to avoid.
  Clicking a title that the island covers would be a real regression.

Verdict: **B is feasible but not worth its fragility.** Option A gets the
"more room" outcome with a fixed geometry, and its default
(`rightWing = 0`) *is* the left-of-notch layout AQ described — the
difference is that A anchors on the notch and treats the sides as
configuration rather than measuring another app's menu bar.

### C. A second status item / a wider status item

Rejected: the same overflow problem, and macOS 26 already hides items it
cannot fit.

## Architecture (Option A)

New App-layer pieces; no Core changes beyond a settings struct.

```
Sources/VibeBarApp/
  NotchIslandController.swift      // NSPanel lifecycle, screen tracking, hover/click state
  NotchGeometry.swift               // pure: notch rect, wing rects, closed/opened frames
  Views/NotchIslandView.swift       // SwiftUI content: closed wings + opened strip
Sources/VibeBarCore/Models/
  NotchIslandSettings.swift         // Codable settings, part of AppSettings
```

### Panel

Same recipe as open-vibe-island's `OverlayPanelController`, which is
also close to `MiniQuotaWindowController.makePanel`:

- `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`,
  `isFloatingPanel = true`, `level = .statusBar`, `hidesOnDeactivate =
  false`, `hasShadow = false`, `backgroundColor = .clear`.
- `collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces,
  .ignoresCycle, .stationary]` — `.stationary` keeps it pinned during
  Mission Control / "click wallpaper to reveal desktop".
- The panel is created at its **opened** size and not resized during
  hover/expand transitions; closed vs opened is a SwiftUI state inside
  a fixed frame, which avoids AppKit resize flicker and keeps
  hit-testing simple. The frame *is* recomputed (and the panel rebuilt
  if needed) whenever a sizing input changes: wing widths, the selected
  fields, density, the target screen's parameters.
- The opened width is clamped to the target screen's `visibleFrame`
  width minus a margin (the same rule `MiniQuotaWindowController`
  applies); past that the strip compresses to the compact density and
  then truncates trailing fields with a "+N" marker rather than
  running off-screen.
- Pointer handling: while closed, `ignoresMouseEvents = true` for the
  notch/black region so the menu bar under it keeps working, but the
  visible **wing** rects are hit-testable (an `NSView` subclass that
  returns itself only inside the wing rects), so a click on a gauge
  opens/pins immediately without waiting for the hover delay and never
  reaches an underlying control. Hover detection uses **both** a
  global `NSEvent` monitor (events delivered to other apps) and a
  local monitor plus tracking areas (events delivered to Vibe Bar,
  e.g. when it is frontmost or the pointer came from our status item);
  the timer starts on either.
- One panel per eligible screen; screens re-evaluated on
  `NSApplication.didChangeScreenParametersNotification`.

### Geometry (`NotchGeometry`, pure and unit-tested)

```
notchHeight = screen.safeAreaInsets.top                  // 0 on non-notched displays
notchWidth  = screen.frame.width
            - (screen.auxiliaryTopLeftArea?.width  ?? 0)
            - (screen.auxiliaryTopRightArea?.width ?? 0)
closedRect  = x from midX − notchWidth/2 − leftWing, width leftWing + notchWidth + rightWing, height notchHeight
openedRect  = same notch centre, width min(max(closedWidth, contentWidth), visibleFrame.width − 32), height notchHeight + stripHeight
```

`leftWing` defaults to 88pt (room for two compact rings), `rightWing`
to 0; both configurable. On `notchHeight == 0` the island is off unless the
"top-centre pill" fallback is enabled, in which case a 38pt-tall,
190pt-wide fake notch is drawn (open-vibe-island's numbers).

### Content

- **Closed**: each wing renders up to N `RingGauge`s (the mini window's
  gauge, at the compact density) for the fields chosen in settings, with
  a 1–2 character short label under each. Colour = the same
  `Theme.barColor(percent:mode:)` used everywhere.
- **Opened**: the mini window's strip content — company header →
  SubProvider row → gauges — rendered inside the island's black surface.
  This is the *same view* the mini window uses (`MiniQuotaWindowView`'s
  body extracted into a `MiniQuotaStrip` that takes a `density` and a
  `surface` style), so a fix in one place fixes both.
- Hover delay 350 ms (configurable), close on pointer exit after 250 ms,
  click toggles "pinned" (stays open until clicked again or Esc).
- Transient states (optional, later): when a bucket hits "out" the
  island can pop for a few seconds even when unhovered — the same
  signal the status item colours today.

### Data

No new data path. The island observes the same `QuotaService`,
`AppSettings`, and field catalog (`MenuBarFieldCatalog`) as the mini
window; it adds one more *selection* of fields (`islandFields`), edited
in the same Settings section as menu-bar and mini-window fields.
Timers: none of its own — it re-renders on the publishers it already
observes; the ring pace animation uses the mini window's existing
timeline scoped to visibility (AGENTS.md § 11: no periodic
`TimelineView` in eagerly-instantiated trees).

## Coexistence with the menu bar

- The status item stays. With the island on, the status item can be set
  to icon-only (there is already a "compact" style) so it takes minimal
  width; the island carries the gauges.
- The island is not a status item, so Control Center's allow-list, the
  `MenuBarBlockWatchdog`, and menu-bar overflow do not apply to it.
- Full-screen apps: `.fullScreenAuxiliary` keeps it available over
  full-screen spaces where the menu bar auto-hides; a setting can hide
  it there instead (some users will not want a black bar over a
  full-screen video).
- Menu bar auto-hide (System Settings): the panel is positioned from
  `screen.frame`, not `visibleFrame`, so it stays at the top edge
  regardless.

## Settings surface

`NotchIslandSettings` in `AppSettings`:

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | master switch |
| `displays` | `.builtInNotchedOnly` | `.builtInNotchedOnly` / `.allNotched` / `.allDisplays` (fake-notch fallback) |
| `leftWingWidth` | `88` | pt, 0 allowed |
| `rightWingWidth` | `0` | pt; off by default because status items live there |
| `hoverDelayMilliseconds` | `350` | |
| `hideOverFullScreen` | `false` | |
| `hiddenFromScreenSharing` | `false` | when `true`, `panel.sharingType = .none` (excluded from capture); `.readOnly` is not exclusion |
| `fields` | mirrors `miniWindowFields` | field ids from `MenuBarFieldCatalog` |

Edited in Settings → a new "Notch Island" section next to the menu-bar
and mini-window field editors, reusing `MiniWindowFieldProviderSection`.

## Design language

`docs/DESIGN.md` gets a second, narrow exception next to the mini
window's Liquid Glass: the island's surface is **opaque near-black**
(it must merge with the physical notch), with the same flat gauges and
type as the mini window drawn on top. No glass, no shadow, no gradient.
Corner radius follows the notch's bottom corners.

## Risks and open questions

- **Multiple displays.** Which screen "has" the island when the
  built-in display is closed (clamshell)? Default: none, unless
  `.allNotched`/`.allDisplays`.
- **Stage Manager / Sonoma desktop reveal.** `.stationary` covers the
  known cases; needs a manual pass.
- **Screen sharing.** open-vibe-island hides its panel from capture by
  default; for a quota widget that is probably surprising in a demo
  recording. Default visible; opt-in hide.
- **Accessibility.** The island is pointer-only. The status item /
  popover remains the keyboard-reachable path, so nothing regresses;
  the island's gauges should still expose accessibility labels.
- **CPU.** One extra SwiftUI host per screen. Content must not
  re-render on a 1 s timer when closed; pace animation only when opened.
- **macOS 26 behaviour drift.** `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea` are documented API since macOS 12; the
  Sonoma+ desktop-reveal interaction is what `.stationary` exists for.
  Keep the geometry pure so it can be re-tested against new OS builds.

## Phased plan

1. **Spike (1 PR, behind `enabled = false`).** `NotchGeometry` + tests,
   `NotchIslandController` with the panel recipe above, closed wings
   showing two hard-coded fields, hover-open into the existing mini
   strip. Goal: prove geometry, hit-testing, and full-screen behaviour
   on AQ's MacBook.
2. **Settings + field catalog.** `NotchIslandSettings`, Settings
   section, `islandFields`, per-display selection, status-item compact
   mode when enabled.
3. **Polish.** Open/close animation, pin/Esc, optional "out of quota"
   pop, fake-notch fallback for external displays, DESIGN.md addition.

Rough size: phase 1 ≈ 400 LOC + tests; phase 2 ≈ 250 LOC; phase 3
≈ 200 LOC.

## Decision needed from AQ

- Option A (on-notch with wings) vs a strict left-of-notch strip (B).
  This proposal recommends A and treats B as `wingWidth(right) = 0`.
- Whether to build the phase-1 spike now or park it.
