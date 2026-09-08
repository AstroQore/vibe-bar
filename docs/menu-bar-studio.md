# Native menu bar rendering in Studio

`MenuBarNativeRenderer` is the drawing and measurement path shared by the
status item, the Studio stage, Settings previews and the drag image. It uses
AppKit fonts and brand images and reports the rectangles it drew. Studio
magnifies those coordinates and adds selection outlines and segment controls
without adding padding between the actual tokens.

Default field layouts enter the same renderer through the existing seed
rules, filtered to live percentage-bearing fields first. Icon Only retains
its system template image. Both Default and Custom show a live Studio
preview; changing their mode does not erase the saved composition.

A group is an atomic editing unit. Group gathers the selection at its first
element in reading order, including complete existing groups. Unselected
neighbours remain outside. Selecting, dragging, copying or removing a member
operates on the whole group; a copy receives fresh child and group IDs.
Dropping another element before a child inserts before the group boundary.
Ungroup leaves the children in place. The existing flat wire representation
is retained, so saved compositions remain compatible.

Mini Window groups retain the children's two-dimensional positions and
appear as one layer with one selection boundary. Their empty interior also
belongs to the group's hit region. Popover cards can be selected on the stage
or in the inspector, grouped, moved or hidden together. A card group remains
distinct from a layout segment and is saved under `studioCardGroups`.
Grouping and its arrangement are saved as one change, so Undo restores both.
