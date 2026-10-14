# KeeMac

A native macOS password manager for KeePass (`.kdbx`) databases, built with SwiftUI and a bit of AppKit.

> This project was developed using **OpenAI Codex**.

## Features

### Databases
- Open local `.kdbx` files with a master password, a key file or both.
- YubiKey HMAC-SHA1 challenge-response (slot 1 or 2) as part of the master key, compatible with KeePassXC (KDBX 4). Add it when creating a database or in Change Master Key; the unlock screen remembers it per database. The key is asked once per session: saves keep the KDF seed, so a slot that needs a touch isn't touched on every change. Optionally Touch ID can unlock without the key (Database Settings → Master Key).
- Create new databases: name and location, master password and/or key file (choose or generate), encryption presets or a custom format, cipher (AES-256, ChaCha20, Twofish), KDF (Argon2id, Argon2d, AES-KDF) calibrated to the unlock time you pick.
- Database Settings (⇧⌘,): name and description, templates group, cipher and KDF with the estimated unlock time, recycle bin on/off and its group (turning it off asks whether to empty it or keep it as a group), history limits per entry (versions and size, for new changes), changing the master key (current password, new password and/or a chosen, generated or removed key file), removing unused custom icons, additional databases.
- Recent databases are remembered (security-scoped bookmarks); Touch ID unlock can be enabled per database. Removing a database from the recent list also deletes its Touch ID password and KeeMac's copy of its last save.
- The unlock screen shows the format, KDF and cipher read from the KDBX header.

### Browsing and editing
- Floating sidebar with the library (All Entries, Favorites, Recently Viewed, Recently Modified, Trash), a group tree with counts and tags.
- Layouts: Tahoe (floating sidebar, grouped cards), Classic (flush sidebar, form-style details), Compact (single-line list).
- Sort by title or last modification, keyboard navigation, drag and drop between groups.
- Field references and placeholders from KeePass and KeePassXC (`{REF:P@I:…}`, `{USERNAME}`, `{URL}`, `{S:Field}`): shown, copied and checked with the values they point to, with a link to the source entry and a warning for broken references; the editor keeps the stored reference. Duplicate with References makes a copy whose username and password follow the original.
- Inline completion in unprotected fields (title, username, website, tags, custom fields, Wi-Fi network, host): the rest of a value already used in the database appears selected; Tab, → or Return accept it, Esc removes it.
- Entries: create, edit inline, duplicate, move to Trash, restore, delete permanently, empty Trash, favorites, history with revert.
- Search across titles, usernames, websites, notes, groups, tags, custom fields and attachment names (protected fields are never searched). All words must match; `"phrases"`, `-exclude`, field operators (`title:` `user:` `url:` `notes:` `group:` `tag:` `field:`) and filters (`is:otp` `is:expired` `is:expiring` `is:weak` `is:favorite` `has:attachment`) are supported.
- Custom fields (protected or plain), attachments, TOTP (secret or `otpauth://` URI), tags, icon and colors, expiry date.
- Attachments: preview images, PDFs and text files inside the app without writing them to disk, save with Save… or drag to Finder; in the editor add, drop, rename, replace and remove files.
- Password generator: random passwords (8–64 characters, choice of character types, look-alike characters can be avoided, custom symbol set, digits only for PINs) or passphrases from the EFF word list (3–10 words, separator, capitalization, an added number), with the exact entropy. It sits under every password field and in its own window (Generate Password…, ⌥⌘G, also in the menu bar) that works while the database is locked. Generated passwords aren't stored.
- One-time passwords from QR codes: select the code on screen (needs the Screen Recording permission), paste a QR image or choose an image file, or drop it on the TOTP field. Decoded on the Mac with Vision; the captured image is deleted right after reading.
- Groups: create, rename, change icon, move, delete.
- Entry types (KDBX 4 databases): Login, Credit Card, Wi-Fi, Server / SSH and Secure Note from the arrow next to New Entry. Each type has its own form and card (masked card number with brand and expiry, Wi-Fi security, `ssh://` host with Open in Terminal) and is stored in standard KeePass fields plus custom fields, so other clients can read it. The type itself is kept in the entry's CustomData. KDBX 3.1 files show plain fields.
- Templates: entries in the database's templates group (Database Settings → Entry Types, the standard KeePass setting) appear as types in New Entry; their custom fields become the new entry's fields.

### References
- **Insert Reference…** on the username, password, URL or notes field of the editor links it to a field of another entry (`{REF:…}`), so a shared password is changed in one place. Linked fields show the source entry with Go to Entry, Change Reference and Unlink; entries that would form a loop can't be picked.

