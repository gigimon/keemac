# Description
Goal: build a macOS-only native KeePass client with a polished UI and strong security defaults.

Product scope for MVP:
- Platform: macOS only
- Minimum OS target: macOS 14+ (Sonoma or newer)
- UI architecture: SwiftUI-first
- KeePass support: existing Swift KDBX library (do not implement crypto format from scratch)
- Storage model: local-first (open local `.kdbx` files only)
- Unlock model: master password with optional key file support
- Lock model: timed lock (auto-lock after inactivity timeout + lock on sleep)
- Clipboard policy: allow copy only for `username` and `password` fields with auto-clear timeout
- Distribution channel: direct distribution outside Mac App Store (signed + notarized)
- Feature scope: read-only vault browser

Tech stack:
- Language: Swift 6
- UI: SwiftUI (with minimal AppKit interop only if needed)
- App architecture: MVVM + Observable state model
- KDBX library: KeePassKit (vendored `xcframework` integration for MVP baseline)
- Data/security: Keychain APIs where appropriate, strict in-memory secret lifecycle, no custom cryptography
- Project setup: Xcode app target for macOS

Non-goals for MVP:
- Built-in cloud sync
- Touch ID unlock
- Editing/creating/deleting entries
- Attachments/history/advanced KeePass features

# Implementation

## Step 1: Foundation and app skeleton
[x] Create macOS SwiftUI app target and baseline project structure
[x] Set deployment target to macOS 14+ and validate baseline run
[x] Define modules/layers (`App`, `Domain`, `Data`, `UI`)
[x] Add dependency for chosen KDBX library and validate basic integration build (vendored KeePassKit + KissXML binary targets)
[x] Define error model (invalid password, unsupported KDBX variant, parse failure, file I/O errors)

## Step 2: File opening and vault loading flow
[x] Implement local file picker for `.kdbx`
[x] Build unlock screen with master password input and validation states
[x] Implement vault load pipeline (file read -> decrypt -> parse -> mapped domain model)
[x] Add loading and failure UX states (progress, retry, clear user-facing errors)

## Step 3: Read-only vault experience
[x] Build group/tree navigation
[x] Build entries list view with search/filter (title, username, URL)
[x] Build entry detail screen (title, username, URL, notes, custom fields in read-only)
[x] Add copy actions only for `username` and `password` with explicit user action

## Step 4: Security hardening for MVP
[x] Ensure password/derived key material is cleared from memory as soon as possible
[x] Add auto-clear policy for clipboard after configurable timeout
[x] Implement timed lock policy (inactivity timeout + immediate lock on sleep)
[x] Add structured secure logging policy (no secrets in logs/crashes)

## Step 5: Native polish and UX quality
[x] Refine macOS-native keyboard shortcuts and command menu
[x] Add split-view layout for desktop ergonomics
[x] Implement empty states and onboarding hints for first open
[x] Finalize visual polish (spacing, typography, motion, accessibility basics)

## Step 6: Release readiness
[x] Add unit tests for vault-loading pipeline and mapping logic
[] Add UI smoke tests for open/unlock/browse/read-only flow
[] Validate against a compatibility matrix of sample `.kdbx` files
[] Prepare direct distribution flow (Developer ID signing, notarization, staple, DMG/ZIP packaging)

## Step 7: Post-MVP — Editable entries (instant save)
[] Introduce writable vault session model (keep in-memory `KPKTree` after unlock, not only mapped read-only DTO)
[] Add persistence pipeline for save operations:
[] Before each write, create `.bak` backup next to source `.kdbx`
[] Persist edits atomically and surface save errors to UI
[] Implement entry CRUD in UI via modal sheets (no inline editing):
[] Add "New Entry" sheet
[] Add "Edit Entry" sheet
[] Add delete action with confirmation
[] Add editable fields in form:
[] Basic fields: title, username, password, url, notes
[] Custom fields: add/remove/edit key-value + protected toggle
[] OTP fields: algorithm, period, digits, secret
[] Implement OTP format strategy:
[] Preserve existing OTP format per entry where possible (`otpauth` vs native KeePass fields)
[] For newly created OTP-enabled entries, default to `otpauth` format unless explicitly set otherwise
[] Wire write actions to immediate persistence (Option B):
[] Save immediately after each confirmed sheet action (create/update/delete)
[] Reload/refresh list/detail state from writable session after save
[] Add safety and conflict guards:
[] Prevent editing while vault is locked/loading
[] Validate unique custom field keys before save
[] Validate OTP inputs (secret encoding, period/digits ranges)
[] Add tests for write-path:
[] Unit tests for mapper round-trip (domain form <-> KeePassKit entry)
[] Unit tests for backup creation and save failure rollback behavior
[] UI smoke tests for create/edit/delete entry flows

# Next planning decisions (after editable entries)
- Group CRUD (create/rename/move/delete)
- Attachments and history editing
- Touch ID unlock and sync roadmap
