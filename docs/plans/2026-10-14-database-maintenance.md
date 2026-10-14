# Description

Database maintenance settings for an open database, like KeePassXC and MacPass: recycle bin on/off and its group, history limits, cipher choice, changing the master key (password and/or key file), removing unused custom icons.

Already implemented and kept: name and description, templates group, KDF (Argon2d/Argon2id/AES-KDF and their parameters), master password change (password only, current key file kept), additional databases.

Stack: Swift 6.1, SwiftUI, KeePassKit (`KPKMetaData.useTrash` / `trashUuid` / `historyMaxItems` / `historyMaxSize` / `cipherUUID` / `customIcons` / `removeCustomIcon:`, `KPKCompositeKey`, `NSData+KPKKeyfile`). No new libraries. Design: new cards and sheets in the Claude Design project `KeeMac.dc.html` (Step 0), built from existing components (`sectionCard`, `.kmField`, `KMButtonStyle`, `KMSegmentedControl`, confirm dialog).

## Decisions

- **Master key** (`A`): one sheet "Change Master Key…" opened from the settings card: current password (required, checked with `verifyMasterKey`), new password + confirmation (empty keeps the current password), key file: Keep / Choose another… / Generate new… / Remove. One save re-encrypts once. Removing the key file needs a password (current or new). After the change the recent-database entry remembers the new key file; the Touch ID password is updated as today.
- **Recycle bin** (`B`): toggle "Move deleted entries to the recycle bin" and a group picker (any group outside the bin, or "New group"). Turning it off with entries in the bin asks: "Empty the recycle bin" / "Keep as a normal group" / "Cancel". Keeping it shows the former bin as a normal group.
- **History limits** (`B`): "Keep up to N versions" (or unlimited) and "Up to N MB per entry" (or unlimited). New limits apply as entries change (KeePassKit's own history maintenance); existing history isn't trimmed.
- **Layout** (`B`): one scrolling sheet as today. New cards: "Recycle Bin", "History", "Maintenance"; the cipher picker joins the Encryption card; "Master Password" becomes a "Master Key" card with the current key summary (password, key file name) and "Change Master Key…".
- Each card keeps its own save button; cipher and KDF are applied together with "Apply Encryption".
- **Unused icons**: "N unused custom icons" with "Remove…" and a confirmation; icons used by history versions count as used.
- A generated key file: "Generate…" asks where to save it (save panel); the file is written only when "Change Master Key" is confirmed, right before re-encrypting. Cancel creates nothing.
- Settings changes aren't undoable (as today); the `.bak` copy keeps the previous file. Emptying the bin while turning it off and removing icons clear the undo stack.
- "Unlimited" history is stored as `Int32.max`: KeePass and KeePassXC read -1 as unlimited, but KeePassKit reads -1 as "history off" (and clears history), so -1 from other clients is shown as unlimited and not written by KeeMac.
- With the bin off, deleting an entry asks "Delete permanently?" instead of "Move to Trash?" (`VaultSummary.usesRecycleBin`).

## Design details (KeeMac.dc.html, "DB Settings · …", "Change Master Key sheet", dialogs)

"Database Settings sheet": 620 pt, one scrolling column, title "Database Settings" + file name, "Close" at the bottom right; the Change Master Key sheet and both dialogs open over it. Card order: General, Entry Types, Encryption, Recycle Bin, History, Master Key, Maintenance, Additional Databases (the mockup lists Additional Databases right after Entry Types; KeeMac keeps it last as today).

- **General**: Name, Description, plus a read-only "Location" row with the database file path; "Save General".

- **Encryption**: segmented "Cipher" AES-256 / ChaCha20 / Twofish; segmented "Key derivation" Argon2id / Argon2d / AES-KDF with a note ("Memory-hard. Resists GPU and ASIC cracking." / "Legacy. Use for KeePass 2.34 and older."); parameters as menus: Memory 16–1024 MB, Iterations 2/5/10/20/50, Parallelism 1/2/4/8 threads, Rounds 6/30/60/120/300 million (a current value outside the presets is listed too); "Time to unlock ~X s on this Mac" (measured with the existing KDF calibration); note "Changing the cipher or key derivation re-encrypts the database when you apply."; button "Apply Encryption" (disabled until something changes, "Re-encrypting…" while saving).
- **Recycle Bin**: toggle "Move deleted entries to the recycle bin" with subtitle "Deleted entries can be restored" / "Deleting is permanent"; "Recycle bin group" menu (current bin "— current", indented groups, "New Group…" creates a group named "Recycle Bin" (localized)), count "12 entries in the bin" / "Empty"; "Save Recycle Bin". Dialog "Turn off the recycle bin?" "The recycle bin has N entries." with "Empty Recycle Bin" (destructive), "Keep as a Group", "Cancel".
- **History**: "Keep up to" − N versions + with "Unlimited" checkbox; "Up to" N "MB per entry" with "Unlimited"; note "New limits apply when entries change; existing history isn't trimmed."; "Save History".
- **Master Key**: rows Password "Set"/"Not set", Key file name or "None", Last changed (relative date); "Change Master Key…".
- **Change Master Key sheet** (500 pt): title + database file name; Current password ("Required"; errors "Enter the current password." / "The current password is wrong."); New password with reveal and strength meter, Confirm ("Passwords don't match" / "Match"); hint "Leave empty to keep the current password."; Key file segmented Keep / Choose… / Generate… / Remove: Keep shows "Keeps X." or "No key file. The database opens with the password only.", Choose opens "Choose a key file", Generate opens "Save the new key file" (Save As / Where); both then show the file name and folder ("— will be created" for Generate) with "Change", Generate warns "Back up this file: without it the database can't be opened.", Remove shows "The database will open with the password only." or the error "Set a password before removing the key file."; "Change Master Key" disabled while nothing changes, "Re-encrypting…" while saving. Generated key file name defaults to "<database name>.keyx".
- **Maintenance**: "Unused custom icons" with "N icons · X KB" and "Remove…", or "No unused icons"; dialog "Remove N unused icons?" "Icons used by entries, groups or their history are kept." with "Remove" / "Cancel".
- Short confirmations after actions (toast): re-encrypted, bin settings saved / emptied / kept as a group, history limits saved, master key changed ("Master key changed · Personal.keyx created" when a file was generated), icons removed.

# Implementation

## Step 0: Design
[x] Claude Design mockups in `KeeMac.dc.html`: Database Settings sheet with the new cards, Change Master Key sheet, disable-recycle-bin dialog, remove-icons confirmation

## Step 1: Domain and loader
[x] `VaultDatabaseSettings`: cipher, recycle bin (enabled, group path), history max items / max size (nil = unlimited)
[x] Loader reads/writes them; recycle bin switch with "empty" / "keep as group" handling; new recycle bin group creation
[x] Cipher change (re-encrypt on save)
[x] `changeMasterKey(currentPassword:newPassword:keyFile:)` with keep / replace / generate / remove; current password verified first
[x] Unused custom icons: count and remove (entries, history versions and groups count as users)

## Step 2: Settings UI
[x] Encryption card: segmented cipher and KDF, preset menus for parameters, unlock time estimate
[x] Recycle Bin card: toggle, group picker, disable dialog
[x] History card: max versions, max size, unlimited options
[x] Maintenance card: unused icons count and Remove
[x] Master Key card and Change Master Key sheet; recent-database key file and Touch ID updated afterwards
[x] Localize new strings (en/ru)

## Step 3: Docs
[x] README and CLAUDE.md

## Step 4: Tests
[x] Unit: settings round trip (cipher, bin, history), bin off with empty/keep, new bin group, key change (keep/replace/generate/remove, wrong current password), unused icon removal keeps used ones
[x] UI: change history limits, toggle recycle bin with the dialog, change master key with a generated key file and unlock with it

## Review fixes (docs/reviews/2026-10-14-branch-feature-database-maintenance.md)
[x] A changed key file is saved as the persisted selection, so it is used after a relaunch
[x] A generated key file is written to a temporary file and moved into place only after the re-encrypted save; generating over the current key file is refused; key files are 0600
[x] A lock during a long re-encryption isn't undone when the save finishes
[x] An unreadable current key file reports a file error, not "wrong password"
[x] Recycle bin and icon confirmations use the app's confirm dialog (`confirm.secondary` for "Keep as a Group")
[x] KeePass/KeePassXC's -1 history limits become `Int32.max` in the open tree so KeePassKit keeps versions; 0 versions (history off) is allowed; an unchanged size keeps its exact bytes
[x] Context menu wording follows the entry's own database; unlock estimate waits for the settings and drops stale results; refreshing status keeps unsaved drafts; the new bin's name is localized and the templates group can't be the bin