### Database Report
- Summary: counts, master key age, data completeness, most used and stale entries.
- Password Health: expired or expiring, reused, weak and old passwords.
- Breach Check against Have I Been Pwned using k-anonymity (only 5 characters of the hash leave the Mac).
- Expiry reminders: after unlocking, one macOS notification and a banner when passwords expired or expire within 7, 14 or 30 days (per database). The notification shows counts only, never entry names. The Database Report row in the sidebar shows red and orange counts.

### Sync and merge
KeeMac keeps working when the database file is shared through iCloud Drive, Dropbox, Syncthing or edited by another KeePass client. Merging uses KeePassKit's synchronization: the newer version of an entry wins, the other version goes to the entry's history, and deletions carry over through the database's deleted-objects list.

- **Watching the file.** While a database is open, KeeMac watches the file (file presenter for iCloud, folder watcher that survives atomic replaces) and checks it again when the app becomes active.
- **When the database changes on disk** (Settings → General → Sync, per database):
  - *Merge automatically* (default): changes from the other device are merged and saved right away. A toast reports how many changes came in, with **Show** to jump to them; changed entries get a cloud marker until you view them.
  - *Ask*: a banner says the file changed on another device, with **Show Changes** (preview of added, updated, deleted and moved entries), **Merge** and **Ignore**.
  - *Don't watch*: the file is not watched. Changes on disk are still merged before KeeMac saves, so nothing is overwritten.
- **Safe saves.** Before every save KeeMac compares the file with what it last read or wrote; if another device changed it, that version is merged in first. If the file already contains everything, it is not rewritten.
- **Editing an entry that changed elsewhere.** The editor shows a notice; your version is saved and the other one goes to history.
- **Overwrites while locked.** KeeMac keeps an encrypted copy of its last save in `~/Library/Application Support/KeeMac/Snapshots` (folder `0700`, files `0600`, same key as the database). If another client overwrote the file while the database was closed, the copy is merged back on unlock and a toast lists the restored entries.
- **Conflicting copies.** On unlock KeeMac looks for copies sync services leave next to the database (`Name 2.kdbx`, `Name (… conflicted copy …).kdbx`, `Name.sync-conflict-….kdbx`), offers to review and merge them, then to move them to the Trash. Can be turned off in Settings.
- **Merge Database…** (Vault menu, ⇧⌘M, or the ⋯ button): merge any other `.kdbx` file opened with its own password and key file, after a preview.

Not covered: a master key changed on another device, clocks that disagree between devices, clients that don't record deleted objects (deleted entries may come back), and the database file being moved or renamed elsewhere.

### Undo, import and export
- Undo and redo (⌘Z, ⇧⌘Z) for changes made in KeeMac until the database locks: new, edited, moved, deleted and restored entries and groups, emptying the Trash, imports and logins saved from the browser. Toasts after deleting or importing have an Undo button. Changes merged from another device clear the undo history.
- **Import…** (Vault menu, ⇧⌘I): KeePass XML (with groups, history, attachments and custom fields) and CSV from Bitwarden, 1Password, Chrome / Edge / Brave, Firefox, Safari / Apple Passwords, LastPass and KeePassXC, detected from the columns. A review step chooses the target group, keeps folders as subgroups, skips duplicates and lists rows that couldn't be read.
- **Export…** (Vault menu, ⇧⌘E): KeePass XML or CSV (KeePassXC columns), the whole database or the selected group, with or without the Trash, history and attachments. Needs the master password or Touch ID; the file is written readable only by you.

### Security
- Auto-lock after inactivity, lock on sleep, lock when the screen locks, the screen saver starts or you switch users. Quitting, logging out or shutting down locks the database first, so usage counts are saved. Copied secrets are cleared from the clipboard after a timeout, when the database locks and when KeeMac quits.
- A `.bak` copy is written next to the database before every change, and the file is replaced atomically.
- Usage count and last access are tracked when a field is copied or a URL is opened, and saved when the database locks.
- Logs never contain secret values.

### QR codes
- Any field (password, username, URL, custom and typed fields) can be shown as a QR code to scan with a phone. Wi-Fi entries also show a join code: scanning it connects the phone to the network.

