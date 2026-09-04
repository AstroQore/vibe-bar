# Layout Studio — status and handover

Status: **shipped as the direct-manipulation editor** (this branch). The
first pass (#336) put the real surface on a stage beside a copy of the
Settings controls; this pass made the stage the editor. What is below is
what a second pair of hands needs to know, and what is still open.

## What it is

One window, `LayoutStudioWindowController`, for two subjects: a popover
page (`PageLayoutPageID`) or a mini window (`UUID`). The surface renders
exactly as in production, scaled on a lit stage; arranging it means
dragging its cards or cells where they are.

- **Drag on the surface.** Press on a card or cell, move 4 pt, and it lifts
  as a picture of its own pixels (`LayoutStudioWindowController.snapshot`);
  a dimmed placeholder stays in layout and the others make room live. Drop
  writes once; Esc cancels.
- **Well and tray.** While dragging from the surface, a well appears under
  the stage: hide a card / remove a field. Hidden cards and not-shown
  fields sit in a tray as chips — click to restore in place, drag onto the
  surface to place.
- **Chrome.** Glass pills over the stage (a deliberate second exception in
  `docs/DESIGN.md` § 3): subject menu, mode + width split (or the seven
  mini styles), zoom (−/%/+, ⌘0 fit), undo, inspector toggle. The full
  Settings editors slide in as the inspector.
- **Keys.** Esc, ⌘W, ⌘+/⌘−/⌘0, ⌘Z, ←/→ or ⌘[/⌘], ⌥⌘I — an `NSEvent` local
  monitor in the controller, text fields exempt.
- **Undo.** Every write to the subject's saved state is one step, recorded
  by watching the state (`savedState`), so inspector edits and stage
  edits undo in order. Cleared when the window closes.

## How the real surface takes part (`SurfaceItems.swift`)

- `surfaceItem(_:)` tags every arrangeable card or cell. Inert in
  production; under the studio it reports the item's frame into
  `SurfaceItemFrames` in the surface's own unscaled coordinates
  (`SurfaceCoordinates.space`, set inside `ScaledPreview` before the
  scale). **Tag any new card or cell render site**, or the studio cannot
  pick it up. Focus and Rail mini styles are untagged on purpose.
- `studioPageOverride` / `studioMiniOrderOverride` hand the surface the
  arrangement a drag proposes. For an Auto Overview the override asks for
  the resolved arrangement through the fixed-column path from the moment
  the studio opens, so a drag never switches layouts under the pointer.
- `liftedSurfaceItem` dims the placeholder.
- `PageLayoutColumns` draws both columns in one `PageColumnsLayout`, so a
  card crossing columns travels instead of being rebuilt.
- The drop geometry — `StudioArranging` in Core — uses midpoint rules,
  which stay stable while the reflow animation is still moving frames.
- A drag on an Auto/Compact page lands it in Manual in one write
  (`PageLayoutModel.applyStudioArrangement`).

Two constraints from the first pass still hold: neither surface can be
sized with `.frame(width:)` (measure, then scale), and `PopoverRoot`
applies `initialPage` once, so the stage gives it `.id(tab)`.

## Verified

Driven in the built app on the Overview: open from Settings, the pills,
zoom, subject switching, the hint, hover outline and cursor; a card lifts
and drops. The bot-review threads on #337 were each verified or answered.
Still to drive by hand before a Main release: cross-column drops on a
tall page (auto-scroll), the well, tray drag-in, every mini style's cells,
Esc mid-drag, Light Aqua.

## Open ideas, roughly in order

1. Rename a mini cell or a card's label by double-click on the stage (the
   inspector does it today).
2. Remember the last subject and zoom across openings.
3. Arrow keys inside the subject menu; VoiceOver labels for the pills.
4. The drag image is a bitmap of the card at the current zoom; at 200 %
   it is soft. Snapshot at 2× and downscale.
5. A `DragGesture` in the App target is untested; the geometry is. If the
   state machine grows, move it into a testable type.
