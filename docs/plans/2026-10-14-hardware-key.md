# Description

Hardware key unlock: a YubiKey HMAC-SHA1 challenge-response slot as an extra part of the master key, compatible with KeePassXC (and KeePassDX / Strongbox, which follow it). Works together with a password and/or key file.

Stack: Swift 6.1, SwiftUI, IOKit HID (`IOHIDManager`, feature reports; no ykpers/libusb), KeePassKit patched to take a challenge-response component. No physical key is available during development: the device layer sits behind a protocol, and tests use a software emulator (HMAC-SHA1 with a known secret). Design: unlock key picker, hardware key in New Database / Change Master Key, "Touch your YubiKey" panel, Touch ID option (Claude Design project `KeeMac.dc.html`, Step 0).

## Decisions

- **Format** (`A`): KeePassXC's scheme only (no KeeChallenge `.xml`). KDBX 4: the challenge is the KDF seed (Argon2 salt / AES-KDF seed, 32 bytes) PKCS#7-padded to 64 bytes; the response is 20 bytes; `SHA-256(response)` is appended to the composite key data (`SHA-256(password hash ‖ key file hash ‖ SHA-256(response))`) before the KDF. Several hardware keys: responses hashed in order (only one supported in the UI).
- KDBX 3.1 (AES-KDF KDBX3 UUID) puts the response after the KDF with the master seed as challenge; KeeMac supports hardware keys for KDBX 4 only: adding a hardware key to a KDBX 3.1 database saves it as KDBX 4, opening a KDBX 3.1 database with a hardware key reports "not supported".
- **Touch frequency** (`B`): one challenge per session. While a hardware key is part of the key, saves keep the KDF seed and reuse the transformed key (no Argon2 per save, no touch); master seed and IV stay random per save. The seed changes when the master key changes (new challenge then). If another client rewrote the file with a new seed, the next merge asks for the key once and pins the new seed.
- **Touch ID** (`A`, per database): Database Settings → Master Key card: "Unlock with Touch ID without the hardware key" (off by default). Off: Touch ID fills the password, the YubiKey is still challenged. On: the response (and the seed it belongs to) is stored next to the Touch ID password; if the file's seed no longer matches, the key is asked for and the stored response replaced. Turning it off deletes the stored response.
- The file doesn't record that a hardware key is used (like KeePassXC); the recent-database entry remembers serial + slot (like the key file). The unlock screen preselects it when that key is connected.
- Devices: YubiKey (vendor 0x1050) over USB HID feature reports (OTP interface, `SLOT_CHAL_HMAC1/2`), slots configured for HMAC-SHA1 challenge-response are listed as "YubiKey 5 NFC (12345678) · Slot 2". Touch-required slots show the touch panel while waiting (with Cancel, ~15 s device timeout).
- Entry points: unlock screen, New Database, Change Master Key sheet (keep / add / change / remove hardware key), Database Settings Master Key card (summary + Touch ID option), Quick Access and SSH agent unlock panels (use the remembered key).
- Errors: "Hardware key not found — plug in YubiKey 12345678", "Timed out waiting for touch", "This slot is not configured for challenge-response", wrong key → the usual "wrong master key".
- UI testing: `KEEMAC_UI_TEST_HARDWARE_KEY=<hex secret>[:serial:slot]` replaces the USB layer with the emulator; `KEEMAC_UI_TEST_HARDWARE_KEY_TOUCH=1` makes it wait for a "Touch" button.

## Design details (KeeMac.dc.html, "Unlock · hardware key", "Touch YubiKey panel", "New Database · hardware key", "Change Master Key · hardware key", "DB Settings · Master Key hardware")

- **Key row** (shared by Unlock, New Database, Change Master Key), states:
  - collapsed: `usb` icon, "No hardware key", link "Add hardware key";
  - picker: menu "Choose a hardware key…" + "YubiKey 5 NFC (12345678) · Slot 2" items, refresh button (spinner while scanning, help "Look for hardware keys"), × "Don't use a hardware key";
  - chip: selected key label with × "Remove hardware key";
  - message: "No hardware key detected — plug in your YubiKey" (`usb_off`) or, orange, "YubiKey 12345678 remembered for this database — not connected" (`usb`), with refresh.
- **Unlock**: the row sits under Password / Key file; a remembered connected key shows as the chip. Unlocking with a remembered key that isn't connected shows the error "Connect YubiKey 12345678 to unlock this database." The Touch ID button gets the subtitle "Touch ID + YubiKey" when the database has a hardware key and the Touch ID option is off.
- **Touch panel** (290 pt floating card over Unlock, Quick Access and Database Settings): pulsing ring around a key icon; states:
  - wait: "Touch your YubiKey", "YubiKey 12345678 · Slot 2 is waiting for a touch", Cancel;
  - ok: green check, "… · Slot 2 responded";
  - timeout: "Timed out waiting for touch", "Touch the gold contact on YubiKey 12345678 within 15 seconds.", Try Again / Cancel;
  - not found: "Hardware key not found", "Plug in YubiKey 12345678 and try again.", Try Again / Cancel;
  - no slot: "This slot isn't set up for challenge-response", "Program Slot 2 with HMAC-SHA1 in YubiKey Manager, or choose another slot.", OK.
