# E-ink device groups

Two or more panels can be run as a single display. A group is a display like
any other: it lives in the same list, wears the same chrome, has the same two
cards inside, and is configured with the same controls. The only things it
adds are where its screens hang and, per page, whether they draw one template
or one each.

## One destination, one roster

Settings › **E-ink Displays** is the whole feature. Under the access card
(API key, sync switch, fetch devices) is one expandable panel per display,
where a display is either a screen on its own or a group. A group sits where
its first member sat, names its members under its own name, and its members do
not appear separately — they are part of one display now. **Group screens…**
above the list makes one from two or more screens that are not already in a
group; a group's own panel offers **Ungroup**, which discards the group's
pages and returns each screen with the settings and slides it had before.

A screen belongs to at most one group. Any combination works: two screens as a
pair, four as two pairs or as one and three, five as two and three.

## Inside a display

Both cards are the same for a screen and for a group.

The **display card** carries the status readings — one line per member for a
group — then cadence (data refresh, battery refresh, seconds per page), the
playback picker, the alert threshold, the tap link, quiet hours and **Push
now**. Where a screen shows its orientation picker, a group shows its
arrangement canvas: drag a panel, its edges snap to its neighbours', and each
member keeps its own rotation. Precise pixel coordinates are one disclosure
away, and an arrangement that overlaps or overflows the 4096 × 4096 canvas
says so rather than being silently corrected. Playback offers **One page** and
**Rotate**; a group is turned by the Mac, so the device's own loop is not on
offer for one.

The **slides card** is the same editor a screen uses: the page list with its
drag-reorder, **Add a slide**, the layout and preset pickers, content
selection, composition (header, footer, slot labels), the Studio, the page
arrows and the preview. A group's list is the group's pages, and its preview
is every screen in its arrangement drawing the selected page.

## Screens, per page

Above the page's editor, a group page says which screens it uses:

- **Combined** — the screens make one canvas and the page draws a single
  template across it. This is the point of a group: a bigger canvas fits more
  than the four or five items one panel holds.
- **Separate** — each screen draws its own template. A tab strip names the
  members in arrangement order, and the editor below edits the one that is
  selected; there is never more than one editor on screen.
- **Custom** — with three screens or more, merge some screens into one canvas
  and leave others on their own. Merge and split act on the page's regions.

Switching keeps what was selected: combining collects every region's buckets
and periods, separating hands each screen a copy. **Add a slide** starts the
new page in the mode the selected page is in.

Content that does not fit continues onto derived pages, on the combined canvas
as on a single panel — capacity is measured from what the renderer actually
draws, so a nominal five-slot layout that can only print three long names
carries the rest onto the next page. Regions turn together, and a shorter
region holds its last page until the longer one has finished. Freeform editing
in the Studio needs one page per page, so a paginated page is turned into
independent pages on an explicit confirmation before the Studio opens.

## Device and storage boundaries

Group playback needs a running Mac and one Canvas API item in each panel's
LOOP task. Requests are paced per device; physical refresh completion is not
simultaneous. A partially failed group page stays pending for retry. Every
outgoing payload still obeys the device's element and size limits.

Membership, pages and group settings live under the existing `einkSync`
settings key, in the shape earlier builds wrote: a group's `frames` are its
pages, and each page's `regions` assign one template to one or more screens.
Groups written by Dev 84 and Dev 85 decode and play unchanged. Custom layouts
stay in `einkCanvasLayouts` — a group page forks its own copy, so editing it
never rewrites the layout a screen keeps for the day it leaves the group — and
credentials stay in the credential vault. No group or page stores an API key.
