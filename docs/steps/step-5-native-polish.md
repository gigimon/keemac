# Step 5: Native polish and UX quality

## Scope
- Improve macOS-native keyboard flow and top-level commands.
- Refine split-view behavior for desktop browsing ergonomics.
- Add onboarding and empty-state guidance for first open and filtering.
- Polish visual hierarchy and baseline accessibility affordances.

## Progress
- [x] Added app-level command menu (`Vault`) with shortcuts:
  - Open vault (`Cmd+O`)
  - Select key file (`Cmd+Shift+K`)
  - Clear key file
  - Lock vault (`Cmd+L`)
- [x] Added centralized command event names in `AppCommands`.
- [x] Wired command menu actions to `RootView` via `NotificationCenter`.
- [x] Improved unlock screen:
  - redesigned to visual card-based layout instead of settings-like table
  - added large `Choose Database` / `Choose Key File` actions with clear secondary actions
  - emphasized password entry area with larger controls and single primary unlock CTA
  - focused password field for faster unlock flow
  - improved action hints (`help`) on key controls
- [x] Refined split view in vault browser:
  - explicit column widths for sidebar/content
  - column visibility toolbar controls
- [x] Added explicit empty states:
  - no entries in selected group scope
  - no search results for current query

## Notes
- Search focus command was intentionally not added because `searchFocused` requires macOS 15+, while app target is macOS 14+.

## Next
- Step 6 release readiness:
  - unit tests for loader/mapping
  - UI smoke tests
  - sample `.kdbx` compatibility checks
  - signing/notarization packaging pipeline
