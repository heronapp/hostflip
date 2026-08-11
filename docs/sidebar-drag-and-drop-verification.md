# Sidebar Drag-and-Drop GUI Verification

Verifies the real macOS interactions for #31; use the app produced by
`scripts/build-app.sh`, and make sure the test data contains no profile content
that needs to be preserved.

## Setup

1. Launch `build/Hostflip.app` and create three standalone profiles
   `Standalone A`, `Standalone B`, and `Standalone C`.
2. Create three groups `Group A`, `Empty Group`, and `Group C`; move two new
   profiles into `Group A` and name them `Grouped A` and `Grouped B`.
3. Select `Standalone B` and note the active state of each profile.

Dragging starts from the three-line handle at the end of the row. While
hovering, a blue insertion line should appear at the insertion boundary of a
profile or group; when a profile hovers over the standalone section or a group
header, the entire target header should show a blue outline.

## Steps

1. **Reordering within the same container**: drag `Standalone A` onto the
   upper half and then the lower half of `Standalone C`; repeat with
   `Grouped A` / `Grouped B`. Each result should land exactly where the
   feedback line was, regardless of drag direction.
2. **Moving across containers**: drag `Standalone C` onto the upper half of
   `Grouped A`, then onto the lower half of `Standalone A`. Groups and the
   standalone section use the same insert-before/insert-after semantics.
3. **Dropping onto an empty group**: drag `Standalone C` onto the header of
   `Empty Group`; the full-row outline appears, and after the drop the profile
   becomes the group's only member.
4. **Reordering groups to the front, the back, and in between**: drag
   `Group C` onto the upper half of the `Group A` header, then onto the lower
   half of the last group header; afterwards drag it onto the upper/lower half
   of any adjacent group header. A clear insertion line should appear at the
   front, at the back, and between groups, without needing to hit the header
   text.
5. After each drag, confirm that `Standalone B` is still selected, the editor
   on the right has not switched, and the active state of every profile
   matches the setup phase.

## Consistency checks

1. Quit and relaunch the app; confirm the sidebar order is unchanged.
2. Inspect `~/Library/Application Support/hostflip/manifest.json`: the order
   of `standaloneProfiles`, `groups`, and each group's `profiles` should match
   the sidebar.
3. Perform one merged write for the active profiles and confirm the profile
   block order in the system hosts is: Base Hosts, standalone profiles, then
   each group's profiles in sidebar order.
4. Run `swift test --filter WorkspaceStoreTests`; the automated assertions for
   insertion boundaries, manifest persistence, and the final merge order
   should all pass.

## 2026-08-10 Verification log

Environment: macOS 26.6.1 (25G76), `build/Hostflip.app`, isolated Application
Support directory. The following drag-and-drops were performed with an actual
mouse from the row-end handle, checking the blue insertion line or the target
container outline each time:

- Profiles moved forward and backward within the same container, and between
  the standalone section, a non-empty group, and an empty group; the upper
  half always inserted before, the lower half always inserted after.
- Groups moved to the first position, the last position, and between adjacent
  groups; the insertion line sat at the boundary of the full section.
- After all drops, `Standalone B` was still selected and the editor on the
  right had not switched; the manifest's `activeProfileIDs` was empty, and no
  profile's active toggle was accidentally triggered.

The final sidebar and manifest both read:

- Standalone profiles: `Standalone B`, `Standalone A`.
- Group order: `Group A`, `Group C`, `Empty Group`.
- `Group A`: `Grouped B`, `Grouped A`; `Group C` is empty; `Empty Group`:
  `Standalone C`.

`WorkspaceStoreTests` separately covers manifest reload and the final hosts
merge order, so the GUI check does not only verify the transient on-screen
state.
