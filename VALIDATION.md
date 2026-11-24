# Validation status

Verified build: 24 November 2026, GitHub-hosted macOS 26.7.2 / Apple Silicon.

- Commit: `8a3170f8b7050cee09f824608da14ad9a2cbace0`.
- Run: https://github.com/edinterfaces-arch/claudesweep/actions/runs/45387891261
- Artifact: `ClaudeSweep-macOS`, ID `14918225165`.
- DMG: `ClaudeSweep-0.1.0-arm64.dmg`, 299335 bytes.
- DMG SHA-256: `826a6ff419ac7dd0cb698e20e70da4fc20eb96bed6fa211a0ce46c1c59f878a0`.

Passed:

- Native Swift debug compilation and release build, including SwiftUI, AppKit and Security.framework.
- All 14 XCTest cases with zero failures. Fixtures are isolated UUID-owned subtrees under the runner home; no real Claude profile or Keychain is modified.
- Ad-hoc signing and strict signature verification.
- Compressed HFS+ / UDZO disk-image creation and `hdiutil verify`.
- Read-only mounting, Applications-shortcut validation, copying the app from the image and verifying the copied app signature.
- ARM64 executable check and five seconds of native process survival after launch. No scanning or cleanup was requested.
- Downloaded workflow archive digest, contained DMG SHA-256 and UDIF trailer verified after retrieval.

The first macOS run exposed test fixtures passing through the system /var symlink. Fixtures were relocated into an isolated home subdirectory; application symlink protections remain enabled. The successful run above includes that fix.

Not verified:

- Interactive window layout, accessibility, light/dark appearance or UI automation. Process survival is not a full UI test.
- Actual Finder Trash operations, recovery or permission failures.
- Keychain metadata access, authentication prompts or deletion against disposable credentials.
- Coverage of every Claude version, process or storage location.
- Intel builds or runtime compatibility on macOS 13–25. The deployment target remains macOS 13.
- Developer ID signing, notarization, Gatekeeper acceptance on downloaded copies or public-release readiness.

The compiler reports deprecations for SecKeychainOpen and kSecUseAuthenticationUIFail. These were warnings, not build failures. Follow the macOS release checklist in README.md before treating this prototype as a production cleaner.
