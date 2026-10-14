# Description

Multi-select and bulk actions for entries. Select several entries and act on them together: move, delete, restore, tag, favorite.

Decisions (brainstorming, October 2026):

- **Where:** in every entry list (group, All Items, Favorites, tags, search results), but **within one database only**. A modifier click on an entry of another database (search covers every unlocked one) starts a new selection there. The selection may span groups of that database.
- **Recycle bin:** trashed entries only show in the bin, so a selection is either all trashed or none. In normal lists, Delete moves to the bin, or deletes permanently when the bin is off. In the bin view, the actions are Restore and Delete Permanently.
- **First iteration actions:**
  - move to a group (Move… picker and dragging onto a sidebar group);
  - delete;
  - restore / delete permanently in the bin;
  - tags;
  - favorite / unfavorite: "Add to Favorites" unless all of them already are.
- **Later iteration:** icon/color, export of the selection (entries from different groups keep their paths), duplicate.
- **Right pane:** with more than one entry selected, a selection panel replaces the entry card. It shows "N entries selected", a stack of tiles / short title list, and buttons for the actions. The same actions are in the rows' context menu and the Vault menu. This is a new screen: design first (Claude Design `KeeMac.dc.html`).
- **Tags:** one popover listing the database's tags plus a "New tag" field. Each tag has a tri-state checkbox: all / some (dash) / none. A click sets it on all or removes it from all, and Done applies everything as one undo step.
- **Dragging to another database:** dropping the selection on another database's group moves or copies it through the existing transfer flow, with the conflict sheet and per-entry decisions. `undoLastTransfer` takes back both sides.
- **Gestures (macOS standard):**
  - click selects one;
  - ⌘-click toggles;
  - ⇧-click selects a range from the anchor;
  - ⇧↑/⇧↓ extends;
  - ⌘A selects every entry in the current list;
  - Esc goes back to one entry.
  - Opening the editor ends multi-selection.
- **Batch semantics:** each bulk action is one loader call, so one merge check, one `.bak`, one save and one undo step with a plural action name. Favorites stay app-local (UserDefaults), not an undo step.
- **Selection upkeep:** when the visible list changes (search text, sidebar selection, sync or merge removing entries), the selection is trimmed to entries still in the list. If one is left, the normal card returns.

Stack: Swift 6.1, SwiftUI (custom entry list in `VaultBrowserView`, no `List(selection:)`), KeePassKit through `KeePassKitVaultLoader`; no new dependencies.

## Design details (KeeMac.dc.html: "Selection panel", "Tags popover", "Move to Group sheet"; demo states "Selection · …", "Tags popover · …", "Move to Group · …", "Delete confirmation", "Delete permanently", "Drag · …", "Context menu")

### List
- All selected rows get the accent fill. The focused row adds an inner ring (`inset 0 0 0 1.5px rgba(255,255,255,.7)` plus a darker 3px ring).
- The header count becomes "N selected" in the accent color, semibold.
- ⌘⇧-click adds a range to the current selection.

### Selection panel
Centered column, max width 460, padding 44/36 (Compact 24):
- a fan of up to 4 tiles: 56 pt, radius 14, offset 26 pt and rotated 7° per step, white 2 pt outline, shadow;
- title "N entries selected" (19 pt bold);
- names: "A, B and C" or "A, B, C and N more";
- a line with a `database` icon and the database name, plus a group icon and path when every entry is in one group (bin: trash icon + "Trash").

Buttons, 2-column grid with 8 pt gap:
- Tahoe: icon above label, height 64, radius 14, fill rgba(0,0,0,.045).
- Classic: white raised buttons, radius 7.
- Compact: icon beside label, height 36, radius 8.
- Labels: Move to Group…, Tags…, Add/Remove from Favorites (star filled orange when all are favorites), Move to Trash or Delete Permanently (danger tint).
- Bin variant: title "N entries in Trash", buttons Restore and Delete Permanently.

Hint below the buttons: "⌘-click to add or remove, ⇧-click to select a range, Esc to clear".

### Tags popover
Anchored under the Tags… button, 280 wide, radius 12.

At the top, a "New tag" field (tag icon) with a suggestion list:
- prefix matches;
- "Create “x”" when nothing matches exactly;
- the first item is highlighted, and Return picks it, adding the tag checked.

Rows (max height 240):
- tri-state checkbox: check / dash / empty;
- tag color dot (`KM.tagColor`);
- name, semibold when changed;
- "k of N" for a mixed tag still mixed;
- an accent dot marking a changed row.

Clicking cycles mixed → all → none (→ mixed again if it started mixed); none → all.

Footer: "N changes" + Cancel / Done. Done adds the tags now "all" and removes the ones now "none", as one step. "No tags yet" when the database has none.

### Move to Group sheet
- Title "Move to Group", subtitle "N entries · <database>".
- Search field, then groups of the selection's database:
  - indented by depth;
  - a flat list with paths while searching;
  - a "Current" badge on groups that hold selected entries.
