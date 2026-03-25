# KeeMac

Native macOS application for working with KeePass (`.kdbx`) vaults with a modern SwiftUI + AppKit interface.

> This project was developed using **OpenAI Codex**.

## What KeeMac Does

- Opens local `.kdbx` databases.
- Supports unlock modes:
  - master password
  - key file
  - master password + key file
- Remembers last selected vault/key file (security-scoped bookmarks).
- Stores up to 3 recent vaults for quick selection.
- Supports Touch ID unlock (per-vault setting).
- Shows full vault browser UI:
  - group tree (with nested groups)
  - entry list with search
  - detailed entry view
- Supports entry CRUD:
  - create, edit, delete entries
  - custom fields (including protected fields)
  - icon selection
  - OTP configuration and persistence
- Supports group CRUD:
  - create group/subgroup
  - rename group
  - delete group
  - group icon selection
- OTP in entry detail:
  - live TOTP code
  - expiry countdown + progress
  - one-click copy
- Password UX:
  - reveal/hide password
  - copy password
  - built-in password generator (length + character sets)
- Security behavior:
  - idle auto-lock (per vault)
  - lock on system sleep
  - manual lock
  - clipboard auto-clear timeout for copied secrets
- macOS integration:
  - menu bar extra with quick actions
  - optional Dock icon hiding
  - app settings window

## Tech Stack

- Swift 6.1 (`swift-tools-version: 6.1`)
- SwiftUI + AppKit interop
- Target platform: macOS 14+
- Modular package architecture:
  - `App` (application lifecycle, windows, menu bar)
  - `UI` (views, view model, settings, security UI services)
  - `Data` (KeePass bridge, load/save/edit pipeline)
  - `Domain` (models and errors)
- Vendored binary dependencies:
  - `KeePassKit.xcframework`
  - `KissXML.xcframework`

## Project Structure

```text
.
├── Package.swift
├── Sources
│   ├── App
│   ├── Data
│   ├── Domain
│   └── UI
├── Tests
│   └── DataTests
├── Vendor
│   ├── KeePassKit.xcframework
│   └── KissXML.xcframework
├── docs
│   └── steps
└── scripts
    └── build_vendor_frameworks.sh
```

## Requirements

- macOS 14 or newer
- Xcode 16+ (recommended) and Command Line Tools
- Swift toolchain with Swift 6 mode support

## Run Locally

### 1. Build

```bash
swift build
```

### 2. Run

```bash
swift run KeeMacApp
```

### 3. Run tests

```bash
swift test
```

## CI and GitHub Releases

The repository includes GitHub Actions workflows for build verification and release publishing:

- `/.github/workflows/ci.yml`
  - runs on pushes to `main`, `master`, and `codex/**`
  - runs on all pull requests
  - executes `swift test`
  - builds a packaged `.app`
  - uploads a ZIP archive and SHA-256 checksum as workflow artifacts

- `/.github/workflows/release.yml`
  - runs on tags matching `v*`
  - can also be started manually from the Actions tab
  - executes `swift test`
  - builds a release ZIP
  - creates a GitHub Release if needed
  - uploads the ZIP and checksum to that release

Local helper script:

```bash
./scripts/make_release_archive.sh
```

Artifacts produced locally and in CI:

- `.build/release/KeeMac-<version>-macOS.zip`
- `.build/release/KeeMac-<version>-macOS.zip.sha256`

To publish a release through GitHub Actions:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Touch ID Notes

- Touch ID is configured per selected vault in **Settings**.
- First unlock is done with password/key file, then KeeMac can save credentials for biometric unlock.
- If Touch ID is unavailable in your current run context, open the package in Xcode and run as a signed macOS app for the most stable Keychain/biometric behavior.

## Editing and Save Model

- KeeMac keeps an editable in-memory vault session after unlock.
- Every confirmed mutation is saved immediately.
- Before each save, KeeMac creates a backup file next to the vault:
  - `<vault>.kdbx.bak`
- Save is performed atomically via temporary file replacement.

## Settings

Current settings include:

- **Security**
  - Enable/disable Touch ID for selected vault
  - Auto-lock timeout for selected vault
- **Clipboard**
  - Auto-clear timeout for copied secrets
- **Appearance**
  - Show/hide Dock icon

## UX and Commands

- App menu commands:
  - `Cmd+O` open vault
  - `Cmd+Shift+K` select key file
  - `Cmd+L` lock vault
- Context menus in group list for group and entry actions.
- Inline icon buttons in entry detail for edit/delete/reveal/copy actions.

## Security Considerations

- Clipboard secrets are cleared after timeout only if clipboard was not modified by something else.
- Locked state clears active editing session.
- Vault/key file paths are persisted as security-scoped bookmarks.
- Logs avoid printing secret values.

## Known Limitations

- macOS-only application.
- No cloud sync integration (Dropbox/iCloud/etc.) in-app yet.
- No browser autofill extension yet.
- No import/export migration assistant yet.

## Dependency and License Notice

KeeMac uses KeePass-related binary dependencies from:

- [KeePassKit](https://github.com/MacPass/KeePassKit)
- [KissXML](https://github.com/robbiehanson/KissXML)

Review their licenses and compatibility requirements before redistribution.

## Vendor Framework Rebuild (Optional)

If you need to rebuild vendored frameworks:

```bash
bash scripts/build_vendor_frameworks.sh
```

This script clones/updates upstream repos and rebuilds `.xcframework` artifacts into `Vendor/`.

## Roadmap (High-Level)

- Better onboarding and first-run flow
- More advanced settings and per-vault profiles
- Additional UI/UX polish for power users
- Distribution pipeline (signing, notarization, packaging)

## Credits

- Product and implementation: KeeMac contributors
- AI-assisted engineering: **OpenAI Codex**