- **New Database**: "Hardware key" row with the key row and note "The database will only open with this YubiKey. Compatible with KeePassXC."; creating challenges the key (touch panel).
- **Change Master Key**: "Hardware key" segmented Keep / Choose / Remove (with a key) or None / Add (without); Keep: "Keeps YubiKey 12345678 · Slot 2."; Choose/Add: key row + warning "Make sure you have a backup YubiKey programmed with the same secret, or another way to unlock."; Remove: "The database will open without the hardware key." Submitting with a new key shows the touch panel, then saves.
- **Master Key card**: row "Hardware key" with "YubiKey 12345678 · Slot 2" / "None"; with a key, toggle "Unlock with Touch ID without the hardware key", subtitle "Your YubiKey response is stored in the keychain on this Mac. Off: the YubiKey is required every time."; disabled with "Touch ID is off for this database. Turn it on in Settings → Security." when Touch ID is off.

Review notes:
- The mockup lists both slots of every key; KeeMac lists configured slots only (the "slot not set up" panel covers slots configured for something else).
- Changing only the password/key file with "Keep" keeps the KDF seed, so the cached response is reused (no touch); a new or removed hardware key gets a new seed.
- KDBX 3.1 with a hardware key and SSH agent unlock aren't in the mockups: the first uses the unlock error line, the second the same touch panel.

## Plan

- [x] Step 0: Design prompt and review of the mockups.
- [x] Step 1: KeePassKit patch — challenge-response component in `KPKCompositeKey` (KDBX 4 formula), option to keep the KDF seed on save; patch file in `scripts/` applied by `build_vendor_frameworks.sh`, rebuilt xcframework.
- [x] Step 2: Domain + Data — `VaultHardwareKey` (serial, slot), `HardwareKeyChallenging` protocol, software emulator; loader: open/create/changeMasterKey with a hardware key, seed pinning and cached response, re-challenge on merge with a new seed; KDBX 3.1 handling.
- [x] Step 3: YubiKey HID driver (IOKit): enumerate devices, read serial and slot configuration, challenge with touch wait, cancel, timeouts.
- [x] Step 4: AppViewModel — recent databases remember the hardware key, unlock flow, touch panel state, Touch ID option (store/refresh/delete response), Quick Access / SSH agent unlock.
- [x] Step 5: UI — unlock key picker, New Database, Change Master Key sheet, Master Key card, touch panel; localization (ru).
- [x] Step 6: UI testing hooks (emulator).
- [x] Step 7: Unit tests (formula vs. KeePassXC, emulator round trips, seed pinning, merge with new seed, Touch ID option) and UI tests.
- [x] Step 8: README / CLAUDE.md, code review.

## Testing without hardware

- Formula checked against KeePassXC's code path (`CompositeKey::rawKey(&seed)`, PKCS#7 padding) with a fixed secret; a KeePassXC-made test database with a known HMAC secret if one can be found or produced.
- The HID frame format (CRC-16, 70-byte frames over 8-byte feature reports, status/touch flags) is unit-tested on byte level against ykpers' documented frames; real-device behaviour must be confirmed on an actual YubiKey later.

## Review fixes (docs/reviews/2026-10-14-branch-feature-hardware-key.md)

- Database Settings change the KDF parameters (and seed) only when the key derivation changes; renaming no longer asks the key. The Touch ID response is refreshed after new encryption settings and merges.
- The archiver no longer writes KDF parameters back into the metadata (it bumped `SettingsChanged`). Plain databases also got a new `SettingsChanged` on every save (the unarchiver set the KDF parameters after reading, which bumped it); fixed later by `scripts/patches/keepasskit-settings-changed.patch`, which also makes merges take the newer side's settings (KeePassKit compared them the wrong way round).
- The driver reads response parts until the key ends them (as ykpers), checking only the first bytes and their CRC.
- Stored Touch ID responses carry the slot they came from and only stand in for that slot.
- Locking cancels a pending hardware key panel; Touch ID's authenticated context is dropped after reading the response; unlock captures the selection before scanning; device failures are a localized `HardwareKeyFailure`; keys with a hidden serial number are reported; found devices are cached between challenges.
- Known limits: additional databases and "merge from another database" don't take hardware keys; the derived key is cached in the composite key for the session (released with the session). The real-device protocol (FIDO interface, Input Monitoring) still needs a check on an actual YubiKey.