- Click selects, double-click moves.
- Primary "Move N Entries" is disabled until a group other than the current one is picked. Return moves, or picks the only match. "No groups match".

### Confirmations
- Move to Trash: "Move N entries to Trash?" / "You can restore them from the Trash." / Move to Trash.
- Delete permanently: "Delete N entries permanently?" / "This can't be undone." / Delete Permanently.

### Context menu (on a selected row)
- Header "N Entries", then Move to Group…, Tags…, Add/Remove from Favorites, separator, Move to Trash (or Delete Permanently) with ⌘⌫.
- Bin: Restore, separator, Delete Permanently.
- Right-clicking an unselected row shows that row's normal menu.

### Drag
- The drag image is the first tile with the second tilted behind it, and a red count badge.
- Over a group of another database, a hint "Copy or move to <database>" appears.

### Toasts
- "Moved N entries to <group>" (+ " · <database>")
- "Added/Removed N entries to/from Favorites"
- "Updated tags on N entries"
- "Moved N entries to Trash" / "Deleted N entries"
- "Restored N entries"

### Esc
Closes the tags popover or the move sheet first, then clears the selection.

### Where we differ from the design
- **Favorites:** the button is hidden for an additional database, which has no favorites.
- **Recycle bin setting:** the panel follows each database's own recycle bin setting; the design assumes it's on for additional ones.
- **Focus ring:** follows the focused entry, which ⇧-arrows move, rather than staying on the range anchor.
- **⌘⌫:** new for the app; it also deletes a single entry.


# Implementation

## Step 0: Design
- [x] Claude Design: selected rows (several), the selection panel (normal and bin variants), the tag popover with tri-state checkboxes, the Move… group picker, the delete confirmation with a count
- [x] Update the local design copy and check it against these decisions

## Step 1: Loader batch operations
- [x] `VaultEditing`:
  - `moveEntries(ids:toGroupPath:)`
  - `deleteEntries(ids:)` (bin or permanent, like `deleteEntry`)
  - `restoreEntries(ids:)`
  - `updateTags(ids:adding:removing:)`
- [x] Each is one `beginUndo`/`endUndo` with new plural undo actions (`moveEntries`, `moveEntriesToTrash`, `deleteEntriesPermanently`, `restoreEntries`, `editTags`) and their localized names
- [x] Single-entry calls keep working (either thin wrappers or unchanged)

## Step 2: View model
- [x] `AppViewModel` bulk methods route to the loader that owns the selection (main or additional database, via `additionalTarget`)
- [x] Batch favorites (main database only, like single favorites: the button is hidden for an additional database)
- [x] Transfer of several entries by drag, reusing `makeTransferPayload` / `receiveTransfer` / `trashTransferredEntries` and the conflict sheet (`prepareTransfer(entryIDs:)` already takes several entries; the drag is wired in Step 4)

## Step 3: Selection model in the entry list
- [x] Replace `selectedEntryID` with a selection (`Set<UUID>` plus anchor and focused entry). `selectedEntryID` remains the "primary" entry for the card, HOTP, the browser, etc.
- [x] Gestures and keys from the decisions; the one-database rule; trimming on list changes; the editor ends multi-selection
- [ ] Selected-row styling for several rows (accent fill for every selected row done; anchor marker after the design); accessibility (`isSelected` trait done, count announced)

## Step 4: Selection panel and actions
- [ ] `EntrySelectionPanel`: count, tiles/titles, buttons; bin variant (Restore, Delete Permanently)
- [ ] Move… group picker (groups of the selection's database)
- [ ] Tag popover with tri-state checkboxes and "New tag"
- [ ] Delete confirmation with the count (`ConfirmDialog`)
- [ ] Context menu on a multi-selected row; Vault menu items (enabled by selection)
- [ ] Dragging the selection onto a sidebar group (same database: move; other database: transfer)
- [ ] Accessibility identifiers: `selection.*` (`selection.count`, `selection.move`, `selection.tags`, `selection.favorite`, `selection.delete`, `selection.restore`), `tagPicker.*`, `movePicker.*`

## Step 5: Localization and docs
- [ ] ru strings, plurals in `Localizable.stringsdict` ("%lld entries selected", "Move %lld entries…")
- [ ] README features, CLAUDE.md section

## Step 6: Tests
- [ ] Unit:
  - loader batch operations: one save, one undo step, bin on and off, tags add/remove;
  - view model routing for an additional database;
  - selection trimming
- [ ] UI tests:
  - ⌘-click / ⇧-click / ⌘A;
  - panel actions: move, delete then undo, tags tri-state, favorite;
  - bin restore;
  - search selection limited to one database

## Step 7: Review
- [ ] code-reviewer subagent, fix findings

## Later iteration
- [ ] Change icon / color for the selection
- [ ] Export the selection (XML/CSV), entries from different groups under their own paths
- [ ] Duplicate the selection
