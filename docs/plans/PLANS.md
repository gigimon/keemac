# KeeMac feature plans

Gap analysis against MacPass, KeePassXC, 1Password and Bitwarden (October 2026).
Each feature gets its own detailed plan in `docs/plans/<date>-<feature-name>.md` when work starts.
Priority: **P1** — expected by most users / parity with KeePassXC & MacPass, **P2** — strong value, **P3** — nice to have.

## Already implemented (baseline)

- KDBX 3.1/4 open & create (password, key file, AES/ChaCha20/Twofish, Argon2/AES-KDF), recent databases, Touch ID per database
- Browsing: library, group tree, tags, three layouts, search with operators, favorites, recently viewed
- Entries: custom fields, attachments with preview, TOTP (QR import), entry types and templates, references and placeholders, history with revert, colors and icons, expiry
- Password generator (random + EFF passphrases), Database Report (health, HIBP breach check, expiry reminders)
- Sync & merge (file watcher, safe saves, snapshots, conflict copies, manual merge), undo/redo
- Import (KeePass XML, 7 CSV formats, KeePass 1 `.kdb`), export (XML, CSV)
- Browser integration via KeePassXC-Browser (fill, save logins, TOTP, generator, favicons)
- SSH agent (host matching, confirmation, KeeAgent-compatible settings)
- Additional databases, transfer between databases, Quick Access panel with global hotkey
- Auto-lock, clipboard clearing, `.bak` + atomic saves, English/Russian, VoiceOver

## Not implemented yet

### P1

- [x] **Auto-Type** (KeePassXC, MacPass) — type username/password sequences into other apps — plan: [2026-10-13-auto-type.md](2026-10-13-auto-type.md)
  - Entry/group Auto-Type settings and window associations (KeePass format via KeePassKit), full editing
  - Sequence parser (`{USERNAME}{TAB}{PASSWORD}{ENTER}`, keys, modifiers, delays, `{TOTP}`)
  - Matching by window associations, window title and browser tab URL (Accessibility)
  - Unicode keystroke typing via CGEvent (Accessibility permission, Secure Input check)
  - Separate global hotkey ⌃⌥⌘A, picker in Quick Access Auto-Type mode, Settings section
- [ ] **System AutoFill / Safari** (1Password, Bitwarden) — Credential Provider extension (AuthenticationServices)
  - App extension target + App Group shared container, signed build
  - Credential identity store sync from the main database (no secrets), unlock UI in the extension (Touch ID)
  - Fill passwords and TOTP in Safari and native apps
- [ ] **Passkeys** (KeePassXC 2.7.7+, 1Password, Bitwarden)
  - Store passkeys in KeePassXC format (`KPEX_PASSKEY_*` attributes) and show them in entries
  - KeePassXC-Browser `passkeys-register` / `passkeys-get` messages (WebAuthn: ES256/EdDSA, attestation none)
  - Later: system passkey provider through the Credential Provider extension
- [x] **Hardware key unlock** (KeePassXC) — plan: [2026-10-14-hardware-key.md](2026-10-14-hardware-key.md) — YubiKey HMAC-SHA1 challenge-response, KeePassXC compatible, USB HID via IOKit, combined with password/key file
  - KeePassKit patch: challenge-response in the composite key (KDBX 4), KDF seed kept between saves (one touch per session)
  - YubiKey HID driver, software emulator for tests
  - Unlock / New Database / Change Master Key with a hardware key, touch panel
  - Per-database option: Touch ID unlocks without the hardware key
- [ ] **Multi-select and bulk actions** (all four) — select many entries: move, delete, tag, favorite, export selection, change icon
- [x] **More OTP types** (KeePassXC, 1Password, Bitwarden) — HOTP with counter and Steam Guard — plan: [2026-10-13-otp-types.md](2026-10-13-otp-types.md)
  - Domain kinds + HOTP/Steam generators
  - Loader read/write (native `HmacOtp-*`, Steam `encoder=steam`), counter advance without history, merge keeps max counter
  - Editor kind selector, detail card "Next code" for HOTP
  - Browser `get-totp` / Quick Access advance HOTP; tests

### P2

- [ ] **More import formats** (1Password, Bitwarden, KeePassXC) — 1Password `.1pux`, Bitwarden JSON (incl. password-protected), Proton Pass, Dashlane, Enpass, Apple Passwords with notes/OTP
- [ ] **KeeShare** (KeePassXC) — share a group through a separate synchronized `.kdbx` container (import / export / sync modes, KeePassXC-compatible)
- [x] **Database maintenance settings** (KeePassXC, MacPass) — plan: [2026-10-14-database-maintenance.md](2026-10-14-database-maintenance.md) — recycle bin on/off and group choice, history limits (items/size) for existing databases, remove unused custom icons, change key file / KDF / cipher of an open database
  - Recycle bin toggle and group (asks what to do with the bin's entries when turned off)
  - History limits (versions, size) for new changes; cipher next to the KDF
  - Change Master Key sheet: current password, new password, key file keep/choose/generate/remove
  - Remove unused custom icons
- [ ] **Custom icons management** (MacPass, KeePassXC) — add icons from files, bulk download favicons for existing entries, icon library per database
- [ ] **Extended Watchtower** (1Password, Bitwarden) — sites that support 2FA but have none (2fa.directory), insecure `http://` URLs, duplicate entries, checking usernames/emails in breaches
- [ ] **Command-line tool** (keepassxc-cli, Bitwarden CLI) — `keemac` CLI: search, show, clip, totp, generate; talks to the unlocked app over a local XPC/socket with confirmation, or opens a file directly
- [ ] **Shortcuts / App Intents & Spotlight** (1Password) — intents: generate password, lock, copy field of an entry; optional Spotlight index of titles only
- [ ] **Versioned backups** (KeePassXC) — keep N timestamped backups in a chosen folder instead of a single `.bak`, restore from the backup list
- [ ] **Clipboard hardening** (KeePassXC, 1Password) — `org.nspasteboard.ConcealedType` / `TransientType` markers, exclusion from Universal Clipboard
- [ ] **Username / email alias generator** (Bitwarden, 1Password) — random usernames, plus-addressing, optional SimpleLogin / addy.io / Fastmail masked email API

### P3

- [ ] **Emergency Kit & printing** (1Password, KeePass) — printable PDF with database location and master password field; print selected entries/groups
- [ ] **Unlock with Apple Watch** — `deviceOwnerAuthenticationWithBiometricsOrWatch` for the Touch ID flow
- [ ] **Generator extensions** (KeePassXC, Bitwarden) — custom word lists, generator history (session only), password rules per site
- [ ] **Secure sharing of an item** (Bitwarden Send, 1Password share) — export one entry as an encrypted one-off file/QR with expiry, offline only
- [ ] **History diff view** (KeePassXC) — side-by-side comparison of an entry's history versions
- [ ] **Markdown notes** (1Password) — render Markdown in notes with a raw/preview toggle
- [ ] **iOS / iPadOS companion** — read/write the same `.kdbx` with the shared Domain/Data modules (large, separate project)
