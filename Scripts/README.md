# MyRAM Scripts

## Reset macOS local storage

`reset-myram-mac-local-storage.sh` resets exactly one MyRAMMac build configuration. It stops only the selected Debug or Release app, waits for that app to exit, then removes that configuration's SwiftData store, external blob storage, and widget snapshot.

Run from the repository root:

```bash
Scripts/reset-myram-mac-local-storage.sh debug
Scripts/reset-myram-mac-local-storage.sh release
```

Preview the selected paths without stopping the app or deleting anything:

```bash
Scripts/reset-myram-mac-local-storage.sh debug --dry-run
```

Skip the confirmation prompt:

```bash
Scripts/reset-myram-mac-local-storage.sh debug --yes
```

Without `--yes`, enter `RESET DEBUG` or `RESET RELEASE` when prompted.

The reset preserves the other build configuration and does not remove `~/Library/Application Support/MyRAM`, because that sync-state directory is shared between Debug and Release.

If the selected app cannot be stopped, the script aborts before deleting local data.

> Warning: A reset permanently deletes the selected configuration's local note data and widget snapshot.

## Resolve a frozen verification contract

`myram_verification_contract.py` converts an already-frozen MyRAM authority manifest into a deterministic, immutable verification/evidence contract. It performs no network access, Git operations, runner generation, or verification execution.

Run the MYR-196 reference replay from the repository root:

```bash
python3 Scripts/myram_verification_contract.py \
  --rules Scripts/myram-verification-contract-v1.json \
  --authority Scripts/tests/fixtures/myr-196-authority.json
```

The resolver validates repository, candidate, changed-path, and authority identity before selecting only the approved `always-required`, `changed-area`, and `explicit-authority` mappings. Unsupported paths or obligations and missing, conflicting, or stale authority fail closed with `F01`–`F04` and produce no contract on standard output.

Successful output is one canonical compact JSON object plus a trailing line feed. `contract_sha256` is the SHA-256 of that canonical JSON with the digest field absent.

Run the focused tests with:

```bash
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
```

## Reusable native test runner

Run a clean, **committed** candidate from the MyRAM checkout with one command:

```bash
python3 Scripts/verify.py                           # iPhone simulator UI tests (default)
python3 Scripts/verify.py ui                        # all MyRAMUITests
python3 Scripts/verify.py ui --only MyRAMUITests/MyRAMUITests/testNewNoteOpensWithoutAttachments
python3 Scripts/verify.py ios --only MyRAMTests/EditorFormattingMutationApplierTests
python3 Scripts/verify.py ios                       # all iOS app tests
python3 Scripts/verify.py mac                       # all Mac tests
python3 Scripts/verify.py all                       # Mac + iOS + UI + Release builds
```

Add or update ordinary `MyRAMUITests`, `MyRAMTests`, or `MyRAMMacTests` test cases for each task; no runner edits or per-ticket test scripts are needed. Xcode Test Navigator also continues to work normally.

The runner verifies the clean `HEAD` commit and the repository-owned NearbySyncCore pin, preflights the locally installed Eclipse Temurin 17 (`java`, `jlink`, `jpackage`), creates **disposable sibling worktrees** from those exact commits, and applies the repository's `automated` Verification identity in that worktree only. The iOS automated-test app, storage, service name, and test bundles differ from production and other Verification campaigns. The runner resets only the disposable automated-test app on its chosen simulator, never production or any other test app. It automatically prefers an already booted iPhone simulator and never creates one; override with `--simulator UUID` or `MYRAM_SIMULATOR_ID=UUID`.

Focused selectors must name a test target and class (optionally a method). `--only` is accepted only with `ui`, `ios`, or `mac`. No test selector may silently pass with zero tests. The runner rejects uncommitted source/test changes, disallowed repository identity, missing pinned dependency, and overlapping test runs. Xcode result bundles, execution logs, and a sealed SHA-256 manifest are retained beneath `<workspace>/Evidence/MyRAM/AutomatedVerification/`; temporary worktrees and DerivedData are removed. This is an automated regression runner, **not** a replacement for manually observed physical Mac↔iPhone acceptance or ticket-specific completion criteria.
