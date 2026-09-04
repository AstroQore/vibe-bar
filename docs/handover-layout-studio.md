# Handover — Layout Studio

Status: **shipped but unfinished.** It works and is reachable; the design is
one pass in, not done. Written down rather than polished further because AQ
called time on it — pick it up from here.

## What it is

Two settings panes arrange a surface you cannot see while arranging it:
Mini Windows and Layout (the popover's module columns). The split we settled
on:

- **Inline stays a skeleton.** A settings pane's width belongs to its
  controls, and a skeleton shows the thing those controls edit — how many
  fields, how they fold, in what order. Layout already had one; Mini Windows
  now does.
- **The real surface moves to its own window.** `LayoutStudioWindowController`
  opens a translucent window with the surface on a lit stage and the controls
  beside it. The proportions invert on purpose: in Settings the controls own
  the room, here the surface does.

Both panes reach it through `LayoutStudioButton`; inside the studio that
button hides itself via `EnvironmentValues.isInLayoutStudio`.

## Where the code is

| Piece | File |
|---|---|
| Window, translucency, `Subject` | `Sources/VibeBarApp/Controllers/LayoutStudioWindowController.swift` |
| Stage, toolbar, inspector | `Sources/VibeBarApp/Views/LayoutStudioView.swift` |
| Natural-size measure + scale, studio button, environment flag | `Sources/VibeBarApp/Views/ScaledPreview.swift` |
| Mini Windows skeleton + door | `Sources/VibeBarApp/Views/MiniWindowsSettingsSection.swift` (`windowSkeleton`) |
| Layout skeleton + door | `Sources/VibeBarApp/Views/LayoutEditorView.swift` (`previewColumnStack`) |

Two constraints worth not rediscovering:

- **Neither surface can be sized with `.frame(width:)`.** A mini window lays
  out at its panel's width and a popover at a window's; a narrower frame does
  not narrow them, it makes them spill over whatever is beside them. That is
  what `ScaledPreview` exists for — measure at natural size, then scale.
- **`PopoverRoot` applies `initialPage` once**, to state it owns. The stage
  gives it `.id(tab)` so switching subjects rebuilds it; without that the
  preview stays on the page it opened with.

## What works

Driven in the built app, both subjects: the window opens from either pane,
the surface renders live on the stage, the subject chips switch between the
five popover pages and every mini window, Fit/Actual size changes the scale,
and the inspector hosts the same editors Settings shows — so a control's
behaviour is still defined in one place.

## What is left

Roughly in the order that would matter:

1. **The stage is only ever top-left.** A short surface floats in a large
   empty stage. It should centre, and probably grow the shadow with the zoom.
2. **`Actual size` is a magic 10 000.** `ScaledPreview` caps its scale at 1×,
   so passing an absurd width means "never shrink". It works and it reads
   badly; give `ScaledPreview` an explicit mode instead.
3. **No zoom between fit and 1×.** A slider, or ⌘+/⌘−, and a percentage
   readout.
4. **Motion is only on the container.** The subject chip has a
   `matchedGeometryEffect` and the panes cross-fade, but the surface itself
   does not animate when the arrangement under it changes — which is the one
   moment where motion would actually explain something.
5. **The inspector is Settings' pane at a different width**, not a layout
   designed for this room. In particular the Mini Windows editor still shows
   its own skeleton inside the studio, next to the full-size stage showing the
   same thing.
6. **Nothing restores the last subject.** The window always opens on whatever
   pane sent you, and the model resets per launch.
7. **No keyboard.** Escape should close, ⌘W too, and the subject chips should
   be arrow-navigable.
8. **Untested at small window sizes** and never looked at in Light Aqua — the
   gradient backdrop was tuned against Dark.
9. **The mini-window stage measures the view, not the panel.**
   `MiniQuotaWindowController.stableContentSize` adds a 20/24-point reserve for
   the close button and can clamp to the screen; the stage measures
   `MiniQuotaWindowView`'s intrinsic size alone, so a many-field window is
   spaced slightly differently here than on screen. Reuse that sizing.

## Design intent, so a second pass does not undo the first

The window is translucent (`underWindowBackground`, `isOpaque = false`) and
the chrome is `.ultraThinMaterial`, so the stage reads as lit and everything
else recedes. The surface keeps its own corners and gets a shadow rather than
a frame — it is the real thing on a stage, not a picture in a border. Colour
belongs to the surface; the studio itself is greys and one accent.
