# Step 2: File opening and unlock flow

## Scope
- Local `.kdbx` selection.
- Unlock form with credentials.
- Load/decrypt/parse pipeline with user-facing errors.

## Progress
- [x] `.kdbx` file picker in UI.
- [x] Unlock flow with loading/failure states.
- [x] Real parser integration (`KeePassKitVaultLoader`).
- [x] Added optional key file selection in UI.
- [x] Added composite key support in loader (`password` + `key file`).

## Notes
- Unlock now supports:
  - password only
  - key file only
  - password + key file
- If neither password nor key file is provided, unlock is blocked.
