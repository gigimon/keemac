# KeeMac

Native macOS password manager written in SwiftUI (with some AppKit). It reads and writes KeePass `.kdbx` databases; all KDBX parsing and cryptography come from the vendored KeePassKit library.

## Rules
1. Write feature code before tests
2. Write unit tests when code is done
3. Write several UI tests if was added new UI screens
4. After each feature, before merge run code-reviewer subagent, wait for finish and check report

## Build and test

```bash
swift build                      # debug build
swift run KeeMacApp              # run the app
swift test                       # XCTest suite (DataTests)
./scripts/build_app.sh           # package .build/dist/KeeMac Dev.app (tech.keemac.dev); --release: KeeMac.app (tech.keemac.app)
./scripts/run_ui_tests.sh        # build the UI test app and run the XCUITest suite (needs xcodegen)
./scripts/build_vendor_frameworks.sh   # rebuild Vendor/*.xcframework from pinned revisions
```

- Swift 6.1 package, macOS 15+, arm64.
- The unbundled debug binary stores settings in the `KeeMacApp` defaults domain. Packaged builds use their bundle ID: `tech.keemac.dev` ("KeeMac Dev") or `tech.keemac.app` (`--release`). `LegacySettingsMigration` copies the old `com.keemac.local` settings into `tech.keemac.app` once.
- Signing (`build_app.sh`):
  - It finds a certificate in the keychain and a profile for the bundle ID in `~/Library/Developer/Xcode/UserData/Provisioning Profiles` (team `BL65NHTRYD`), then signs with `keychain-access-groups`, the embedded profile and hardened runtime. Otherwise it signs ad-hoc. The UI test build is always ad-hoc.
  - `KeychainBiometricCredentialStore` uses the data protection keychain when the entitlement is there.
- `AppVariant` (bundle ID ending in `.dev`) gives "KeeMac Dev" its own SSH agent and browser sockets. `keemac-proxy` checks the same suffix. It also never writes `~/.ssh/config` and doesn't repair browser manifests automatically.
- Versions come from git (`scripts/resolve_version.sh`, sourced by the build scripts): HEAD at a `vX.Y.Z` tag is a release build with version `X.Y.Z`, anything else uses the short commit hash; the build number is the commit count. `release.yml` runs unit and UI tests on `vX.Y.Z` tags before publishing.

## UI tests

