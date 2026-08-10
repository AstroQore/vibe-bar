# Workbench Porcelain design QA

## Scope

- Source: the supplied Workbench Porcelain design render from `UI界面重新设计.zip`.
- Implementation: the native SwiftUI Workbench at a 1500 × 1100 content size.
- States checked: Usage light, Usage dark, Models table, and embedded Settings.
- Dynamic values are expected to differ because the implementation renders the live local ledger; hierarchy, component geometry, chart semantics, and data relationships were compared.

## Comparison history

### Pass 1

- P1 — the breakdown surface still used AppKit's default `Table`, leaving a large empty pane, system chrome, and a clipped trailing `Avg/req` column.
- P2 — duplicated status/refresh controls weakened the filter toolbar hierarchy.
- P2 — the token legend could truncate at the regular Workbench width.
- P2 — a default focus halo appeared on the Settings appearance button.

Fixes: replaced all four tables with compact self-drawn grids and hover rows; made their height follow real content; aligned headers and rows to the same inset; removed duplicate controls; rebalanced hero widths; disabled only the default focus effect while retaining the semantic button.

### Pass 2

- P1 — the token chart used overlapping provider areas while the source and hero card describe input, output, cache-write, and cache-read composition.
- P2 — sparse daily bars were optically too narrow.

Fixes: changed Tokens to an exact token-component stacked bar chart backed by the same filtered ledger points as the hero and Periods table; kept Cost as provider series; retained navigator, window navigation, hover, and Auto/Hourly/Daily/Weekly controls; sized bars from the visible bucket count.

### Final pass

- Layout: sidebar, fixed page header/filter toolbar, merged hero, chart/provider pair, and compact table follow the source hierarchy without clipping or overlap.
- Typography and surfaces: native system typography, restrained hairlines, 16 pt cards, small uppercase table headers, monospaced numeric columns, and light/dark semantic fills are coherent.
- Color: token colors agree across hero, chart, and tooltip; provider colors agree across filters, cost series, and provider mix. Grok uses an adaptive neutral that remains legible in dark mode.
- Interaction: provider/model/range filters, Tokens/Cost, granularity, window navigation, brush navigator, tabs, row hover, refresh, appearance toggle, and Settings subnavigation remain functional.
- Accessibility: semantic buttons and labels remain, selected states are exposed, reduced-motion behavior is retained, and no required value is encoded only by color.
- Settings: the old independent window is replaced by a secondary Workbench destination with its existing nested navigation and controls.
- Mini window: no Mini Window source is changed; the final product follows the system appearance unless the user explicitly toggles the Workbench-only appearance button.

No P0, P1, or P2 visual findings remain in the final light/dark comparison.

final result: passed
