# Step 3: Read-only vault experience

## Scope
- Build group/tree navigation for loaded vault content.
- Build searchable entries list (title, username, URL).
- Build read-only entry detail (title, username, URL, notes, custom fields).
- Add explicit copy actions only for `username` and `password`.

## Decisions
- Keep `NavigationSplitView` as the desktop-native container (`sidebar / content / detail`).
- Use group breadcrumb path as stable key for group filtering.
- Keep copy operations explicit and scoped to safe fields only (`username`, `password`).

## Progress
- [x] Added group tree UI using `OutlineGroup` in sidebar.
- [x] Added entries list with search over title/username/URL.
- [x] Added detail panel with read-only metadata, notes, and custom fields.
- [x] Added explicit copy buttons for username/password.
- [x] Added entry/group icon rendering from KeePass custom/default icons (where available).
  - custom icons from DB are rendered directly from encoded image data
  - built-in KeePass icon IDs are mapped to distinct SF Symbols in UI
- [x] Added TOTP support in entry detail:
  - current code rendering
  - explicit copy action for OTP
  - countdown/progress until current code expiry
- [x] Extended domain model for read-only detail:
  - `VaultEntry.groupPath`
  - `VaultEntry.password`
  - `VaultEntry.customFields`
  - `VaultEntry.iconPNGData`
  - `VaultEntry.otp`
  - `VaultGroup.iconPNGData`
  - new `VaultCustomField`
- [x] Updated `KeePassKitVaultLoader` mapping for group path, password, and custom attributes.
- [x] Verified build and run (`swift build`, `swift run KeeMacApp`).

## Notes
- Clipboard auto-clear is intentionally not implemented here; it belongs to Step 4.
- Group hierarchy is derived from breadcrumb paths (dot-separated format from KeePassKit).

## Next
- Step 4 security hardening:
  - memory scrubbing lifecycle
  - clipboard auto-clear timeout
  - timed lock behavior
  - secure logging policy
