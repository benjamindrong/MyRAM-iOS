# MyRAM Scripts

## Reset macOS local storage

`reset-myram-mac-local-storage.sh` stops `MyRAMMac` and removes the local SwiftData store and external blob storage for exactly one build configuration.

Run from the repository root:

```bash
Scripts/reset-myram-mac-local-storage.sh debug
Scripts/reset-myram-mac-local-storage.sh release
```

Preview the selected paths without deleting anything:

```bash
Scripts/reset-myram-mac-local-storage.sh debug --dry-run
```

Skip the confirmation prompt:

```bash
Scripts/reset-myram-mac-local-storage.sh debug --yes
```

Without `--yes`, enter `RESET DEBUG` or `RESET RELEASE` when prompted.

The script does not remove `~/Library/Application Support/MyRAM` because that sync-state directory is shared between Debug and Release.

> Warning: A reset permanently deletes the selected configuration's local note data.
