# DESIGN.md — Vibe Bar's visual language

One app, three surfaces, one card. This file is the spec; the code is
`Theme.swift`, `CardShell.swift`, and `WorkbenchPorcelainStyle.swift`.
If a change makes one surface look like a different application, it is
wrong even when it looks good on its own.

`design-qa.md` at the repo root is a historical QA log from the
Workbench redesign, not a spec. This file supersedes it.

## 1. The surfaces

| Surface | Owner | Shell |
| --- | --- | --- |
| Menu-bar popover | `Views/PopoverRoot.swift` | AppKit popover, system chrome |
| Mini floating window | `Views/MiniQuotaWindowView.swift` | Borderless panel with **Liquid Glass** |
| Workbench window | `Views/Workbench/WorkbenchRootView.swift` | 1180×820 `NSWindow`, sidebar + header + page |

They differ in *size and density*, never in material. A quota card in
the popover and the same quota card in the Workbench are the same
object seen at two magnifications.

## 2. The flat language

**Cards are flat.** A card is a continuous rounded rectangle with:

- fill `.background.tertiary` at `Theme.Card.fillOpacity` (0.6)
- stroke `.separator` at `Theme.Card.strokeOpacity` (0.4)
- stroke weight `Theme.Card.hairlineWidth` (0.5pt — one device pixel at 2x)
- **no drop shadow, no material, no gradient**

**Density, not material, separates the surfaces.** `Theme.Density`
carries padding, spacing, radii and type sizes for `compact` / `regular`
/ `spacious`. The Workbench opts into the same recipe with larger
metrics through `workbenchPorcelain()`, which floors card padding and
corner radius at `Theme.Card.workbenchMin*` (16). That floor is the
whole difference.

**Chrome is fill plus hairline.** Sidebar rows, toolbars, fields, pills
and selection states use a `WorkbenchPorcelain` fill and the same
hairline. Selection is a fill change, never elevation.

**Nothing floats by casting a shadow.** Content that genuinely sits over
other content — a chart tooltip, a toast, a loading pill — uses
`workbenchOverlaySurface(in:)`, which is opaque. Opacity is how a flat
design says "on top".

**Type scale.** Page header 22pt bold (`tracking -0.35`) with an 11.5pt
secondary subtitle; card titles from `density.titleFontSize`
(14/16/18); section captions 12pt semibold secondary; body and rows
13pt; captions 11–11.5pt; metadata 10–10.5pt tertiary. Numbers that
change over time are `.monospacedDigit()` so a refresh does not shift
the layout.

**Colour comes from one table.** Provider hues are
`Theme.providerAccent(for:)` and quota state colours are
`Theme.barColor(percent:mode:)`. Never hardcode a provider colour at a
call site: a provider that is teal in the mini window and green in a
chart is two providers as far as the reader is concerned.

**Gradients live inside data-viz only.** Chart area fills
(`UsageTrendChartView.areaGradient`, `CostHistoryView`) may use a
gradient because it encodes magnitude. Backgrounds, cards, sidebars and
buttons may not.

## 3. The two exceptions: floating surfaces over content

`MiniQuotaWindowView` wraps its content in
`.glassEffect(.regular.interactive(), in: .rect(cornerRadius:
Theme.miniCornerRadius))`. This is the platform's own Liquid Glass on a
borderless always-on-top panel — the outer *surface* of a floating
window, which is exactly what the effect is for. Its **content** is
flat like everywhere else.

The Layout Studio (`LayoutStudioView`) is the second, for the same
reason. Its stage shows a real popover page or mini window, and its
chrome — the subject menu, the mode and zoom pills, the hide well, the
tray, the hint, the inspector — floats *over* that surface rather than
sitting in a page beside it. Glass and material are what let the chrome
sit on top of live content without hiding it, which is the mini window's
situation again. The studio's own content is flat: the surface on the
stage draws exactly as it does in production, and the tray's chips are
the flat pill recipe.

Do not remove either, do not copy them. No other view in the app may
call `.glassEffect` or use `.regularMaterial` / `.ultraThinMaterial`. If
you find one, it is a regression.

## 4. Where the tokens live

| File | Owns |
| --- | --- |
| `Views/Theme.swift` | `Theme.Card` (the card recipe), `Theme.Density` profiles, provider accents, quota bar colours, mini-window metrics |
| `Views/CardShell.swift` | `CardShell`, `cardSurface(density:)`, `SettingsSectionCard` — the only places the card recipe is composed |
| `Views/Workbench/WorkbenchPorcelainStyle.swift` | Workbench window chrome: ground, sidebar, toolbar, field, overlay, selection, hover, hairline, accent; `WorkbenchPillButtonStyle`; the `workbenchPorcelain()` density opt-in |

The `WorkbenchPorcelain` name is historical — it once meant a
soft-shadowed "porcelain" direction. It is now just the Workbench's
chrome namespace, and it deliberately owns no card tokens.

## 5. How to add a card

```swift
CardShell(density: density) {
    Text("Section title")
        .font(.system(size: density.titleFontSize, weight: .semibold))
    // rows…
}
```

That is the whole recipe. Then:

- Take `density` from the caller; never resolve a `Theme.Density`
  inside a leaf view, and never hardcode padding or corner radius.
- Space siblings with `density.interSectionSpacing`, and inset a page
  with `density.popoverPaddingH` / `popoverPaddingV`.
- Use `cardSurface(density:)` instead when the card already owns its
  internal layout (a centred empty state, a pinned-height summary).
- In Settings, use `SettingsSectionCard(title:density:)` — it is
  `CardShell` with the page's caption above it.
- Do not add `.shadow`, `.glassEffect`, or a material. Do not draw a
  second surface under a view the caller already wrapped in a card.

## 6. Review checklist

- `grep -rln "glassEffect\|regularMaterial\|ultraThinMaterial" Sources/`
  returns exactly two files: `MiniQuotaWindowView` and
  `LayoutStudioView` (§ 3).
- `grep -rn "\.shadow(" Sources/VibeBarApp/Views/` returns only
  data-viz marks (`PaceMarkerCapsule`), drag affordances
  (`LayoutEditorView`, `LayoutStudioView`'s drag image) and the
  studio's lit stage, never a card.
- No *new* card draws its own `RoundedRectangle` background and stroke.
  Small chrome (a 6pt status chip, a 7pt selection row) may still carry
  its own radius; a card may not.
