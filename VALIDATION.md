# Validation status

Standalone version **0.1.1**, verified on 25 November 2026 (Asia/Yekaterinburg; run timestamps are 24 November UTC).

- Source commit: `a7aec77878b35e6cc779636a50e82f6ce6e4f55e`.
- Run: https://github.com/edinterfaces-arch/claudesweep/actions/runs/45469983113
- macOS 15.8.2 / Apple Silicon: **35 tests passed, zero failures or skips**; build, DMG and launch checks passed.
- macOS 26: pending runner availability.
- Delivered artifact: `ClaudeSweep-macos-15-arm64`, ID `14955898807`.
- DMG: `ClaudeSweep-0.1.1-arm64.dmg`, 288855 bytes.
- DMG SHA-256: `7db155c40fdf2ab45d14b31cf7831dc93bd0b5e4ec9308e32e283c2e8fd91a81`.
- Workflow ZIP SHA-256: `e46bb186c3977d2200f3590fef6609956bd18e85bf3adc5b81ac80713e4f0564`.

## Passed

| Suite | Cases | What it establishes |
|---|---:|---|
| Core safety | 14 | Path boundaries, allowlists, symlinks and stale file identities |
| Native Trash integration | 9 | Actual moves and byte-for-byte recovery, name collisions, nested symlinks, denied permissions, partial failures, unchanged scans, process blocking and recovery collision protection |
| Native Keychain integration | 12 | Metadata scanning, selected deletion, unrelated accounts/services/keychains preserved, changed/replaced entries rejected, locked-keychain and running-process blocking |

The native tests call the production services using synthetic profiles and separate disposable keychains. No real Claude account or user credentials are used. See [TESTING.md](TESTING.md) for the exact isolation and opt-in procedure.

Packaging checks also passed:

- Swift debug compilation and release build, including SwiftUI, AppKit and Security.framework.
- Ad-hoc signing and strict signature verification.
- Compressed HFS+ / UDZO disk-image creation and `hdiutil verify`.
- Read-only mounting, Applications shortcut validation, copying the app from the image and verifying the copied app signature.
- ARM64 executable check and five seconds of process survival after launch. No scan or cleanup was triggered through the UI.
- Downloaded workflow archive digest, contained DMG SHA-256 and UDIF trailer verified after retrieval. The installer ZIP contains that same DMG, its checksum and `УСТАНОВКА.txt`; the DMG also includes the guide.

## Bugs found and fixed

Real macOS tests showed that file-based Keychain references can be reused after a credential is deleted and recreated with the same service and account. A reference alone was therefore insufficient to identify the scanned generation. Deletion now rechecks creation/modification dates as well as service and account, and requires a scan taken at least two seconds after the latest change to account for second-resolution timestamps. Tests cover both in-process replacement and replacement through a separate `security` command, plus in-place updates.

Tests also showed that a locked keychain could still permit deletion. Cleanup now explicitly checks that the selected keychain is unlocked before proceeding. The process guard is enforced inside the Keychain deletion service.

The legacy Keychain backend does not accept date constraints in the deletion query. Dates are checked in the immediately preceding metadata query. This is **not an atomic transaction**: an external change between validation and deletion remains a concurrency limit. Quit Claude and other processes that write these credentials before cleanup.

## Not verified

- Interactive window layout, accessibility, light/dark appearance or UI automation. Process survival is not a full UI test.
- Finder's graphical Put Back command. Recovery tests use Foundation to move the actual trashed item back and compare its bytes; the app has no in-app undo.
- Interactive login-keychain authentication prompts or user cancellation. Disposable keychains run with interaction disabled.
- Every Claude version, process wrapper, storage location, filesystem volume or browser profile.
- Intel builds or runtime compatibility outside the macOS versions recorded above. The deployment target remains macOS 13.
- Developer ID signing, Apple notarization or Gatekeeper acceptance on downloaded copies.

Keychain deletion remains permanent and is not covered by file recovery. This is an experimental local cleanup utility, not a guarantee of complete account unlinking or protection from account restrictions. Legacy Security.framework deprecation warnings remain; they did not fail the build.
