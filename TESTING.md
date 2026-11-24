# Native cleanup integration tests

`Tests/MacIntegrationTests` calls the same `FileCleaner`, `ProcessGuard` and `KeychainService` implementations used by the app. Trash operations and Security.framework operations are real, not mocked.

## Isolation

- Native cleanup tests are opt-in: `CLAUDESWEEP_RUN_INTEGRATION_TESTS=1 swift test`.
- Run them as an unprivileged user on a disposable macOS runner or dedicated test user. CI sets the opt-in variable before packaging.
- File fixtures are UUID-owned subdirectories of the runner's home. Scans receive that synthetic home and disable shared-application discovery.
- Trash cleanup tracks only exact URLs returned for this test's moved files. It never empties Trash or deletes unrelated contents.
- Credential tests create separate, password-protected keychain files containing synthetic entries. They explicitly select those keychains for every scan, insert and deletion; they do not enumerate or delete login-keychain credentials.
- The original keychain search list and interaction setting are restored. Only test-created keychains are deleted.
- A copied system `sleep` executable named `claude` exercises process detection. Only the child process started by the test is terminated.
- No test opens a browser or contacts Anthropic.

## What is exercised

| Area | Checks |
|---|---|
| Scan | Fixture file contents remain unchanged |
| Trash | Real move, returned Trash location, byte-for-byte recovery |
| Collisions | Two same-named files remain distinct and recoverable |
| Links | A symlink inside a moved profile does not move its outside target |
| Stale scan | Replaced files are rejected before cleanup |
| Partial failure | Earlier successes are retained, the failure is reported, subsequent items are untouched |
| Permissions | A denied move is not recorded as a success |
| Running Claude | A detected process blocks file and credential deletion |
| Recovery collision | A recreated original is not overwritten |
| Keychain scan | Allowlisted metadata is returned without requesting secret values |
| Selected deletion | One selected entry disappears while another account and unrelated service survive |
| Identity | Mismatched account and unrecognized service are rejected |
| Stale credential | Replacements made inside the test or through a separate `security` process are rejected |
| Recent change | A fresh snapshot is refused; waiting alone does not authorize it; a new scan after the quiet interval does |
| Updated secret | A credential changed in place after scanning is rejected |
| Keychain boundaries | Same-named entries in another keychain survive; a foreign reference is rejected |
| Locked keychain | Deletion fails without prompting and leaves the entry intact |

## Limits

Legacy file-based keychains can reuse references after a credential is replaced. Deletion therefore compares service, account, creation date and modification date with the scan snapshot. Because these dates have one-second precision, snapshots taken within two seconds of a change are refused and require a new scan. This preflight is not an atomic lock: an external change between validation and deletion remains a concurrency limit. Keep Claude and other credential-writing processes stopped during cleanup.

These tests do not simulate clicking Finder's Put Back command: they recover the actual trashed item with Foundation's move API and check its bytes. They do not exercise an interactive login-keychain permission prompt, every Claude process wrapper, other volumes, all macOS versions, UI accessibility, or browser cleanup. A passing suite is evidence for the cases above, not a promise that every installation is covered.

The release workflow also mounts the produced DMG, copies the app, verifies its ad-hoc signature and confirms that its process remains alive for five seconds. It does not establish Apple notarization or Gatekeeper acceptance.

See VALIDATION.md for the latest recorded run and artifact checksum.
