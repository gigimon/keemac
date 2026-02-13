# Step 4: Security hardening for MVP

## Scope
- Reduce sensitive data lifetime in memory.
- Add clipboard auto-clear for copied secrets.
- Add timed lock (idle timeout + lock on system sleep).
- Establish secure logging policy.

## Progress
- [x] Master password field is cleared immediately after unlock submission in UI.
- [x] Added `SensitiveClipboard` manager with configurable timeout (`autoClearTimeoutSeconds`) and conditional clear.
- [x] Added timed lock in `AppViewModel`:
  - idle timeout lock (`idleLockTimeoutSeconds`)
  - explicit lock API
  - lock on macOS sleep via `NSWorkspace.willSleepNotification`
- [x] Added activity monitor in UI to reset idle timer on user interaction.
- [x] Added structured secure logging (`SecureLogger`) that logs only domain/code metadata (no secret values).

## Notes
- Clipboard clearing is safe-guarded by pasteboard `changeCount`, so user-copied values are not blindly overwritten.
- Idle lock currently tracks local mouse/keyboard activity in the app window.

## Next
- Step 5 UI polish:
  - command menu / shortcuts refinement
  - layout polish and onboarding empty states
  - accessibility pass