- `UITests/` holds the XCUITest suite: `project.yml` (XcodeGen; the generated `.xcodeproj` is ignored), `KeeMacUITests/` and `Fixtures/Sample.kdbx` (password `sample-password`; groups Work with GitHub, which has TOTP, and Jira, plus Mail in EMail).
- The suite has no host app: `KeeMacUITestCase` launches `.build/uitest-dist/KeeMac.app` from `scripts/build_app.sh --ui-testing` (bundle ID `com.keemac.uitests`, so its defaults and LaunchServices identity are separate from a real KeeMac) with `KEEMAC_UI_TESTING=1`.
- That mode (`Sources/UI/UITesting.swift`) starts from clean defaults, opens `KEEMAC_UI_TEST_VAULT` without the open panel, keeps Touch ID in memory, moves the browser and SSH agent sockets and manifests to `/tmp/keemac-uitests`, skips the global shortcut and notifications, and copies secrets to the `com.keemac.uitests` pasteboard. New singletons that touch user data must respect it.
- Tests find elements by `accessibilityIdentifier` (`unlock.*`, `toolbar.*`, `entry.<title>`, `sidebar.<selection id>`, `detail.*`, `editor.*`, `newEntry.*`, `newDatabase.*`, `groupEditor.*`, `confirm.*`, `settings.*`, `generator.*`; `KMSegmentedControl` segments via `identifierPrefix`), not by localized text; only menu items go by their English titles (tests launch with `-AppleLanguages (en)`). `CompletingTextField` takes its identifier through `.fieldIdentifier(_:)`.
- `KEEMAC_UI_TEST_NEW_DATABASE_DIRECTORY` replaces Documents as the New Database folder. Tests open Settings with ⌘, and close it with its own close button (the window is titled after the tab).
- `typeText` uses the current keyboard layout, so the base class switches to U.S. for each test and back. Locking hides the main window; `reopenMainWindow()` brings it back from the menu bar icon.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/Domain` | Plain models: `VaultEntry`, `VaultGroup`, `VaultEntryForm`, `VaultDatabaseSettings`, `VaultCreationOptions`, errors |
| `Sources/Data` | `KeePassKitVaultLoader` (actor wrapping KeePassKit: load, edit, save, create, KDF calibration), protocols in `VaultLoader.swift`, `KDBXHeaderReader` |
| `Sources/BrowserIntegration` | KeePassXC-Browser protocol (`BrowserMessageHandler`), `BrowserSocketServer`, `NativeMessagingHosts`, NaCl wrapper |
| `Sources/CTweetNaCl` | Vendored TweetNaCl (public domain) |
| `Sources/Proxy` | `keemac-proxy`: native messaging host, relays stdio to KeeMac's socket |
| `Sources/HardwareKey` | YubiKey challenge-response over USB HID (`YubiKeyDevice`, `YubiKeyHIDChallenger`) |
| `Sources/UI` | `AppViewModel`, all SwiftUI views, settings store, clipboard, theme |
| `Sources/App` | `@main` app, menu bar extra, main window controller |
| `Tests/DataTests` | Loader tests against temporary KDBX files |
| `Vendor` | Prebuilt `KeePassKit.xcframework` and `KissXML.xcframework` |

## UI conventions

- The design comes from the Claude Design project `KeeMac.dc.html` (plus `KeeMac Icons.dc.html`).
- Colors and shared components live in `Sources/UI/Theme.swift`: `KM.*` light/dark tokens, `KMButtonStyle`, `KMIconButtonStyle`, `.kmField`, `.kmCard`, `LetterTile`, `StrengthMeter`, `OTPRing`, `KMSegmentedControl`. Reuse them instead of system styles.
- Main screens: `UnlockView`, `NewDatabaseView`, `VaultBrowserView` (sidebar, list, detail), `EntryDetailPane`, `EntryEditorPane`, `DatabaseReportView`, `BrowserSheets` (new entry, group editor, confirm dialog), `SettingsView` (General, Security, Shortcuts, Browser, Auto-Type, SSH Agent, About), `DatabaseSettingsView` (sheet of per-database cards, each saved on its own) with `ChangeMasterKeySheet`.
- Layout variants Tahoe / Classic / Compact are stored under `KMLayout.storageKey`.
- All user-facing text goes through `L("…")` (UI and App use the public one in `Sources/UI/Localization.swift`, Domain has its own); SwiftUI literals would look in the main bundle, which a package can't fill. Pass the result as a String: `Text(L("Unlock"))`, `Button(L("Cancel"))`. Keys are the English text (`%@` / `%lld` for interpolations); translations live in `Resources/Localization/ru.lproj/Localizable.strings`, plurals in `Localizable.stringsdict` (en and ru). Words with several meanings use `L("stable.key", default: "English")`. `LocalizationTests` checks specifiers and plural forms.
- The main window uses a full-size content view with a transparent title bar; `WindowDragRegion` makes custom areas draggable.
- Quick Access (`QuickAccess.swift`, `QuickAccessHotKey.swift`): a non-activating `NSPanel` under the menu bar icon, opened by a Carbon global hotkey (no Accessibility permission). It handles keys in the panel's `sendEvent` because KeeMac isn't the active app. When it unlocked the database it locks again with `LockReason.quickAccess`, which leaves the clipboard alone.

## Data conventions

- Group paths are KeePassKit breadcrumbs joined with `.` and include the root group (`Root.Work.Servers`). Use `GroupPathFormatter` for display. The recycle bin is a `VaultGroup` with `isTrash == true` and is hidden from the tree.
- Every mutation saves immediately: a `.bak` copy is written next to the database, then the file is replaced atomically.
- Usage count and last access are updated in memory when a field is copied or a URL is opened, and written on lock through `savePendingChanges()`.
- Favorites and recently viewed entries are app-local (UserDefaults), not stored in the database.

## Database maintenance

- Plan: `docs/plans/2026-10-14-database-maintenance.md`. `VaultDatabaseManaging` covers settings (incl. cipher), `maintenanceStatus()`, `updateRecycleBin`, `updateHistoryLimits`, `removeUnusedCustomIcons` and `changeMasterKey(currentPassword:currentKeyFileURL:newPassword:keyFile:)`, which checks the current key first and writes a generated key file only when the change goes ahead.
- KeePassKit marks the bin by `trashUuid` even when `useTrash` is off, so turning the bin off also clears `trashUuid` (the group then shows as a normal one). `VaultSummary.usesRecycleBin` switches delete prompts to "Delete permanently".
- History "unlimited" is written as `Int32.max`: KeePass/KeePassXC read -1 as unlimited, KeePassKit reads it as "history off". Removing icons or emptying the bin while turning it off clears the undo stack.
- UI testing: `KEEMAC_UI_TEST_KEY_FILE` replaces the open/save panels of the Change Master Key sheet.

## Hardware keys

- Plan: `docs/plans/2026-10-14-hardware-key.md`. YubiKey HMAC-SHA1 challenge-response in KeePassXC's KDBX 4 scheme: the KDF seed is the challenge (PKCS#7-padded to 64 bytes), `SHA-256(response)` is hashed after the password and key file before the KDF. KeePassKit doesn't support it, so `scripts/patches/keepasskit-*.patch` (applied by `build_vendor_frameworks.sh`) adds `KPKCompositeKey.challengeResponseHandler` and `keepsKeyDerivationSeed`.
- The loader wraps such keys in `HardwareCompositeKey`; its `HardwareKeyResponder` caches responses per seed. Saves keep the seed (one challenge per session); a new hardware key gets a new seed, keeping it keeps the seed. A file rewritten by another client with a new seed asks the key once on the next merge. KDBX 3.1 with a hardware key throws `hardwareKeyUnsupportedFormat`; adding one saves KDBX 4.
- `HardwareKey` module: `YubiKeyDevice` speaks the OTP application's feature-report protocol over a `YubiKeyTransport` (tested against a simulated key), `YubiKeyHIDChallenger` finds keys with IOKit (FIDO interface first, like ykpers, to avoid Input Monitoring). The file doesn't record the key; `AppSettingsStore` remembers it per database, plus the "Touch ID without the hardware key" option, whose response the biometric store keeps next to the password.
- UI: `HardwareKeyPicker` (unlock, New Database, Change Master Key), `HardwareKeyPrompt.swift` (`PromptingHardwareKeyChallenger` shows the floating touch panel with Try Again / Cancel). UI testing: `KEEMAC_UI_TEST_HARDWARE_KEY=<hex secret>` (YubiKey 12345678, slot 2), `KEEMAC_UI_TEST_HARDWARE_KEY_TOUCH=1` / `timeout`; without it no keys are found.

## Multi-select

- Plan: `docs/plans/2026-10-14-multi-select.md`. `EntrySelection` (focus, anchor, ids) holds the entry list's selection; `selectedEntryID` in `VaultBrowserView` is its focus (setting it selects one entry). A selection never spans databases, is trimmed to the visible list in `ensureValidSelection`, and collapses when the editor opens.
- Bulk actions: `VaultEditing.moveEntries` / `deleteEntries` / `restoreEntries` / `updateTags` (one save, one undo step each; missing IDs are skipped), routed by `AppViewModel.editEntries` to the owning loader; favorites stay main-database only. The view gets them through `EntryBulkActions`.
- UI: `EntrySelectionPanel`, `TagSelectionPopover` (`BulkTagEditor` tri-state logic), `MoveToGroupSheet` in `EntrySelectionViews.swift`; drag payload `keemac-entry:<id>,<id>…`. Identifiers `selection.*`, `tagPicker.*`, `movePicker.*`.

## Undo, import and export

- KeePassKit records the inverse of tree changes in the `NSUndoManager` it gets from the tree delegate; `KMUndoStack` (`Sources/UndoSupport`, Objective-C because Swift marks `UndoManager` main-actor only) owns it and keeps our own action names. Registration is off by default: wrap every user-visible mutation in `beginUndo()` / `defer { endUndo(.action) }`. Merges run with a throwaway manager (`withoutUndo`), and merging someone else's changes clears the stack.
- `VaultImporter` reads KeePass XML, seven CSV formats and KeePass 1 `.kdb` (`Sources/Data/VaultImporter.swift`); a `.kdb` throws `keePass1Locked` until `readKeePass1` gets its key, then imports as KeePass XML without the Backup group; `importEntries` and `exportDatabase` live in the loader. Group exports build a new tree from copies so the file doesn't list everything else as deleted objects.

## Sync conventions

- Merging uses `KPKTree.synchronize(with:mode: .synchronize)`: the newer entry wins, the other version goes to history. `VaultMergeDiff` turns before/after trees into a `VaultMergeSummary` for the UI.
- The loader remembers the file fingerprint (SHA-256 + size) of what it last read or wrote. Every save merges the file on disk first if the fingerprint changed, and skips rewriting when the disk already has everything.
- `VaultFileWatcher` watches the open file; `AppViewModel.checkForExternalChanges()` acts by the per-database `VaultSyncMode` (automatic / ask / off).
- Snapshots of the last save live in `~/Library/Application Support/KeeMac/Snapshots` and are merged back on unlock. Tests create loaders without a snapshot directory, so snapshots are off there.
- Manual merges go through `prepareMerge(from:)` → preview → `commitPreparedMerge()` / `discardPreparedMerge()`. `VaultConflictCopyFinder` finds copies left by iCloud, Dropbox and Syncthing.

## Additional databases

- The main database can have additional `.kdbx` files attached (`Sources/UI/AdditionalDatabases.swift`, views in `AdditionalDatabaseViews.swift`). The list is stored per main database in `AppSettingsStore` (bookmarks, this Mac only); each one is unlocked with its own password for the session (never Touch ID) and locks with the main database.
- Each unlocked one has its own `KeePassKitVaultLoader` (own undo, saving, `.bak`). The browser sees one merged `browserVault`: group paths of an additional database get a `DatabaseScope` prefix and entry/group IDs are XORed with a per-session salt, because a backup copy shares every UUID and path with the main database. `AppViewModel` routes each edit by ID or path (`additionalTarget`) to the owning loader; `activeDatabaseKey` (the browser's selection) decides where ⌘Z goes.
- Library rows, favorites, tags, the report, expiry reminders, Quick Access and browser integration use the main database only; search covers every unlocked one.
- Moving or copying between databases: the source packs a payload (`makeTransferPayload`, references replaced by values, UUIDs kept), the target reports conflicts by UUID or title + username and receives it with per-entry decisions (`receiveTransfer`), and after a move the source trashes the originals (`trashTransferredEntries`). Each side is one undo step (`receiveEntries` / `sendEntries`); `undoLastTransfer` takes back both while they are still the last change. Moving a group node across KeePassKit trees loses its children, so groups are rebuilt with `transplant`.

## Auto-Type

- Plan and decisions: `docs/plans/2026-10-13-auto-type.md`. Settings live in KeePass's own fields through KeePassKit (`KPKEntry.autotype`, `KPKGroup.isAutoTypeEnabled` / `defaultAutoTypeSequence`); the loader works out group inheritance itself (`VaultAutoTypeInheritance`) because KeePassKit's `isAutotypeable` reads the parent's raw flag. `VaultEntryForm.autoType == nil` leaves an entry's settings untouched.
- Domain: `AutoTypeSequence` parses KeePass sequences into tokens (placeholders stay tokens, so typed values are never read as commands), `AutoTypeMatcher` picks login entries by association, browser tab URL (`BrowserURLMatcher`) and title.
- UI: `AutoTypeController` (global hotkey, placeholder values incl. `{TOTP}` and HOTP advance, typing), `AutoTypeSystem.swift` (Accessibility, window/URL reading through AX, `SystemAutoTypeTypist` posting Unicode `CGEvent`s), `AutoTypeNotices.swift` (typing / permission / Secure Input / failure panel), Quick Access's Auto-Type mode (picker, unlock and type). `GlobalHotKey` keeps one handler per hotkey ID.
- UI testing mode: no hotkey; Vault → "Perform Auto-Type" stands in for it with a fake Safari window (`KEEMAC_UI_TEST_AUTOTYPE_TITLE` / `_URL`), `KEEMAC_UI_TEST_AUTOTYPE_PERMISSION=denied` removes the permission, and what would be typed lands on the UI test pasteboard with keys as `{TAB}`.

## SSH agent

- Plan and decisions: `docs/steps/step-9-ssh-agent.md`. KeeMac runs its own agent on `~/.keemac/agent.sock` (`SSHAgent` module: `SSHAgentServer`, key reading in `SSHKey.swift`, `SSHConfigSetup`, host matching); `SSHAgentController` (UI) answers it from the main database and shows the floating request / unlock panels.
- Keys are ordinary entries (type `.sshKey` or any entry with agent settings): the private key is an attachment, its passphrase the entry password, settings in the `KeeAgent.settings` attachment exactly like KeePassXC (`VaultSSHAgentSettings`), KeeMac's hosts and confirmation in CustomData `KeeMac.SSHAgent`. The loader hides `KeeAgent.settings` from `attachments` and rewrites it from `VaultEntryForm.sshAgent`, so every form built from an entry must carry `sshAgent`.
- Keys are picked by host: `session-bind@openssh.com` gives the server's host key (its signature over the session id is verified), `~/.ssh/known_hosts` turns it into names (hashed lines are checked against the keys' host names), and only matching keys are listed. A signature request means the server accepted the key, so its host is learned.
- Encrypted OpenSSH keys use the vendored `CBcryptPBKDF` (OpenSSH portable, ISC/BSD). Tests check keys and the agent against the real `ssh-keygen` / `ssh-add`.

## Browser integration

- KeePassXC-Browser talks to `keemac-proxy` (manifest `org.keepassxc.keepassxc_browser.json`), which relays frames to `$TMPDIR/KeeMac.BrowserServer`. Plan and protocol notes: `docs/steps/step-8-browser-integration.md`.
- Associations (`KPXC_BROWSER_<id>` in database CustomData), the database hash and per-entry `KeePassXC-Browser Settings` follow KeePassXC's formats exactly; keep them compatible.
- URL matching and access rules live in `Domain/BrowserMatching.swift`; `BrowserIntegrationController` (UI) answers the server from the open database and shows the prompts.
- Supported: filling, `set-login` (new entries go to "KeePassXC-Browser Passwords" unless the extension picks a group; updates follow password references and push history), groups, `generate-password` (generator window with Fill). Not supported: passkeys, `request-autotype`.

## Licensing

- KeeMac is GPL-3.0-or-later (`LICENSE`) because it links KeePassKit (GPLv3).
- Third-party license texts live in `Sources/UI/Resources/Licenses` and are shown in Settings → About (`AboutLicenses.swift`).
- Vendored revisions are pinned in `scripts/build_vendor_frameworks.sh`; keep them in sync with `AboutLicenses.swift` and the README table when updating. KeeMac's KeePassKit changes live in `scripts/patches` and are part of the GPL source: challenge-response keys, and `SettingsChanged` kept as read (the unarchiver no longer bumps it, unchanged setters don't, merges take the newer side's settings), and Twofish buffers (the cipher wrote the padding past a stack buffer the size of the database).
