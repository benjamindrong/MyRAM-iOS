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
