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

## Plan

- [ ] Step 0: Design prompt and review of the mockups.
- [ ] Step 1: KeePassKit patch — challenge-response component in `KPKCompositeKey` (KDBX 4 formula), option to keep the KDF seed on save; patch file in `scripts/` applied by `build_vendor_frameworks.sh`, rebuilt xcframework.
- [ ] Step 2: Domain + Data — `VaultHardwareKey` (serial, slot), `HardwareKeyChallenging` protocol, software emulator; loader: open/create/changeMasterKey with a hardware key, seed pinning and cached response, re-challenge on merge with a new seed; KDBX 3.1 handling.
- [ ] Step 3: YubiKey HID driver (IOKit): enumerate devices, read serial and slot configuration, challenge with touch wait, cancel, timeouts.
- [ ] Step 4: AppViewModel — recent databases remember the hardware key, unlock flow, touch panel state, Touch ID option (store/refresh/delete response), Quick Access / SSH agent unlock.
- [ ] Step 5: UI — unlock key picker, New Database, Change Master Key sheet, Master Key card, touch panel; localization (ru).
- [ ] Step 6: UI testing hooks (emulator).
- [ ] Step 7: Unit tests (formula vs. KeePassXC, emulator round trips, seed pinning, merge with new seed, Touch ID option) and UI tests.
- [ ] Step 8: README / CLAUDE.md, code review.

## Testing without hardware

- Formula checked against KeePassXC's code path (`CompositeKey::rawKey(&seed)`, PKCS#7 padding) with a fixed secret; a KeePassXC-made test database with a known HMAC secret if one can be found or produced.
- The HID frame format (CRC-16, 70-byte frames over 8-byte feature reports, status/touch flags) is unit-tested on byte level against ykpers' documented frames; real-device behaviour must be confirmed on an actual YubiKey later.
