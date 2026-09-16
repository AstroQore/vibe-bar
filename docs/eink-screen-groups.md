# E-ink devices and screen groups

Settings has two separate destinations:

- **E-ink Displays**: fetch devices and configure standalone screens. Every
  screen has its own enable switch and expandable settings, stacked in the
  page. Enabling a screen expands its existing controls and slide editor.
- **Screen groups**: select two or more available screens to create a group.
  Group members leave the standalone settings list, even while their group
  is disabled. Ungrouping restores their original standalone configurations.

A group owns one set of playback, refresh, alert, tap-link and quiet-hours
settings. Its enable switch controls the group. Per-screen orientation and
placement remain available on the visual arrangement canvas. Drag screens to
align and snap their edges; precise pixel coordinates stay in a disclosure.

## The same slides on one screen or several

Creating a group offers three starting arrangements, usable with any number
of selected screens: a separate page per screen, one page across the whole
group, or the first pair combined with the remaining screens independent.
Existing device slides are carried into the group. Adding another screen
also adds its content to the group's slides.

Groups use the same slide editor, presets, field selection, labels, header,
footer and Studio as standalone devices. Merge a slide with another screen's
slide, or split a combined slide back into independent copies. Merging
collects their quota selections and uses the first slide's layout; custom
arrangements can be edited on the combined canvas. Ungrouping preserves the
original device slides, not the group's later composition edits.

Both a device and a group can play one selected slide or rotate through
several. A group always uses the Mac to coordinate its screens. There is no
separate timeline editor.

## Select content without a five-item ceiling

Choose content opens a searchable, bounded picker with named quota rows.
Selections are not truncated when changing a preset or rotating a screen.
Quota presets adapt to the combined canvas size and orientation, and slides
automatically continue onto more pages when content does not fit. Capacity is measured from what the renderer actually draws, including
long names and label styles; a nominal five-slot layout that can only draw
three selected names carries the remaining names onto subsequent pages.

The page arrows preview every derived page. A single logical slide can have
several pages; they turn using the same seconds-per-slide setting. In a group,
regions turn together and shorter content holds its last page until the
longer content has finished. Before editing paginated content in Studio, an explicit action turns every
page into an independent slide and opens the selected page. All selections
remain in the same slide list; single-slide or carousel playback remains a
user choice. Custom freeform content uses its element bindings, as before;
it does not expose a conflicting preset content selector.

Alerts join the same gallery as one temporary card, disappearing when the
condition clears. A device-loop carousel with insufficient tasks temporarily
uses Mac-driven playback and mirrors the current card into all existing loop
tasks so the firmware does not insert unused placeholders.

## Device and storage boundaries

Grouped playback requires a running Mac and one Canvas API item in each
panel's LOOP task. Requests are paced per device; physical refresh completion
is not simultaneous. A partially failed group page remains pending for retry.
Each outgoing payload still obeys the device's element and size limits.

Group membership and slides remain under the existing `einkSync` settings
key. The legacy `frames` field is retained on disk for compatibility; it is
presented as slides in the UI. Existing Dev 84 groups continue to decode.
Custom layouts remain in `einkCanvasLayouts`, and credentials stay in the
credential vault. No group or page stores an API key.
