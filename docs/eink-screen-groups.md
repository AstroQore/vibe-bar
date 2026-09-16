# E-ink screen groups

In Settings → E-ink Displays → Screen groups, create a group and select its
screens. Drag the screen cards on the dotted canvas; alignment guides and
edge snapping make adjacent screens meet exactly. An overlapping drop settles
against the nearest free edge. The toolbar can stack or align screens, and
Precise adjustment exposes the selected screen's numeric pixel position. Positions use the upright image;
a rotated Quote/0 occupies 152 × 296 pixels. Two landscape screens stacked
vertically make a 296 × 304 canvas. Screen rectangles cannot overlap, and
combined canvases are limited to 4096 × 4096 pixels.

Add frames to the shared timeline. Each frame starts with a separate page for
each screen. Choose a preset or copy an existing page, then edit it in the
combined-page editor. To span screens, remove the other region and select
both screens for the remaining region. With three or more screens, the same
frame can combine a spanning page with separate pages. Screens without a
region show a blank page. Frames can be reordered and removed.

The combined-page editor uses the existing pixel canvas, live data bindings,
modules, and inspector at the region's full size. Saving creates a separate
layout owned by that region; it does not resize the page copied from a
standalone screen. Moving screens changes the canvas around the authored
content; it does not automatically scale font sizes.

Enable the group and every member screen, then enable the main sync switch.
Group timing replaces the member screens' individual playback and data
refresh controls. Any member's Push now updates the entire group. A group
uses one data snapshot and one frame index, validates every panel before
sending, and retries a partially failed frame before advancing. Battery
cadence applies to the whole group if any member reports battery power.

**Use one Canvas API item in each device's LOOP task for Mac-driven grouped
playback.** Remove other loop tasks in the Dot. app: the API cannot remove
them or control the firmware's own rotation. Requests are paced and sent to
individual devices, so shared scheduling does not guarantee simultaneous
physical refresh completion. A failed request can leave a temporarily mixed
picture until the pending frame succeeds. The Mac must remain running.

Alerts add a temporary gallery card. Two authored pages become three while
an alert stands, then return to two when it clears. A single-page display
alternates its selected page with the alert. Device-driven playback uses a
spare Canvas task when available; otherwise it temporarily uses the Mac
carousel. In a group, the alert is one extra shared frame, and only screens
watching an offending bucket show it.

The feature does not change the credential or privacy boundary: every write
still goes through EInkSyncService and DotDeviceClient, and group settings
contain no key. Group geometry, timeline and page choices live under the
existing einkSync settings key; custom layouts remain in einkCanvasLayouts.
