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

# Implementation

## Step 0: Design
- [ ] Claude Design: selected rows (several), the selection panel (normal and bin variants), the tag popover with tri-state checkboxes, the Move… group picker, the delete confirmation with a count
- [ ] Update the local design copy and check it against these decisions

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
- [ ] Replace `selectedEntryID` with a selection (`Set<UUID>` plus anchor and focused entry). `selectedEntryID` remains the "primary" entry for the card, HOTP, the browser, etc.
- [ ] Gestures and keys from the decisions; the one-database rule; trimming on list changes; the editor ends multi-selection
- [ ] Selected-row styling for several rows; accessibility (`isSelected` trait, count announced)

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