### Browser autofill
- Works with the official [KeePassXC-Browser](https://github.com/keepassxreboot/keepassxc-browser) extension in Chrome, Chromium, Brave, Edge, Vivaldi and Firefox. KeePassXC isn't needed: KeeMac ships its own `keemac-proxy` and sets up the browsers in Settings → Browser.
- Fills logins and one-time codes, saves new and changed logins from the extension's banner (updates ask first and keep the old password in history), and fills passwords from KeeMac's generator. Passkeys aren't supported.
- Connections and per-site permissions are stored the way KeePassXC stores them, so a browser connected to the same database in KeePassXC keeps working.
- The first time a site asks for a login KeeMac asks which entries it may use, unless "Always allow access" is on.
- When the database is locked and the extension asks for a login, a small unlock window opens (Touch ID right away when it is set up); focus goes back to the browser afterwards.
- With the extension's "Download favicon after saving" on, new entries get the site's icon, fetched from the site itself.

### Auto-Type
- A global shortcut (⌃⌥⌘A by default) types the matching entry into the frontmost window of any app: `{USERNAME}{TAB}{PASSWORD}{ENTER}` unless the entry or its group sets another sequence. Text is typed as Unicode, so the keyboard layout doesn't matter.
- Entries are matched by window associations (`*` wildcards, `//regex//`), by the entry title in the window title, and in Safari and Chromium browsers by the tab address. One match types right away; otherwise Quick Access opens to pick an entry (it unlocks the database first when needed).
- Sequences follow KeePass: field placeholders, `{S:Field}`, `{REF:…}`, `{TOTP}`, named keys with repeats (`{TAB 2}`), modifiers `+` ⇧, `^` ⌘, `%` ⌥, `@`/`#` ⌃, `{DELAY 500}`, `{DELAY=50}`, `{CLEARFIELD}`. Entry and group settings are stored in the KeePass format, so KeePassXC and MacPass read them.
- Needs Accessibility access (Settings → Auto-Type shows its state); the shortcut is set in Settings → Shortcuts. When another app has Secure Keyboard Entry on, KeeMac says so instead of typing.

### Languages
- English and Russian. KeeMac follows the system language; System Settings → General → Language & Region → Applications sets it per app. For a debug build: `swift run KeeMacApp -AppleLanguages "(ru)"`.

### Accessibility
- VoiceOver: icon-only buttons have spoken labels, entry and sidebar rows read as one item ("GitHub, anna, Favorite"), checkboxes and segments report their state, hidden values read as "Hidden", and toasts such as "Password copied" are announced. Actions that only appear on hover (attachment Preview / Save, removing a recent database) are available as VoiceOver actions.

### macOS integration
- Menu bar extra with a locked or unlocked padlock icon.
- Optional Dock icon, launch at login, start minimized.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⇧⌘N | New database |
| ⌘O | Open database |
| ⇧⌘K | Select key file |
| ⇧⌘M | Merge database |
| ⇧⌘I | Import |
| ⇧⌘E | Export |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌥⌘G | Generate password |
| ⇧⌘, | Database settings |
| ⌘L | Lock database |
| ⌃⌥⌘A | Auto-Type into the frontmost window (global, configurable) |
| ⌘N | New entry |
| ⌘F | Search |
| ⌘E | Edit entry |
| ⌘D | Duplicate entry |
| ⌘S | Save while editing |

## Settings

- **General**: launch at login, start minimized, Dock icon, entries from subgroups, password generator defaults, sync mode, conflicting copies lookup, expiry notifications and banner, layout, entry icons.
- **Security**: Touch ID per database, auto-lock timeout, lock on screen lock, clipboard auto-clear timeout, how long Quick Access keeps the database unlocked.
- **Shortcuts**: the global Quick Access and Auto-Type shortcuts, each with an on/off switch.
- **Browser**: browser integration, per-browser setup, access confirmation, expired logins, updating without asking, connected browsers.
- **Auto-Type**: Accessibility permission, delay between keystrokes.
- **About**: version, license and every bundled component with its license text.

## Tech stack

- Swift 6.1, SwiftUI with AppKit interop, macOS 15+ (arm64).
- Swift package with these modules:
  - `Domain`: plain models and errors, browser URL matching.
  - `Data`: `KeePassKitVaultLoader` (load, edit, save, create, merge), KDBX header reader, conflicting copy finder.
  - `BrowserIntegration`: KeePassXC-Browser protocol, socket server, native messaging manifests.
  - `CTweetNaCl`: TweetNaCl for the browser connection's encryption.
  - `SSHAgent`: SSH agent socket and protocol, SSH key reading, signing and generation, `~/.ssh/config` setup.
  - `CBcryptPBKDF`: bcrypt-pbkdf from OpenSSH for passphrase-protected SSH keys.
  - `HardwareKey`: YubiKey OTP application over USB HID (IOKit): slots, serial number, HMAC-SHA1 challenge-response.
  - `Proxy`: `keemac-proxy`, the native messaging host browsers start.
  - `UI`: `AppViewModel`, SwiftUI views, settings store, clipboard, theme.
  - `App`: app lifecycle, main window, menu bar extra.
- Vendored binary dependencies: `KeePassKit.xcframework`, `KissXML.xcframework`.

```text
.
├── Package.swift
├── Sources
│   ├── App
│   ├── BrowserIntegration
│   ├── CBcryptPBKDF
│   ├── CTweetNaCl
│   ├── Data
│   ├── Domain
│   ├── HardwareKey
│   ├── Proxy
│   ├── SSHAgent
│   └── UI
├── Tests
│   └── DataTests
├── Vendor
│   ├── KeePassKit.xcframework
│   └── KissXML.xcframework
├── docs
│   └── steps
└── scripts
```

## Build and run

Requirements: macOS 15 or newer, Xcode 16+ or the Command Line Tools with Swift 6.

```bash
swift build                      # debug build
swift run KeeMacApp              # run the app
swift test                       # run the tests
./scripts/build_app.sh           # package .build/dist/KeeMac.app
```

The unbundled debug binary stores its settings in the `KeeMacApp` defaults domain; the packaged app uses `com.keemac.local`.

### Touch ID

- Touch ID is enabled per database in Settings → Security.
- The first unlock uses the password and/or key file; after that KeeMac stores the password in the Keychain for biometric unlock.
- If Touch ID is unavailable in your run context, run KeeMac as a signed app bundle for stable Keychain and biometric behavior.

## CI and releases

- `.github/workflows/ci.yml` runs on pushes to `main`, `master` and `codex/**` and on pull requests: `swift test`, a packaged `.app`, and a ZIP with a SHA-256 checksum as workflow artifacts.
- `.github/workflows/release.yml` runs on `vX.Y.Z` tags (or manually with an existing tag): it checks the tag, runs `swift test` and the UI tests, then builds the release ZIP and publishes a GitHub Release with the ZIP and checksum.

Versions come from git (`scripts/resolve_version.sh`):

- a build of a commit tagged `vX.Y.Z` is a release: version `X.Y.Z`;
- any other build is a development build: its version is the short commit hash (`-dirty` with uncommitted changes), shown as "Development build <hash>" in Settings → About;
- the build number is the number of commits up to `HEAD`;
- `APP_VERSION` and `BUILD_NUMBER` override both.

Build the release archive locally:

```bash
./scripts/make_release_archive.sh
```

It produces `.build/release/KeeMac-<version>-macOS.zip` and its `.sha256`. To publish a release:

```bash
git tag v0.2.0
git push origin v0.2.0
```

Run the UI tests locally (needs `brew install xcodegen`; don't touch the keyboard and mouse while they run):

```bash
./scripts/run_ui_tests.sh
```

## Known limitations

- macOS only.
- Browser autofill doesn't support passkeys or Safari.
- Import doesn't read 1Password `.1pux`, Bitwarden JSON or other non-CSV formats.
- Hardware keys: YubiKey challenge-response over USB only (no NFC, no KeeChallenge, no KeePassXC's KDBX 3.1 scheme).

## License

KeeMac is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. See [LICENSE](LICENSE).

Copyright © 2026 gigimon

KeeMac links against KeePassKit, which is licensed under GPLv3, so binaries of KeeMac are
distributed under GPLv3 as a whole. Settings → About lists every bundled component with its
copyright notice and full license text; the texts live in `Sources/UI/Resources/Licenses`.

| Component | License | Source |
| --- | --- | --- |
| [KeePassKit](https://github.com/MacPass/KeePassKit) | GPL-3.0-or-later | `b5cf50ee4ebd67cb355792d7813965fe3ac7125e` + `scripts/patches` |
| [KissXML](https://github.com/robbiehanson/KissXML) | BSD | `990cdef080213b5a3f0d9709b845d553bd3ddb97` |
| [Argon2](https://github.com/P-H-C/phc-winner-argon2) (in KeePassKit) | CC0-1.0 or Apache-2.0 | `b31aa322566a8559403d419b2e9cd3f57957e394` |
| Twofish by Niels Ferguson (in KeePassKit) | Permissive, attribution | KeePassKit tree |
| ChaCha20 by insane coder (in KeePassKit) | ISC-style | KeePassKit tree |
| KeePassX, MiniKeePass portions (in KeePassKit) | GPL | KeePassKit tree |
| AQToolkit, ShortcutRecorder notices (shipped with KeePassKit) | BSD | KeePassKit tree |
| [EFF Large Wordlist](https://www.eff.org/dice) | CC BY 3.0 US | `Sources/UI/Resources/WordLists` |
| [TweetNaCl](https://tweetnacl.cr.yp.to/) | Public domain | `20140427`, `Sources/CTweetNaCl` |
| bcrypt_pbkdf, Blowfish from [OpenSSH portable](https://github.com/openssh/openssh-portable) | ISC, BSD-3-Clause | `V_9_9_P1`, `Sources/CBcryptPBKDF` |

### Rebuilding the vendored frameworks

The vendored frameworks are built from the pinned revisions above:

```bash
bash scripts/build_vendor_frameworks.sh
```

KeeMac's changes to KeePassKit (challenge-response keys) are applied from `scripts/patches`.
Override `KEEPASSKIT_REF` / `KISSXML_REF` to build other revisions, and update the table above
and `Sources/UI/AboutLicenses.swift` when you do.

