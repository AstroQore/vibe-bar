# Custom Mini Window

Choose **Custom** in Settings → Mini Windows, then **Open Studio**. The
inspector opens alongside the same Liquid Glass panel used on the desktop.

The two editing modes are **Snap to grid** (default) and **Free layout**.
Grid mode aligns insertion, movement and resizing to the same visible cells.
Set the board's column and row counts, and each element's cell span, directly;
the pictured spans are shortcuts rather than a fixed list. Free mode preserves
arbitrary coordinates and dimensions. Clicking the palette fills an empty
area; dragging onto another element allows text and gauges to overlap.

Add a ring, horizontal bar, vertical bar, sector or text by clicking the
palette or dragging it onto the canvas. Bind each element to a quota using
the full SubProvider and bucket label. Text can show a percentage, quota
label, reset countdown or custom text. Text is a separate element, so it can
sit inside a gauge, beside a bar or anywhere else on the canvas.

Drag an element to move it; drag its bottom-right handle to resize it.
Shift-click selects several elements, Command-G groups them, Command-D
duplicates them and Delete removes them. Groups preserve their relative
positions when they reach an edge. The inspector also provides dimensions,
font size, ring stroke width, quota/provider/custom colours and layer order.
Command-Z restores the previous layout, including inspector edits.

Layouts are stored under the top-level `miniCanvasLayouts` settings key,
indexed by window UUID, separately from the legacy `miniWindow` roster.
An older client saving that roster therefore preserves the free layout.
Older clients may fall back to Regular for the unknown Custom display mode;
selecting Custom again restores the saved canvas. Switching styles never
deletes a canvas. A default double-click cycle includes only the built-in
styles; Custom can be explicitly added to the cycle.

Canvas dimensions are independent of the panel's screen position. Position
remains in `mini_window_geometry.json`. A drag previews locally and writes
settings only on release. Missing or percentage-less quota data draws an
empty track and a dash, never a fabricated zero or full allowance.
