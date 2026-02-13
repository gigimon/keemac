# Step 7: Post-MVP editable entries

## Goal
Add safe write capabilities for vault entries while preserving compatibility with KeePassXC and existing `.kdbx` files.

## Chosen decisions
- Save model: instant save after each confirmed action (no draft mode).
- Scope: entries only (groups stay read-only in this step).
- UX: modal sheet for create/edit forms.
- Safety: create `.bak` backup before every write operation.
- Editable fields:
  - basic: title, username, password, url, notes
  - custom fields: key, value, protected flag
  - OTP: algorithm, period, digits, secret
- OTP compatibility: preserve existing per-entry format (`otpauth` vs native KeePass fields).

## Implementation plan

### 1) Writable data session
- Keep decrypted `KPKTree` in memory after unlock as editable source-of-truth.
- Add bridge layer to map between domain/UI form models and KeePassKit entry objects.
- Ensure lock flow clears writable session from memory.

### 2) Save pipeline and backup
- Add save coordinator in `Data`:
  - `createBackup(for:)` -> `<vault>.bak`
  - `saveTree(_:, to:)` with atomic write semantics
- On save failure:
  - return user-facing error
  - keep in-memory edits unsaved (no silent discard)

### 3) Entry CRUD service
- Create use-cases:
  - `createEntry(inGroupPath:, form:)`
  - `updateEntry(id:, form:)`
  - `deleteEntry(id:)`
- Every successful mutation triggers immediate `saveTree`.
- After save, refresh view models from editable tree.

### 4) UI sheets
- Add toolbar/context actions:
  - `New Entry`
  - `Edit Entry`
  - `Delete Entry`
- Implement modal form sheet:
  - sections: basic, custom fields, OTP
  - per-field validation and inline error hints
- Deletion requires confirmation dialog.

### 5) OTP editing compatibility
- Detect current OTP storage style on entry load.
- On save:
  - if entry originally used `otpauth`, write back `otpauth`
  - if entry originally used native TimeOTP attributes, update native fields
- Validate ranges:
  - digits: 6-9
  - period: >= 1
  - secret: valid base32/base64/hex depending on selected input mode

### 6) Tests
- Unit tests:
  - mapper round-trip for basic/custom/OTP fields
  - backup file creation per save operation
  - save failure does not corrupt source file
- UI smoke tests:
  - create entry
  - edit entry
  - delete entry
  - verify persistence after app restart

## Risks
- KeePassKit save API edge-cases for some KDBX variants.
- OTP dual-format parsing/writing mismatch.
- Potential save latency for very large vaults with instant-save model.

## Done criteria
- User can create/edit/delete entries in UI.
- Each confirmed operation is persisted immediately.
- `.bak` file exists before each write.
- KeePassXC opens edited vault and shows expected field values/icons/OTP settings.
