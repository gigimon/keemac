# Step 6: Release readiness

## Scope
- Add confidence gates before distribution.
- Cover load pipeline and error mapping with tests.
- Add smoke coverage for primary UI flow.
- Prepare compatibility and packaging process.

## Progress
- [x] Added unit tests for vault-loading pipeline and mapping logic:
  - `LocalKDBXVaultLoader` validation/credential edge cases
  - `KeePassKitVaultLoader` preconditions and KeePass error mapping
  - total: 12 passing tests in `DataTests`
- [ ] Add UI smoke tests for open/unlock/browse/read-only flow.
- [ ] Validate against a compatibility matrix of sample `.kdbx` files.
- [ ] Prepare direct distribution flow (Developer ID signing, notarization, staple, DMG/ZIP packaging).

## Notes
- `KeePassKitVaultLoader` error conversion is now exposed as internal static helper (`mapKeePassError`) to make mapping deterministic under unit tests.

## Next
- Add basic UI smoke tests for:
  - selecting vault/key file
  - unlock success/failure transitions
  - search and detail rendering
