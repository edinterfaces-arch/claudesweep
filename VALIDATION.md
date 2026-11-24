# Validation status

Authoring environment: Linux, 23 November 2026. No Swift compiler, macOS SDK, AppKit runtime or Keychain available here.

Completed:

- All five Swift files (including package manifest and test source) parsed with tree-sitter-swift without error or missing nodes.
- Build.command and Package-DMG.command passed `bash -n`.
- Info.plist parsed successfully, with an executable name matching the Swift package product.
- Source reviewed for use of the Trash API, exact selected-item Keychain deletion, empty initial selections, restricted path catalog, symlink rejection, pre-move inode validation and partial-failure handling.
- Source package checked for expected contents and executable build-script permissions.

Prepared, **not executed here**:

- 14 XCTest cases covering known-path scope, unrelated-file preservation, symlink targets and ancestors, file replacement after scan, path boundaries, custom-profile scope, overlapping profiles, settings-value redaction, variable-name boundaries, credential service matching and legacy backups.
- Build.command runs these tests before packaging the app on a Mac.
- Package-DMG.command builds and verifies an HFS+ / UDZO disk image with an Applications shortcut and SHA-256 checksum. Its Linux guard was checked; actual image creation needs macOS.
- A macOS GitHub Actions workflow packages and uploads the DMG for a future repository. No remote workflow was run.

Not verified:

- Swift type checking, linking or native compilation.
- DMG creation, mounting, drag-to-Applications installation or checksum verification on macOS.
- Native window layout, accessibility and light/dark appearance.
- Actual Finder Trash behavior, recovery and permissions.
- Keychain metadata access, authentication prompts or deletion.
- Detection of all Claude processes or storage paths across versions.
- Developer ID signing, notarization or public distribution.

Syntax parsing is not a substitute for compilation or runtime tests. Follow the macOS release checklist in README.md before treating this prototype as a production cleaner.
