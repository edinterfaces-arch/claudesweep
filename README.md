# Claude Sweep

A native macOS utility for reviewing and cleaning known local Claude Desktop and Claude Code data. SwiftUI, Foundation and Security.framework; no third-party packages, network requests, analytics, root helper or automatic startup.

**Status: experimental native macOS build.** Apple Silicon compilation, all 14 core tests, DMG creation/mounting, copied-app signature verification and a five-second startup check passed on macOS 26 in GitHub Actions on 24 November 2026. Real cleanup, Keychain operations and UI interaction still need validation; see VALIDATION.md. The app is ad-hoc signed, without Developer ID signing or Apple notarization.

## Download the built app

Open the [verified build](https://github.com/edinterfaces-arch/claudesweep/actions/runs/45387891261) and download its `ClaudeSweep-macOS` artifact (GitHub sign-in may be required). Unzip it, open `ClaudeSweep-0.1.0-arm64.dmg`, and drag Claude Sweep to Applications. This build is for Apple Silicon Macs. Command Line Tools are only needed when building from source. Workflow artifacts have a limited retention period.

## Build on your Mac

Requirements: macOS 13+, Xcode 15+ or Apple Command Line Tools providing Swift 5.9+.

1. Unzip the project.
2. Double-click `Build.command`. If needed, run `bash Build.command` from Terminal in this folder.
3. The script runs the core tests, builds the app for your Mac's architecture, and reveals `dist/Claude Sweep.app` in Finder.
4. Open the app. No installation is required; you may move it to Applications.

If the tools are missing, run `xcode-select --install`, finish Apple's installer, and retry. The build script uses an ad-hoc local signature. A distributable release requires a Developer ID signature and notarization, neither included here. Do not disable Gatekeeper or SIP to run this project.

Alternatively, open `Package.swift` in Xcode, select the ClaudeSweep executable scheme and run. Tests use UUID-named temporary fixtures; they do not touch your real Claude data or Keychain. Build.command still builds the UI target as part of SwiftPM's test/build process.

## Create a DMG

Double-click `Package-DMG.command`, or run `bash Package-DMG.command` in this folder on your Mac. It runs the tests, builds and ad-hoc signs the app, then creates and verifies a compressed disk image with an Applications shortcut. Finder reveals the result in `dist`:

- Apple Silicon: `ClaudeSweep-0.1.0-arm64.dmg`
- Intel: `ClaudeSweep-0.1.0-x86_64.dmg`
- A matching `.dmg.sha256` file records its SHA-256 checksum.

Open the image, drag the app to Applications, and eject it. The build targets the Mac that runs the script; it is not a universal binary. A DMG is a container and does not add Developer ID signing or notarization. This prototype still needs cleanup and Keychain testing with disposable data before use on real data.

The included GitHub Actions workflow performs the same steps on a macOS runner and uploads the DMG and checksum as a workflow artifact. The macOS 26 Apple Silicon workflow has passed, including a mounted-image installation and startup check. Set `SWEEP_NO_REVEAL=1` to suppress Finder during automated builds.

## Use

1. **Scan files.** It checks known app paths and a limited set of shell/editor settings. It never reads conversation bodies, file credential values or Keychain secrets. Shell/editor files are inspected locally for specific setting names only, with a 1 MiB limit.
2. **Select only what you want removed.** All selections start empty. The caches shortcut selects only cache/log targets. Desktop and Code profiles can include irreplaceable work, skills and MCP settings.
3. **Save needed work and quit Claude.** Close Desktop, Code sessions and editors running the Claude extension. Review the exact paths, then move them to Trash. Unexpected failures stop the batch and appear in Activity.
4. **Optionally inspect Keychain.** Only recognized generic-password services in your login keychain are shown. Every deletion is selected and separately confirmed. Keychain entries are permanently deleted, not trashed. Deleting Safe Storage can make encrypted application data unreadable, including copies in Trash. Save/export needed work beforehand.
5. **Finish Browser & settings.** Browser site data, extensions, custom launch scripts and project settings need manual review. A matching variable name may just be a comment. The app never edits those files.
6. **Export Activity if needed.** The report contains file paths, action outcomes and service names, not token values or persistent Keychain references. It is otherwise kept only in memory. Keep recovery copies in Trash only as long as needed; they can contain credentials.

## Coverage

| Area | Behavior |
|---|---|
| Desktop profile | Whole `~/Library/Application Support/Claude` offered, with data-loss warning |
| Desktop caches, logs, HTTP storage, preferences, saved state | Exact known paths offered |
| Code data and state | `~/.claude` and `~/.claude.json` offered separately |
| Legacy config backups | Direct home entries beginning `.claude.json.backup` offered |
| Recent-document metadata | Direct matching `com.anthropic.claudefordesktop.sfl*` entries offered |
| Claude app bundle | `~/Applications/Claude.app` and `/Applications/Claude.app` offered separately |
| Custom Code profiles | User-added dedicated folders inside home; only known direct children offered, never the whole root |
| Keychain | Allowlisted services, including suffixed Code credentials; exact persistent-reference deletion |
| Common shell/editor settings | Names of auth/config variables detected; values never displayed; no edits |
| Browser cookies and storage | Guided manual cleanup for each profile |
| Editor/browser extensions, CLI binary, Homebrew/npm packages | Not uninstalled automatically; use their own uninstallers |
| Project files, Cowork output folders, remote machines, containers, other macOS users | Not deleted automatically |
| Enterprise 3P mode, unknown future paths, other keychains | No exhaustive coverage claim |
| Server records, account deletion, remote session revocation | Outside local cleanup scope |

Existing CLI installations or extensions can recreate files on a later launch. Use the official uninstall instructions if you are removing Claude entirely. An app launched from Finder does not reliably inherit shell environment variables, so custom profiles must be added explicitly. The app does not scan the entire disk looking for the word "Claude."

## Safety model and limits

- File deletions use Foundation's `trashItem`, never `rm`, secure erase or recursive permanent deletion.
- The scanner checks path boundaries and rejects symlink targets and symlinked ancestors. Nested symlinks are not traversed for size estimates.
- Cleanup validates each candidate's device/inode/type and repeats the process check before each move. These are conservative checks, not an atomic lock against a hostile concurrent filesystem change. Do not run the cleaner while another process edits the targets.
- A process check blocks known Claude executables, not all conceivable custom wrappers. It never force-kills an application. Stopping those apps remains the user's responsibility.
- File sizes are logical estimates, not guaranteed reclaimable storage. Enumeration stops after 25,000 entries per target; partial totals are marked with ≥.
- Keychain queries request metadata and persistent references, never `kSecReturnData`. Deletion revalidates the service/account and targets one selected persistent reference. OS access denial is surfaced.
- Do not grant broad permissions just to silence an error. Inspect inaccessible locations manually. No Full Disk Access, admin privileges or system-security changes are requested by the app.
- Files and Keychain resets cannot be transacted together. Partial results remain visible; successful changes are not falsely rolled back in the UI.
- Files can be recovered from Finder Trash while they remain there. There is no in-app undo, automatic backup or permanent recovery log.
- This is a local privacy/uninstall utility. It does not establish why an account was restricted, erase Anthropic's historical records, or guarantee that accounts cannot be associated.

## Release verification on macOS

- `swift test` and `swift build -c release` pass on Apple Silicon and Intel if both will be distributed.
- Run first under a disposable macOS user with synthetic data. Verify scan does not mutate files.
- Verify keyboard navigation, light/dark appearances, long paths and VoiceOver labels.
- Verify a running Claude process blocks cleanup; verify partial failures remain in Activity.
- Test Finder Trash recovery, including same-name collisions and denied permissions.
- Test Keychain scan with a locked login keychain, absent entries and duplicate/suffixed services. Only create disposable test entries. Verify unrelated credentials remain intact.
- Verify user-cancelled Keychain prompts don't produce success messages.
- Verify selecting a parent plus nested custom targets cannot move an item twice.
- Sign with Developer ID, enable appropriate hardened-runtime settings, notarize and staple before external distribution.

## Research references

Local storage formats change. These sources motivate the catalog, not a guarantee about every build:

- Official uninstall: https://code.claude.com/docs/en/setup
- Official credential storage: https://code.claude.com/docs/en/authentication
- Official settings scopes: https://code.claude.com/docs/en/settings
- Desktop removal catalog: https://formulae.brew.sh/api/cask/claude.json
- Apple Trash API: https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)
- Apple selected-item deletion: https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items
- Claude Code config review: https://habr.com/ru/articles/1109732/
- Keychain suffix report (user report): https://github.com/anthropics/claude-code/issues/90527
- Desktop storage observations (independent): https://kb.macfor.io/docs/ai-assistants/claude-desktop/state-and-storage

Independent, unofficial project. Claude and Anthropic are their respective owners' trademarks.
